package expo.modules.mpv

import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.Rect
import android.graphics.drawable.Icon
import android.os.Build
import android.util.Rational
import android.view.View
import android.view.ViewGroup
import android.view.ViewTreeObserver
import androidx.activity.ComponentActivity
import androidx.core.app.PictureInPictureModeChangedInfo
import androidx.core.content.ContextCompat
import androidx.core.util.Consumer
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import java.util.WeakHashMap

/** Owns Activity PiP without depending on React's paused background timers. */
internal class ExpoMpvPictureInPicture(
    private val view: View,
    private val activity: ComponentActivity,
    private val onModeChanged: (Boolean) -> Unit,
    private val onTogglePlay: () -> Unit,
    private val onClosed: () -> Unit,
) {
    private var enabled = false
    private var playing = false
    private var ratio = Rational(16, 9)
    private var active = false
    private var released = false
    private val hiddenViews = mutableMapOf<View, Float>()
    private val action = "${activity.packageName}.expo.mpv.PIP_${System.identityHashCode(this)}"
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == action && active && !released) onTogglePlay()
        }
    }
    private val modeListener = Consumer<PictureInPictureModeChangedInfo> { info ->
        if (owners[activity] === this) changeMode(info.isInPictureInPictureMode)
    }
    private val leaveListener = Runnable {
        if (Build.VERSION.SDK_INT < 31 && canAutoEnter()) enter()
    }
    private val layoutListener = View.OnLayoutChangeListener { _, _, _, _, _, _, _, _, _ ->
        updateParams()
    }
    private val drawListener = ViewTreeObserver.OnPreDrawListener {
        if (active) hideSiblings()
        true
    }
    private val lifecycleListener = LifecycleEventObserver { _, event ->
        // Dismissing the small window must not leave invisible audio playing.
        // Expansion resumes the Activity; it does not stop it.
        if (event == Lifecycle.Event.ON_STOP && active) onClosed()
        if (event == Lifecycle.Event.ON_DESTROY) release()
    }

    init {
        activity.addOnPictureInPictureModeChangedListener(modeListener)
        activity.addOnUserLeaveHintListener(leaveListener)
        activity.lifecycle.addObserver(lifecycleListener)
        view.addOnLayoutChangeListener(layoutListener)
        view.viewTreeObserver.addOnPreDrawListener(drawListener)
        ContextCompat.registerReceiver(activity, receiver, IntentFilter(action), ContextCompat.RECEIVER_NOT_EXPORTED)
    }

    fun update(enabled: Boolean, playing: Boolean, width: Int, height: Int) {
        this.enabled = enabled
        this.playing = playing
        val aspect = if (width > 0 && height > 0) width.toDouble() / height else 16.0 / 9.0
        // Android's normal PiP range excludes very tall/wide video ratios.
        ratio = Rational((aspect.coerceIn(1.0 / 2.39, 2.39) * 10000).toInt(), 10000)
        if (enabled && owners[activity] !== this) {
            owners[activity]?.changeMode(false)
            owners[activity] = this
        }
        updateParams()
        // Source replacement can attach a new view while the Activity is
        // already pinned; Android does not send another mode-change callback.
        if (enabled && supported() && activity.isInPictureInPictureMode) changeMode(true)
    }

    private fun supported() = Build.VERSION.SDK_INT >= 26 &&
        activity.packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE) &&
        !activity.isFinishing && !activity.isDestroyed

    private fun canAutoEnter() = enabled && playing && view.isShown &&
        owners[activity] === this && !released

    private fun params(): PictureInPictureParams {
        val builder = PictureInPictureParams.Builder().setAspectRatio(ratio)
        val bounds = Rect()
        if (view.getGlobalVisibleRect(bounds) && !bounds.isEmpty) builder.setSourceRectHint(bounds)
        val pendingIntent = PendingIntent.getBroadcast(
            activity, 0, Intent(action).setPackage(activity.packageName),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val title = activity.getString(if (playing) R.string.expo_mpv_pip_pause else R.string.expo_mpv_pip_play)
        builder.setActions(listOf(RemoteAction(
            Icon.createWithResource(activity, if (playing) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play),
            title, title, pendingIntent,
        )))
        if (Build.VERSION.SDK_INT >= 31) {
            builder.setAutoEnterEnabled(canAutoEnter()).setSeamlessResizeEnabled(false)
        }
        return builder.build()
    }

    private fun updateParams() {
        if (released || owners[activity] !== this || !supported()) return
        try {
            activity.setPictureInPictureParams(params())
        } catch (_: IllegalStateException) {
            // Unsupported host manifest or an Activity that is already leaving.
        } catch (_: IllegalArgumentException) {
            // OEM PiP policy can reject otherwise supported parameters.
        }
    }

    fun enter(): Boolean {
        if (!enabled || released || !view.isShown || !supported()) return false
        if (activity.isInPictureInPictureMode) return true
        return try {
            activity.enterPictureInPictureMode(params())
        } catch (_: IllegalStateException) {
            false
        } catch (_: IllegalArgumentException) {
            false
        }
    }

    private fun changeMode(value: Boolean) {
        if (active == value) return
        active = value
        if (value) {
            // Keep the video host and its native timed overlay. Hide sibling
            // controls at every ancestor without reparenting the SurfaceView or
            // depending on a JS render after Activity.onPause().
            hideSiblings()
        } else {
            hiddenViews.forEach { (sibling, alpha) -> sibling.alpha = alpha }
            hiddenViews.clear()
            // Some Android versions dispatch mode=false before onStop when
            // closing PiP. Distinguish that from expansion back into the app.
            view.postDelayed({
                if (!released && !active && !activity.lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) {
                    onClosed()
                }
            }, 300)
        }
        onModeChanged(value)
    }

    private fun hideSiblings() {
        var child = view
        var parent = child.parent as? ViewGroup
        while (parent != null) {
            for (index in 0 until parent.childCount) {
                val sibling = parent.getChildAt(index)
                if (sibling !== child) {
                    // Fabric resets visibility during layout updates. Also cover
                    // new siblings (e.g. buffering UI) mounted while already pinned.
                    hiddenViews.putIfAbsent(sibling, sibling.alpha)
                    sibling.alpha = 0f
                }
            }
            child = parent
            parent = child.parent as? ViewGroup
        }
    }

    fun release() {
        if (released) return
        enabled = false
        updateParams()
        changeMode(false)
        released = true
        if (owners[activity] === this) owners.remove(activity)
        activity.removeOnPictureInPictureModeChangedListener(modeListener)
        activity.removeOnUserLeaveHintListener(leaveListener)
        activity.lifecycle.removeObserver(lifecycleListener)
        view.removeOnLayoutChangeListener(layoutListener)
        if (view.viewTreeObserver.isAlive) view.viewTreeObserver.removeOnPreDrawListener(drawListener)
        activity.unregisterReceiver(receiver)
    }

    companion object {
        private val owners = WeakHashMap<ComponentActivity, ExpoMpvPictureInPicture>()
    }
}
