package expo.modules.mpv

import android.app.Activity
import android.app.Application
import android.content.Context
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.SurfaceHolder
import android.view.SurfaceView
import expo.modules.kotlin.AppContext
import expo.modules.kotlin.viewevent.EventDispatcher
import expo.modules.kotlin.views.ExpoView

class ExpoMpvView(context: Context, appContext: AppContext) : ExpoView(context, appContext) {

    // MARK: - Event Dispatchers

    private val onPlaybackStateChange by EventDispatcher()
    private val onProgress by EventDispatcher()
    private val onLoad by EventDispatcher()
    private val onError by EventDispatcher()
    private val onEnd by EventDispatcher()
    private val onBuffer by EventDispatcher()
    private val onSeek by EventDispatcher()
    private val onVolumeChange by EventDispatcher()

    // MARK: - State

    private var nativePtr: Long = 0
    private var isInitialized = false
    private var pendingSource: String? = null
    private var pendingHwdec: String = if (isEmulator()) "no" else "mediacodec"
    private val mainHandler = Handler(Looper.getMainLooper())
    private var progressRunnable: Runnable? = null

    // Cached property values from observe callbacks (thread-safe reads from main thread)
    @Volatile private var cachedTimePos: Double = 0.0
    @Volatile private var cachedDuration: Double = 0.0
    @Volatile private var cachedCacheDuration: Double = 0.0
    @Volatile private var cachedPause: Boolean = false
    @Volatile private var cachedVolume: Double = 100.0
    @Volatile private var cachedMute: Boolean = false
    @Volatile private var cachedSpeed: Double = 1.0
    @Volatile private var cachedVideoW: Long = 0
    @Volatile private var cachedVideoH: Long = 0

    // MARK: - Surface

    private val surfaceView: SurfaceView = SurfaceView(context).apply {
        layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
    }

    // MARK: - Init

    init {
        addView(surfaceView)
        setBackgroundColor(0xFF000000.toInt())

        // Create mpv and set options (but don't initialize yet — need surface first)
        createMpv()

        surfaceView.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {
                if (nativePtr == 0L) return
                if (!isInitialized) {
                    // First time: attach surface BEFORE mpv_initialize
                    MPVLib.nativeAttachSurface(nativePtr, holder.surface)
                    initializeMpv()
                } else {
                    // Surface recreated: reattach AFTER mpv_initialize
                    MPVLib.nativeReattachSurface(nativePtr, holder.surface)
                }
                pendingSource?.let { src ->
                    loadFile(src)
                    pendingSource = null
                }
            }

            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}

