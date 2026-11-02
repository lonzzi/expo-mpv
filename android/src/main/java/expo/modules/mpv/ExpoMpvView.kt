package expo.modules.mpv

import android.content.Context
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.widget.FrameLayout
import androidx.activity.ComponentActivity
import expo.modules.kotlin.AppContext
import expo.modules.kotlin.viewevent.EventDispatcher
import expo.modules.kotlin.views.ExpoView

class ExpoMpvView(context: Context, appContext: AppContext) : ExpoView(context, appContext) {
    private val onPlaybackStateChange by EventDispatcher()
    private val onProgress by EventDispatcher()
    private val onLoad by EventDispatcher()
    private val onError by EventDispatcher()
    private val onEnd by EventDispatcher()
    private val onBuffer by EventDispatcher()
    private val onSeek by EventDispatcher()
    private val onVolumeChange by EventDispatcher()
    private val onPictureInPictureChange by EventDispatcher()

    // SurfaceView is a native child; React Native only lays out this outer host.
    override val shouldUseAndroidLayout = true

    private var isDestroyed = false
    var sourceToLoad: String? = null
    var startPosition: Double = 0.0
    var showNotificationControls = false
    var metadata: Map<String, String> = emptyMap()
    private var hasSource = false
    var pictureInPictureEnabled = false
    private var videoWidth = 0
    private var videoHeight = 0
    private var playbackRunning = false
    private var exiting = false
    private var pip: ExpoMpvPictureInPicture? = null

    private val surfaceView = SurfaceView(context).apply {
        layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
    }

    private val player: MpvPlayer = MpvPlayer(
        context,
        object : MpvPlayer.Listener {
            override fun onPlaybackStateChange(state: String, isPlaying: Boolean) {
                if (state == "idle") hasSource = false
                playbackRunning = isPlaying && state != "ended" && state != "idle"
                pipOverlay.playing = state == "playing"
                updatePictureInPicture()
                onPlaybackStateChange(
                    mapOf(
                        "state" to state,
                        "isPlaying" to isPlaying,
                    )
                )
            }

            override fun onProgress(position: Double, duration: Double, bufferedDuration: Double) {
                onProgress(
                    mapOf(
                        "position" to position,
                        "duration" to duration,
                        "bufferedDuration" to bufferedDuration,
                    )
                )
            }

            override fun onLoad(duration: Double, width: Int, height: Int) {
                videoWidth = width
                videoHeight = height
                updatePictureInPicture()
                onLoad(
                    mapOf(
                        "duration" to duration,
                        "width" to width,
                        "height" to height,
                    )
                )
            }

            override fun onError(message: String) {
                onError(mapOf("error" to message))
            }

            override fun onEnd(reason: String) {
                onEnd(mapOf("reason" to reason))
            }

            override fun onBuffer(isBuffering: Boolean) {
                onBuffer(mapOf("isBuffering" to isBuffering))
            }

            override fun onSeek() {
                pipOverlay.invalidate()
                onSeek(emptyMap<String, Any>())
            }

            override fun onVolumeChange(volume: Double, muted: Boolean) {
                onVolumeChange(
                    mapOf(
                        "volume" to volume,
                        "muted" to muted,
                    )
                )
            }
        },
    )

    private val pipOverlay = ExpoMpvPipOverlay(context) { player.sessionPosition / 1000.0 }.apply {
        layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
        visibility = View.GONE
    }

    private val surfaceCallback = object : SurfaceHolder.Callback {
        override fun surfaceCreated(holder: SurfaceHolder) {
            player.setSurface(holder.surface)
        }

        override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
            if (width > 0 && height > 0) {
                // Use physical Surface pixels, not dp or the decoded video's dimensions.
                // libmpv needs this to keep its viewport and EGL buffers in sync.
                player.setPropertyString("android-surface-size", "${width}x$height")
            }
        }

