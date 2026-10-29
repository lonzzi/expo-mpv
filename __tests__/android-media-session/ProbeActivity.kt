package expo.modules.mpv

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.SurfaceHolder
import android.view.SurfaceView
import org.json.JSONObject
import java.io.File

/** Uses the production engine, JNI bridge and service; no playback mocks. */
class ProbeActivity : Activity(), MpvPlayer.Listener, SurfaceHolder.Callback {
    private lateinit var player: MpvPlayer
    private lateinit var surface: SurfaceView
    private val handler = Handler(Looper.getMainLooper())
    private var loads = 0
    private var errors = mutableListOf<String>()
    private var foreground = false
    private var ended = false
    private var title = "Episode 1"
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.getStringExtra("command")) {
                "replace" -> {
                    val previous = player
                    title = "Episode 2"
                    player = createPlayer()
                    player.setSurface(surface.holder.surface)
                    player.loadFile(File(filesDir, "fixture.mp4").path, 7.0)
                    ExpoMpvPlaybackService.attach(applicationContext, player, mapOf("title" to title))
                    previous.release()
                }
                "end" -> { player.setLooping(false); player.seekTo(29.0) }
                "replay" -> { player.seekTo(5.0); player.play() }
                "stop" -> { player.stop(); writeState() }
            }
        }
    }

    private fun createPlayer() = MpvPlayer(applicationContext, this).apply { setHwdec("no") }

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        surface = SurfaceView(this)
        setContentView(surface)
        player = createPlayer()
        surface.holder.addCallback(this)
        val filter = IntentFilter("expo.modules.mpv.TEST_CONTROL")
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(receiver, filter, RECEIVER_EXPORTED)
        else registerReceiver(receiver, filter)
        handler.post(object : Runnable {
            override fun run() { writeState(); handler.postDelayed(this, 250) }
        })
    }

    override fun onResume() { super.onResume(); foreground = true; player.setVideoVisible(true) }
    override fun onPause() { foreground = false; player.setVideoVisible(false); super.onPause() }
    override fun onDestroy() {
        unregisterReceiver(receiver)
        handler.removeCallbacksAndMessages(null)
        player.release()
        super.onDestroy()
    }
    override fun surfaceCreated(holder: SurfaceHolder) {
        player.setSurface(holder.surface)
        if (loads == 0) {
            player.loadFile(File(filesDir, "fixture.mp4").path, 2.0)
            ExpoMpvPlaybackService.attach(applicationContext, player, mapOf("title" to title))
        }
    }
    override fun surfaceDestroyed(holder: SurfaceHolder) { player.setSurface(null) }
    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        player.setPropertyString("android-surface-size", "${width}x$height")
    }
    override fun onLoad(duration: Double, width: Int, height: Int) { loads++; player.setLooping(true) }
    override fun onPlaybackStateChange(state: String, isPlaying: Boolean) { ended = state == "ended"; writeState() }
    override fun onProgress(position: Double, duration: Double, bufferedDuration: Double) {}
    override fun onError(message: String) { errors.add(message); writeState() }
    override fun onEnd(reason: String) {}
    override fun onBuffer(isBuffering: Boolean) {}
    override fun onSeek() {}
    override fun onVolumeChange(volume: Double, muted: Boolean) {}

    private fun writeState() {
        val state = JSONObject().put("position", player.sessionPosition)
            .put("playing", player.sessionPlaying).put("foreground", foreground)
            .put("loads", loads).put("ended", ended).put("title", title)
            .put("errors", org.json.JSONArray(errors))
        val temporary = File(filesDir, "state.tmp")
        temporary.writeText(state.toString())
        temporary.renameTo(File(filesDir, "state.json"))
    }
}