            override fun surfaceDestroyed(holder: SurfaceHolder) {
                if (nativePtr != 0L && isInitialized) {
                    MPVLib.nativeDetachSurface(nativePtr)
                }
            }
        })

        setupLifecycle()
    }

    // MARK: - Lifecycle

    private val lifecycleCallbacks = object : Application.ActivityLifecycleCallbacks {
        override fun onActivityPaused(activity: Activity) {
            if (nativePtr != 0L && isInitialized && activity == appContext.currentActivity) {
                setPropertyString("vid", "no")
            }
        }
        override fun onActivityResumed(activity: Activity) {
            if (nativePtr != 0L && isInitialized && activity == appContext.currentActivity) {
                setPropertyString("vid", "auto")
            }
        }
        override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}
        override fun onActivityStarted(activity: Activity) {}
        override fun onActivityStopped(activity: Activity) {}
        override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
        override fun onActivityDestroyed(activity: Activity) {}
    }

    private fun setupLifecycle() {
        val app = context.applicationContext as? Application ?: return
        app.registerActivityLifecycleCallbacks(lifecycleCallbacks)
    }

    override fun onDetachedFromWindow() {
        super.onDetachedFromWindow()
        destroy()
    }

    fun destroy() {
        stopProgressTimer()
        val app = context.applicationContext as? Application
        app?.unregisterActivityLifecycleCallbacks(lifecycleCallbacks)
        if (nativePtr != 0L) {
            MPVLib.nativeDestroy(nativePtr)
            nativePtr = 0
        }
        isInitialized = false
    }

    // MARK: - MPV Setup (two-phase: create+options, then initialize after surface)

    private fun createMpv() {
        nativePtr = MPVLib.nativeCreate()
        if (nativePtr == 0L) {
            onError(mapOf("error" to "Failed to create mpv instance"))
            return
        }

        MPVLib.nativeSetCallback(nativePtr, this)

        // Rendering
        MPVLib.nativeSetOptionString(nativePtr, "vo", "gpu")
        MPVLib.nativeSetOptionString(nativePtr, "gpu-context", "android")
        MPVLib.nativeSetOptionString(nativePtr, "hwdec", pendingHwdec)
        if (pendingHwdec != "no") {
            MPVLib.nativeSetOptionString(nativePtr, "hwdec-codecs", "h264,hevc,mpeg4,mpeg2video,vp8,vp9,av1")
        }

        if (isEmulator()) {
            android.util.Log.w("ExpoMpv", "Emulator detected, hardware decoding disabled (using software decoding)")
        }

        // General
        MPVLib.nativeSetOptionString(nativePtr, "force-window", "yes")
        MPVLib.nativeSetOptionString(nativePtr, "keep-open", "yes")
        MPVLib.nativeSetOptionString(nativePtr, "idle", "yes")
        MPVLib.nativeSetOptionString(nativePtr, "input-default-bindings", "no")
        MPVLib.nativeSetOptionString(nativePtr, "input-vo-keyboard", "no")
    }

    private fun initializeMpv() {
        if (nativePtr == 0L) return

        val ret = MPVLib.nativeInitialize(nativePtr)
        if (ret < 0) {
            onError(mapOf("error" to "mpv_initialize failed: $ret"))
            return
        }

        isInitialized = true

        // Observe properties
        MPVLib.nativeObserveProperty(nativePtr, "pause", MPVLib.FORMAT_FLAG)
        MPVLib.nativeObserveProperty(nativePtr, "duration", MPVLib.FORMAT_DOUBLE)
        MPVLib.nativeObserveProperty(nativePtr, "time-pos", MPVLib.FORMAT_DOUBLE)
        MPVLib.nativeObserveProperty(nativePtr, "paused-for-cache", MPVLib.FORMAT_FLAG)
        MPVLib.nativeObserveProperty(nativePtr, "eof-reached", MPVLib.FORMAT_FLAG)
        MPVLib.nativeObserveProperty(nativePtr, "volume", MPVLib.FORMAT_DOUBLE)
        MPVLib.nativeObserveProperty(nativePtr, "mute", MPVLib.FORMAT_FLAG)
        MPVLib.nativeObserveProperty(nativePtr, "speed", MPVLib.FORMAT_DOUBLE)
        MPVLib.nativeObserveProperty(nativePtr, "demuxer-cache-duration", MPVLib.FORMAT_DOUBLE)
        MPVLib.nativeObserveProperty(nativePtr, "video-params/w", MPVLib.FORMAT_INT64)
        MPVLib.nativeObserveProperty(nativePtr, "video-params/h", MPVLib.FORMAT_INT64)
    }

    // MARK: - JNI Callbacks (called from event thread)

    fun onEvent(eventId: Int) {
        when (eventId) {
            MPVLib.EVENT_FILE_LOADED -> mainHandler.post {
                onLoad(mapOf(
                    "duration" to (if (cachedDuration.isFinite()) cachedDuration else 0.0),
                    "width" to cachedVideoW.toInt(),
                    "height" to cachedVideoH.toInt()
                ))
                startProgressTimer()
            }
            MPVLib.EVENT_SEEK -> mainHandler.post {
                onSeek(emptyMap<String, Any>())
            }
            MPVLib.EVENT_SHUTDOWN -> {
                isInitialized = false
            }
        }
    }

    fun onPropertyChange(name: String, value: Any?) {
        when (name) {
            "time-pos" -> cachedTimePos = (value as? Double) ?: 0.0
            "duration" -> cachedDuration = (value as? Double) ?: 0.0
            "demuxer-cache-duration" -> cachedCacheDuration = (value as? Double) ?: 0.0
            "pause" -> cachedPause = (value as? Boolean) ?: false
            "volume" -> cachedVolume = (value as? Double) ?: 0.0
            "mute" -> cachedMute = (value as? Boolean) ?: false
            "speed" -> cachedSpeed = (value as? Double) ?: 1.0
            "video-params/w" -> cachedVideoW = (value as? Long) ?: 0
            "video-params/h" -> cachedVideoH = (value as? Long) ?: 0
        }
        mainHandler.post {
            when (name) {
                "pause" -> {
                    val paused = (value as? Boolean) ?: false
                    onPlaybackStateChange(mapOf(
                        "state" to if (paused) "paused" else "playing",
                        "isPlaying" to !paused
                    ))
                    if (paused) stopProgressTimer() else startProgressTimer()
                }
                "paused-for-cache" -> {
                    val buffering = value as? Boolean ?: false
                    onBuffer(mapOf("isBuffering" to buffering))
                }
                "volume", "mute" -> {
                    onVolumeChange(mapOf("volume" to cachedVolume, "muted" to cachedMute))
                }
            }
        }
    }

    fun onEndFile(reason: String, error: String) {
        mainHandler.post {
            stopProgressTimer()
            if (reason == "error" && error.isNotEmpty()) {
                onError(mapOf("error" to "Playback error: $error"))
            }
            onEnd(mapOf("reason" to reason))
        }
    }

    fun onLogMessage(prefix: String, level: String, text: String) {
        android.util.Log.d("ExpoMpv", "[$prefix] [$level] $text")
    }

    // MARK: - Progress Timer

    private fun startProgressTimer() {
        stopProgressTimer()
        progressRunnable = object : Runnable {
            override fun run() {
                emitProgressEvent()
                mainHandler.postDelayed(this, 250)
            }
        }
        mainHandler.post(progressRunnable!!)
    }

    private fun stopProgressTimer() {
        progressRunnable?.let { mainHandler.removeCallbacks(it) }
        progressRunnable = null
    }

    private fun emitProgressEvent() {
        if (nativePtr == 0L) return
        val position = cachedTimePos
        val duration = cachedDuration
        val cachedDur = cachedCacheDuration
        if (!position.isFinite() || !duration.isFinite()) return
        onProgress(mapOf(
            "position" to position,
            "duration" to duration,
            "bufferedDuration" to (if (cachedDur.isFinite()) cachedDur else 0.0)
        ))
    }

    // MARK: - Public API

    fun loadFile(url: String) {
        if (!isInitialized || nativePtr == 0L) {
            pendingSource = url
            return
        }
        if (!surfaceView.holder.surface.isValid) {
            pendingSource = url
            return
        }
        command("loadfile", url, "replace")
    }

    fun play() { setPropertyBoolean("pause", false) }
    fun pause() { setPropertyBoolean("pause", true) }
    fun togglePlay() {
        val isPaused = getPropertyBoolean("pause")
        setPropertyBoolean("pause", !isPaused)
    }
    fun stop() { command("stop"); stopProgressTimer() }
    fun seekTo(position: Double) { command("seek", position.toString(), "absolute") }
    fun seekBy(offset: Double) { command("seek", offset.toString(), "relative") }
    fun setSpeed(speed: Double) { setPropertyDouble("speed", speed) }
    fun setVolume(volume: Double) { setPropertyDouble("volume", volume) }
    fun setMuted(muted: Boolean) { setPropertyBoolean("mute", muted) }
    fun setLooping(loop: Boolean) { setPropertyString("loop-file", if (loop) "inf" else "no") }

    fun setHwdec(mode: String) {
        if (isInitialized && nativePtr != 0L) {
            // Runtime change — set as property
            setPropertyString("hwdec", mode)
        }
        // Also store for next createMpv if view is recreated
        pendingHwdec = mode
    }
    fun setSubtitleTrack(trackId: Int) { setPropertyLong("sid", trackId.toLong()) }
    fun setAudioTrack(trackId: Int) { setPropertyLong("aid", trackId.toLong()) }

    fun addSubtitle(path: String, flag: String, title: String?, lang: String?) {
        val args = mutableListOf(path, flag)
        if (title != null) args.add(title) else if (lang != null) args.add("")
        if (lang != null) args.add(lang)
        commandArray("sub-add", args)
    }

    fun removeSubtitle(trackId: Int) { command("sub-remove", trackId.toString()) }
    fun reloadSubtitles() { command("sub-reload") }
    fun setSubtitleDelay(seconds: Double) { setPropertyDouble("sub-delay", seconds) }

    fun setPropertyString(name: String, value: String) {
        if (nativePtr == 0L) return
        MPVLib.nativeSetPropertyString(nativePtr, name, value)
    }

    fun getPlaybackInfo(): Map<String, Any> {
        return mapOf(
            "position" to (if (cachedTimePos.isFinite()) cachedTimePos else 0.0),
            "duration" to (if (cachedDuration.isFinite()) cachedDuration else 0.0),
            "isPlaying" to !cachedPause,
            "speed" to cachedSpeed,
            "volume" to cachedVolume,
            "muted" to cachedMute
        )
    }

    fun getTrackList(): List<Map<String, Any>> {
        if (nativePtr == 0L) return emptyList()
        val count = getPropertyLong("track-list/count").toInt()
        val tracks = mutableListOf<Map<String, Any>>()
        for (i in 0 until count) {
            val prefix = "track-list/$i"
            val type = getPropertyString("$prefix/type") ?: "unknown"
            val track = mutableMapOf<String, Any>(
                "id" to getPropertyLong("$prefix/id").toInt(),
                "type" to type,
                "title" to (getPropertyString("$prefix/title") ?: ""),
                "lang" to (getPropertyString("$prefix/lang") ?: ""),
                "codec" to (getPropertyString("$prefix/codec") ?: ""),
                "selected" to getPropertyBoolean("$prefix/selected"),
                "isDefault" to getPropertyBoolean("$prefix/default"),
                "isExternal" to getPropertyBoolean("$prefix/external")
            )
            when (type) {
                "audio" -> {
                    track["channelCount"] = getPropertyLong("$prefix/demux-channel-count").toInt()
                    track["sampleRate"] = getPropertyLong("$prefix/demux-samplerate").toInt()
                }
                "video" -> {
                    track["width"] = getPropertyLong("$prefix/demux-w").toInt()
                    track["height"] = getPropertyLong("$prefix/demux-h").toInt()
                    track["fps"] = getPropertyDouble("$prefix/demux-fps")
                }
            }
            tracks.add(track)
        }
        return tracks
    }

    fun getCurrentTrackIds(): Map<String, Int> {
        if (nativePtr == 0L) return emptyMap()
        return mapOf(
            "vid" to getPropertyLong("vid").toInt(),
            "aid" to getPropertyLong("aid").toInt(),
            "sid" to getPropertyLong("sid").toInt()
        )
    }

    fun getMediaInfo(): Map<String, Any> {
        if (nativePtr == 0L) return emptyMap()

        val hwdec = getPropertyString("hwdec") ?: ""
        val hwdecCurrent = getPropertyString("hwdec-current") ?: ""
        val videoCodec = getPropertyString("video-codec") ?: ""
        val audioCodec = getPropertyString("audio-codec-name") ?: ""
        val width = getPropertyLong("video-params/w").toInt()
        val height = getPropertyLong("video-params/h").toInt()
        val fps = getPropertyDouble("container-fps")
        val videoBitrate = getPropertyDouble("video-bitrate")
        val audioBitrate = getPropertyDouble("audio-bitrate")
        val pixelFormat = getPropertyString("video-params/pixelformat") ?: ""
        val colorspace = getPropertyString("video-params/colormatrix") ?: ""

        return mapOf(
            "hwdec" to hwdec,
            "hwdecCurrent" to hwdecCurrent,
            "videoCodec" to videoCodec,
            "audioCodec" to audioCodec,
            "width" to width,
            "height" to height,
            "fps" to (if (fps.isFinite()) fps else 0.0),
            "videoBitrate" to (if (videoBitrate.isFinite()) videoBitrate else 0.0),
            "audioBitrate" to (if (audioBitrate.isFinite()) audioBitrate else 0.0),
            "pixelFormat" to pixelFormat,
            "colorspace" to colorspace
        )
    }

    // MARK: - Property Helpers

    private fun getPropertyDouble(name: String): Double {
        if (nativePtr == 0L) return 0.0
        return MPVLib.nativeGetPropertyDouble(nativePtr, name)
    }
    private fun getPropertyLong(name: String): Long {
        if (nativePtr == 0L) return 0
        return MPVLib.nativeGetPropertyLong(nativePtr, name)
    }
    private fun getPropertyBoolean(name: String): Boolean {
        if (nativePtr == 0L) return false
        return MPVLib.nativeGetPropertyBoolean(nativePtr, name)
    }
    private fun getPropertyString(name: String): String? {
        if (nativePtr == 0L) return null
        return MPVLib.nativeGetPropertyString(nativePtr, name)
    }
    private fun setPropertyDouble(name: String, value: Double) {
        if (nativePtr == 0L) return
        MPVLib.nativeSetPropertyDouble(nativePtr, name, value)
    }
    private fun setPropertyLong(name: String, value: Long) {
        if (nativePtr == 0L) return
        MPVLib.nativeSetPropertyLong(nativePtr, name, value)
    }
    private fun setPropertyBoolean(name: String, value: Boolean) {
        if (nativePtr == 0L) return
        MPVLib.nativeSetPropertyBoolean(nativePtr, name, value)
    }
    private fun command(vararg args: String) {
        if (nativePtr == 0L) return
        MPVLib.nativeCommand(nativePtr, args.toList().toTypedArray())
    }
    private fun commandArray(cmd: String, args: List<String>) {
        if (nativePtr == 0L) return
        MPVLib.nativeCommand(nativePtr, (listOf(cmd) + args).toTypedArray())
    }

    companion object {
        private fun isEmulator(): Boolean {
            return (Build.FINGERPRINT.startsWith("generic")
                    || Build.FINGERPRINT.startsWith("unknown")
                    || Build.MODEL.contains("google_sdk")
                    || Build.MODEL.contains("Emulator")
                    || Build.MODEL.contains("Android SDK built for x86")
                    || Build.BOARD == "QC_Reference_Phone"
                    || Build.MANUFACTURER.contains("Genymotion")
                    || Build.HOST.startsWith("Build")
                    || Build.BRAND.startsWith("generic")
                    || Build.DEVICE.startsWith("generic")
                    || Build.PRODUCT == "google_sdk"
                    || Build.PRODUCT.startsWith("sdk")
                    || Build.PRODUCT.endsWith("_cf")
                    || Build.HARDWARE.contains("goldfish")
                    || Build.HARDWARE.contains("ranchu"))
        }
    }
}
