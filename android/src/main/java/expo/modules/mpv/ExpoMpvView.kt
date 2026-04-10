package expo.modules.mpv

import android.content.Context
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
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

    private var isDestroyed = false

    private val surfaceView = SurfaceView(context).apply {
        layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
    }

    private val player = MpvPlayer(
        context,
        object : MpvPlayer.Listener {
            override fun onPlaybackStateChange(state: String, isPlaying: Boolean) {
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

    private val surfaceCallback = object : SurfaceHolder.Callback {
        override fun surfaceCreated(holder: SurfaceHolder) {
            player.setSurface(holder.surface)
        }

        override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) = Unit

        override fun surfaceDestroyed(holder: SurfaceHolder) {
            player.setSurface(null)
        }
    }

    init {
        addView(surfaceView)
        setBackgroundColor(0xFF000000.toInt())
        surfaceView.holder.addCallback(surfaceCallback)
    }

    override fun onDetachedFromWindow() {
        destroy()
        super.onDetachedFromWindow()
    }

    override fun onWindowVisibilityChanged(visibility: Int) {
        super.onWindowVisibilityChanged(visibility)
        if (visibility == View.GONE || visibility == View.INVISIBLE) {
            player.setPropertyString("vid", "no")
        } else {
            player.setPropertyString("vid", "auto")
        }
    }

    fun destroy() {
        if (isDestroyed) return
        isDestroyed = true
        surfaceView.holder.removeCallback(surfaceCallback)
        player.setSurface(null)
        player.release()
    }

    fun loadFile(url: String) {
        player.loadFile(url)
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