        override fun surfaceDestroyed(holder: SurfaceHolder) {
            player.setSurface(null)
        }
    }

    init {
        // ExpoView is a LinearLayout. Both native layers must share one frame,
        // otherwise the overlay is laid out beside (outside) the video.
        addView(FrameLayout(context).apply {
            layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
            addView(surfaceView, FrameLayout.LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
            addView(pipOverlay, FrameLayout.LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        })
        setBackgroundColor(0xFF000000.toInt())
        surfaceView.holder.addCallback(surfaceCallback)
    }

    override fun onDetachedFromWindow() {
        // Window detach can be temporary during native-screen/Activity changes.
        // Release the engine only when Expo actually drops the React view.
        pip?.release()
        pip = null
        player.setVideoVisible(false)
        player.setSurface(null)
        super.onDetachedFromWindow()
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        player.setVideoVisible(windowVisibility == View.VISIBLE)
        val activity = appContext.currentActivity as? ComponentActivity
        if (activity != null && pip == null) {
            pip = ExpoMpvPictureInPicture(this, activity, { active ->
                pipOverlay.visibility = if (active) View.VISIBLE else View.GONE
                onPictureInPictureChange(mapOf("isActive" to active))
            }, { player.togglePlay() }, { player.pause() })
        }
        updatePictureInPicture()
    }

    override fun onWindowVisibilityChanged(visibility: Int) {
        super.onWindowVisibilityChanged(visibility)
        player.setVideoVisible(visibility == View.VISIBLE)
    }

    fun prepareForExit(onReady: () -> Unit) {
        exiting = true
        updatePictureInPicture()
        player.prepareForExit(onReady)
    }

    fun destroy() {
        if (isDestroyed) return
        isDestroyed = true
        pip?.release()
        pip = null
        surfaceView.holder.removeCallback(surfaceCallback)
        player.setSurface(null)
        player.release()
    }

    fun loadSourceIfNeeded() {
        val source = sourceToLoad ?: return
        sourceToLoad = null
        hasSource = true
        exiting = false
        videoWidth = 0
        videoHeight = 0
        player.loadFile(source, startPosition)
    }

    fun updatePictureInPicture() {
        pip?.update(
            pictureInPictureEnabled && hasSource && videoWidth > 0 && videoHeight > 0 && !exiting && !isDestroyed,
            playbackRunning, videoWidth, videoHeight,
        )
    }

    fun enterPictureInPicture(): Boolean = pip?.enter() ?: false

    fun setPictureInPictureOverlay(overlay: Map<String, Any?>?) {
        pipOverlay.setOverlay(overlay)
    }

    fun updateMediaSession() {
        if (isDestroyed) return
        if (showNotificationControls && hasSource) {
            ExpoMpvPlaybackService.attach(context.applicationContext, player, metadata)
        } else {
            ExpoMpvPlaybackService.detach(player)
        }
    }

    fun play() {
        player.play()
    }

    fun pause() {
        player.pause()
    }

    fun togglePlay() {
        player.togglePlay()
    }

    fun stop() {
        sourceToLoad = null
        hasSource = false
        updatePictureInPicture()
        player.stop()
    }

    fun seekTo(position: Double) {
        player.seekTo(position)
    }

    fun seekBy(offset: Double) {
        player.seekBy(offset)
    }

    fun setSpeed(speed: Double) {
        player.setSpeed(speed)
    }

    fun setVolume(volume: Double) {
        player.setVolume(volume)
    }

    fun setMuted(muted: Boolean) {
        player.setMuted(muted)
    }

    fun setLooping(loop: Boolean) {
        player.setLooping(loop)
    }

    fun setHwdec(mode: String) {
        player.setHwdec(mode)
    }

    fun setSubtitleTrack(trackId: Int) {
        player.setSubtitleTrack(trackId)
    }

    fun setAudioTrack(trackId: Int) {
        player.setAudioTrack(trackId)
    }

    fun addSubtitle(path: String, flag: String, title: String?, lang: String?) {
        player.addSubtitle(path, flag, title, lang)
    }

    fun addAudio(path: String, flag: String, title: String?, lang: String?) {
        player.addAudio(path, flag, title, lang)
    }

    fun removeSubtitle(trackId: Int) {
        player.removeSubtitle(trackId)
    }

    fun reloadSubtitles() {
        player.reloadSubtitles()
    }

    fun setSubtitleDelay(seconds: Double) {
        player.setSubtitleDelay(seconds)
    }

    fun setPropertyString(name: String, value: String) {
        player.setPropertyString(name, value)
    }

    fun getPlaybackInfo(): Map<String, Any> {
        return player.getPlaybackInfo()
    }

    fun getTrackList(): List<Map<String, Any>> {
        return player.getTrackList()
    }

    fun getCurrentTrackIds(): Map<String, Int> {
        return player.getCurrentTrackIds()
    }

    fun getMediaInfo(): Map<String, Any> {
        return player.getMediaInfo()
    }
}
