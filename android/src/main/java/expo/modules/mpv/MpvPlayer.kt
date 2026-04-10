package expo.modules.mpv

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import android.view.Surface
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

internal class MpvPlayer(
    context: Context,
    private val listener: Listener,
) {
    interface Listener {
        fun onPlaybackStateChange(state: String, isPlaying: Boolean)
        fun onProgress(position: Double, duration: Double, bufferedDuration: Double)
        fun onLoad(duration: Double, width: Int, height: Int)
        fun onError(message: String)
        fun onEnd(reason: String)
        fun onBuffer(isBuffering: Boolean)
        fun onSeek()
        fun onVolumeChange(volume: Double, muted: Boolean)
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val playerThread = HandlerThread("ExpoMpvPlayer").apply { start() }
    private val playerHandler = Handler(playerThread.looper)

    @Volatile private var nativePtr: Long = 0
    @Volatile private var isInitialized = false
    @Volatile private var isDestroyed = false

    private var attachedSurface: Surface? = null
    private var pendingSource: String? = null
    private var pendingHwdec: String = if (isEmulator()) "no" else "mediacodec"
    private var progressRunnable: Runnable? = null
    private var lastProgressEmitPosition: Double = Double.NaN
    private var lastProgressEmitDuration: Double = Double.NaN
    private var lastProgressEmitBufferedDuration: Double = Double.NaN
    private var lastBufferingState: Boolean? = null
    private var hasPauseState = false

    @Volatile private var cachedTimePos: Double = 0.0
    @Volatile private var cachedDuration: Double = 0.0
    @Volatile private var cachedCacheDuration: Double = 0.0
    @Volatile private var cachedPause: Boolean = false
    @Volatile private var cachedVolume: Double = 100.0
    @Volatile private var cachedMute: Boolean = false
    @Volatile private var cachedSpeed: Double = 1.0
    @Volatile private var cachedVideoW: Long = 0
    @Volatile private var cachedVideoH: Long = 0

    init {
        runOnPlayerThread {
            createMpvLocked()
        }
    }

    fun release() {
        if (isDestroyed) return
        stopProgressTimer()
        playerHandler.post {
            if (isDestroyed) return@post
            isDestroyed = true
            pendingSource = null
            attachedSurface = null

            val ptr = nativePtr
            nativePtr = 0
            isInitialized = false

            if (ptr != 0L) {
                MPVLib.nativeDestroy(ptr)
            }

            playerThread.quitSafely()
        }
    }

    fun setSurface(surface: Surface?) {
        runOnPlayerThread {
            if (isDestroyed) return@runOnPlayerThread
            attachedSurface = surface?.takeIf { it.isValid }
            updateSurfaceLocked()
            maybeLoadPendingSourceLocked()
        }
    }

    fun loadFile(url: String) {
        runOnPlayerThread {
            if (!isPlayerReadyLocked()) {
                pendingSource = url
                return@runOnPlayerThread
            }

            pendingSource = null
            commandLocked("loadfile", url, "replace")
        }
    }

    fun play() {
        runOnPlayerThread {
            setPropertyBooleanLocked("pause", false)
        }
    }

    fun pause() {
        runOnPlayerThread {
            setPropertyBooleanLocked("pause", true)
        }
    }

    fun togglePlay() {
        runOnPlayerThread {
            setPropertyBooleanLocked("pause", !cachedPause)
        }
    }

    fun stop() {
        runOnPlayerThread {
            commandLocked("stop")
        }
        stopProgressTimer()
    }

    fun seekTo(position: Double) {
        runOnPlayerThread {
            commandLocked("seek", position.toString(), "absolute")
        }
    }

    fun seekBy(offset: Double) {
        runOnPlayerThread {
            commandLocked("seek", offset.toString(), "relative")
        }
    }

    fun setSpeed(speed: Double) {
        runOnPlayerThread {
            setPropertyDoubleLocked("speed", speed)
        }
    }

    fun setVolume(volume: Double) {
        runOnPlayerThread {
            setPropertyDoubleLocked("volume", volume)
        }
    }

    fun setMuted(muted: Boolean) {
        runOnPlayerThread {
            setPropertyBooleanLocked("mute", muted)
        }
    }

    fun setLooping(loop: Boolean) {
        runOnPlayerThread {
            setPropertyStringLocked("loop-file", if (loop) "inf" else "no")
        }
    }

    fun setHwdec(mode: String) {
        runOnPlayerThread {
            pendingHwdec = mode
            if (isInitialized && nativePtr != 0L) {
                setPropertyStringLocked("hwdec", mode)
            }
        }
    }

    fun setSubtitleTrack(trackId: Int) {
        runOnPlayerThread {
            setPropertyLongLocked("sid", trackId.toLong())
        }
    }

    fun setAudioTrack(trackId: Int) {
        runOnPlayerThread {
            setPropertyLongLocked("aid", trackId.toLong())
        }
    }

    fun addSubtitle(path: String, flag: String, title: String?, lang: String?) {
        runOnPlayerThread {
            val args = mutableListOf(path, flag)
            if (title != null) {
                args.add(title)
            } else if (lang != null) {
                args.add("")
            }
            if (lang != null) {
                args.add(lang)
            }
            commandArrayLocked("sub-add", args)
        }
    }

    fun removeSubtitle(trackId: Int) {
        runOnPlayerThread {
            commandLocked("sub-remove", trackId.toString())
        }
    }

    fun reloadSubtitles() {
        runOnPlayerThread {
            commandLocked("sub-reload")
        }
    }

    fun setSubtitleDelay(seconds: Double) {
        runOnPlayerThread {
            setPropertyDoubleLocked("sub-delay", seconds)
        }
    }

    fun setPropertyString(name: String, value: String) {
        runOnPlayerThread {
            setPropertyStringLocked(name, value)
        }
    }

    fun getPlaybackInfo(): Map<String, Any> {
        return mapOf(
            "position" to (if (cachedTimePos.isFinite()) cachedTimePos else 0.0),
            "duration" to (if (cachedDuration.isFinite()) cachedDuration else 0.0),
            "isPlaying" to !cachedPause,
            "speed" to cachedSpeed,
            "volume" to cachedVolume,
            "muted" to cachedMute,
        )
    }

    fun getTrackList(): List<Map<String, Any>> {
        return runOnPlayerThreadSync(emptyList<Map<String, Any>>()) {
            if (nativePtr == 0L) return@runOnPlayerThreadSync emptyList<Map<String, Any>>()

            val count = getPropertyLongLocked("track-list/count").toInt()
            val tracks = mutableListOf<Map<String, Any>>()
            for (index in 0 until count) {
                val prefix = "track-list/$index"
                val type = getPropertyStringLocked("$prefix/type") ?: "unknown"
                val track = mutableMapOf<String, Any>(
                    "id" to getPropertyLongLocked("$prefix/id").toInt(),
                    "type" to type,
                    "title" to (getPropertyStringLocked("$prefix/title") ?: ""),
                    "lang" to (getPropertyStringLocked("$prefix/lang") ?: ""),
                    "codec" to (getPropertyStringLocked("$prefix/codec") ?: ""),
                    "selected" to getPropertyBooleanLocked("$prefix/selected"),
                    "isDefault" to getPropertyBooleanLocked("$prefix/default"),
                    "isExternal" to getPropertyBooleanLocked("$prefix/external"),
                )

                when (type) {
                    "audio" -> {
                        track["channelCount"] = getPropertyLongLocked("$prefix/demux-channel-count").toInt()
                        track["sampleRate"] = getPropertyLongLocked("$prefix/demux-samplerate").toInt()
                    }

                    "video" -> {
                        track["width"] = getPropertyLongLocked("$prefix/demux-w").toInt()
                        track["height"] = getPropertyLongLocked("$prefix/demux-h").toInt()
                        track["fps"] = getPropertyDoubleLocked("$prefix/demux-fps")
                    }
                }

                tracks.add(track)
            }

            tracks
        }
    }

    fun getCurrentTrackIds(): Map<String, Int> {
        return runOnPlayerThreadSync(emptyMap<String, Int>()) {
            if (nativePtr == 0L) return@runOnPlayerThreadSync emptyMap<String, Int>()

            mapOf(
                "vid" to getPropertyLongLocked("vid").toInt(),
                "aid" to getPropertyLongLocked("aid").toInt(),
                "sid" to getPropertyLongLocked("sid").toInt(),
            )
        }
    }

    fun getMediaInfo(): Map<String, Any> {
        return runOnPlayerThreadSync(emptyMap<String, Any>()) {
            if (nativePtr == 0L) return@runOnPlayerThreadSync emptyMap<String, Any>()

            val hwdec = getPropertyStringLocked("hwdec") ?: ""
            val hwdecCurrent = getPropertyStringLocked("hwdec-current") ?: ""
            val videoCodec = getPropertyStringLocked("video-codec") ?: ""
            val audioCodec = getPropertyStringLocked("audio-codec-name") ?: ""
            val width = getPropertyLongLocked("video-params/w").toInt()
            val height = getPropertyLongLocked("video-params/h").toInt()
            val fps = getPropertyDoubleLocked("container-fps")
            val videoBitrate = getPropertyDoubleLocked("video-bitrate")
            val audioBitrate = getPropertyDoubleLocked("audio-bitrate")
            val pixelFormat = getPropertyStringLocked("video-params/pixelformat") ?: ""
            val colorspace = getPropertyStringLocked("video-params/colormatrix") ?: ""

            mapOf(
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
                "colorspace" to colorspace,
            )
        }
    }

    fun onEvent(eventId: Int) {
        when (eventId) {
            MPVLib.EVENT_FILE_LOADED -> {
                runOnPlayerThread {
                    refreshCachedPlaybackSnapshotLocked()
                    if (!hasPauseState) {
                        cachedPause = getPropertyBooleanLocked("pause")
                        hasPauseState = true
                        dispatchPlaybackState()
                    } else {
                        updateProgressTimer()
                    }
                    dispatchOnMain {
                        listener.onLoad(
                            if (cachedDuration.isFinite()) cachedDuration else 0.0,
                            cachedVideoW.toInt(),
                            cachedVideoH.toInt(),
                        )
                    }
                }
            }

            MPVLib.EVENT_SEEK -> {
                dispatchOnMain {
                    listener.onSeek()
                }
            }

            MPVLib.EVENT_SHUTDOWN -> {
                isInitialized = false
                stopProgressTimer()
            }
        }
    }

    fun onPropertyChange(name: String, value: Any?) {
        when (name) {
            "time-pos" -> cachedTimePos = (value as? Double) ?: 0.0
            "duration" -> cachedDuration = (value as? Double) ?: 0.0
            "demuxer-cache-duration" -> cachedCacheDuration = (value as? Double) ?: 0.0
            "pause" -> {
                val paused = (value as? Boolean) ?: false
                if (hasPauseState && paused == cachedPause) return
                cachedPause = paused
                hasPauseState = true
                dispatchPlaybackState()
            }

            "paused-for-cache" -> {
                val buffering = (value as? Boolean) ?: false
                if (buffering == lastBufferingState) return
                lastBufferingState = buffering
                dispatchOnMain {
                    listener.onBuffer(buffering)
                }
            }

            "volume" -> {
                val volume = (value as? Double) ?: 0.0
                if (volume == cachedVolume) return
                cachedVolume = volume
                dispatchOnMain {
                    listener.onVolumeChange(cachedVolume, cachedMute)
                }
            }

            "mute" -> {
                val mute = (value as? Boolean) ?: false
                if (mute == cachedMute) return
                cachedMute = mute
                dispatchOnMain {
                    listener.onVolumeChange(cachedVolume, cachedMute)
                }
            }

            "speed" -> cachedSpeed = (value as? Double) ?: 1.0
            "video-params/w" -> cachedVideoW = (value as? Long) ?: 0
            "video-params/h" -> cachedVideoH = (value as? Long) ?: 0
        }
    }

    fun onEndFile(reason: String, error: String) {
        stopProgressTimer()
        dispatchOnMain {
            if (reason == "error" && error.isNotEmpty()) {
                listener.onError("Playback error: $error")
            }
            listener.onEnd(reason)
        }
    }

    fun onLogMessage(prefix: String, level: String, text: String) {
        Log.d("ExpoMpv", "[$prefix] [$level] $text")
    }

    private fun createMpvLocked() {
        if (isDestroyed) return

        nativePtr = MPVLib.nativeCreate()
        if (nativePtr == 0L) {
            emitError("Failed to create mpv instance")
            return
        }

        MPVLib.nativeSetCallback(nativePtr, this)

        MPVLib.nativeSetOptionString(nativePtr, "vo", "gpu")
        MPVLib.nativeSetOptionString(nativePtr, "gpu-context", "android")
        MPVLib.nativeSetOptionString(nativePtr, "opengl-es", "yes")
        MPVLib.nativeSetOptionString(nativePtr, "hwdec", pendingHwdec)
        if (pendingHwdec != "no") {
            MPVLib.nativeSetOptionString(nativePtr, "hwdec-codecs", "h264,hevc,mpeg4,mpeg2video,vp8,vp9,av1")
        }

        if (isEmulator()) {
            Log.w("ExpoMpv", "Emulator detected, hardware decoding disabled (using software decoding)")
        }

        MPVLib.nativeSetOptionString(nativePtr, "video-sync", "audio")
        MPVLib.nativeSetOptionString(nativePtr, "audio-pitch-correction", "yes")
        MPVLib.nativeSetOptionString(nativePtr, "autosync", "0")
        MPVLib.nativeSetOptionString(nativePtr, "correct-pts", "yes")
        MPVLib.nativeSetOptionString(nativePtr, "framedrop", "vo")
        MPVLib.nativeSetOptionString(nativePtr, "scale", "bilinear")
        MPVLib.nativeSetOptionString(nativePtr, "dscale", "bilinear")
        MPVLib.nativeSetOptionString(nativePtr, "interpolation", "no")
        MPVLib.nativeSetOptionString(nativePtr, "ao", "audiotrack")
        MPVLib.nativeSetOptionString(nativePtr, "audio-buffer", "2.0")

        MPVLib.nativeSetOptionString(nativePtr, "cache", "yes")
        MPVLib.nativeSetOptionString(nativePtr, "demuxer-max-bytes", "64M")
        MPVLib.nativeSetOptionString(nativePtr, "demuxer-max-back-bytes", "16M")
        MPVLib.nativeSetOptionString(nativePtr, "cache-pause", "yes")
        MPVLib.nativeSetOptionString(nativePtr, "cache-pause-initial", "yes")

        MPVLib.nativeSetOptionString(nativePtr, "force-window", "yes")
        MPVLib.nativeSetOptionString(nativePtr, "keep-open", "yes")
        MPVLib.nativeSetOptionString(nativePtr, "idle", "yes")
        MPVLib.nativeSetOptionString(nativePtr, "input-default-bindings", "no")
        MPVLib.nativeSetOptionString(nativePtr, "input-vo-keyboard", "no")

        updateSurfaceLocked()
    }

    private fun updateSurfaceLocked() {
        val ptr = nativePtr
        val surface = attachedSurface
        if (ptr == 0L) return

        if (surface == null || !surface.isValid) {
            if (isInitialized) {
                MPVLib.nativeDetachSurface(ptr)
            }
            return
        }

        if (!isInitialized) {
            MPVLib.nativeAttachSurface(ptr, surface)
            if (!initializeMpvLocked()) return
        } else {
            MPVLib.nativeReattachSurface(ptr, surface)
        }
    }

    private fun initializeMpvLocked(): Boolean {
        if (nativePtr == 0L || isDestroyed) return false
        if (isInitialized) return true

        val ret = MPVLib.nativeInitialize(nativePtr)
        if (ret < 0) {
            emitError("mpv_initialize failed: $ret")
            return false
        }

        isInitialized = true
        observePropertiesLocked()
        return true
    }

    private fun observePropertiesLocked() {
        val ptr = nativePtr
        if (ptr == 0L) return

        MPVLib.nativeObserveProperty(ptr, "pause", MPVLib.FORMAT_FLAG)
        MPVLib.nativeObserveProperty(ptr, "duration", MPVLib.FORMAT_DOUBLE)
        MPVLib.nativeObserveProperty(ptr, "time-pos", MPVLib.FORMAT_DOUBLE)
        MPVLib.nativeObserveProperty(ptr, "paused-for-cache", MPVLib.FORMAT_FLAG)
        MPVLib.nativeObserveProperty(ptr, "volume", MPVLib.FORMAT_DOUBLE)
        MPVLib.nativeObserveProperty(ptr, "mute", MPVLib.FORMAT_FLAG)
        MPVLib.nativeObserveProperty(ptr, "speed", MPVLib.FORMAT_DOUBLE)
        MPVLib.nativeObserveProperty(ptr, "demuxer-cache-duration", MPVLib.FORMAT_DOUBLE)
        MPVLib.nativeObserveProperty(ptr, "video-params/w", MPVLib.FORMAT_INT64)
        MPVLib.nativeObserveProperty(ptr, "video-params/h", MPVLib.FORMAT_INT64)
    }

    private fun maybeLoadPendingSourceLocked() {
        val source = pendingSource ?: return
        if (!isPlayerReadyLocked()) return

        pendingSource = null
        commandLocked("loadfile", source, "replace")
    }

    private fun isPlayerReadyLocked(): Boolean {
        return nativePtr != 0L && isInitialized && attachedSurface?.isValid == true
    }

    private fun refreshCachedPlaybackSnapshotLocked() {
        val ptr = nativePtr
        if (ptr == 0L) return

        val duration = getPropertyDoubleLocked("duration")
        if (duration.isFinite() && duration >= 0) {
            cachedDuration = duration
        }

        val timePos = getPropertyDoubleLocked("time-pos")
        if (timePos.isFinite() && timePos >= 0) {
            cachedTimePos = timePos
        }

        val cacheDuration = getPropertyDoubleLocked("demuxer-cache-duration")
        if (cacheDuration.isFinite() && cacheDuration >= 0) {
            cachedCacheDuration = cacheDuration
        }

        val width = getPropertyLongLocked("video-params/w")
        if (width > 0) {
            cachedVideoW = width
        }

        val height = getPropertyLongLocked("video-params/h")
        if (height > 0) {
            cachedVideoH = height
        }
    }

    private fun dispatchPlaybackState() {
        dispatchOnMain {
            listener.onPlaybackStateChange(
                if (cachedPause) "paused" else "playing",
                !cachedPause,
            )
            updateProgressTimer()
        }
    }

    private fun updateProgressTimer() {
        if (isDestroyed || !isInitialized || nativePtr == 0L || cachedPause || attachedSurface?.isValid != true) {
            stopProgressTimer()
        } else if (progressRunnable == null) {
            startProgressTimer()
        }
    }

    private fun startProgressTimer() {
        stopProgressTimer()
        progressRunnable = object : Runnable {
            override fun run() {
                emitProgressEvent()
                if (!isDestroyed && progressRunnable === this) {
                    mainHandler.postDelayed(this, 500)
                }
            }
        }
        mainHandler.post(progressRunnable!!)
    }

    private fun stopProgressTimer() {
        progressRunnable?.let { mainHandler.removeCallbacks(it) }
        progressRunnable = null
        lastProgressEmitPosition = Double.NaN
        lastProgressEmitDuration = Double.NaN
        lastProgressEmitBufferedDuration = Double.NaN
    }

    private fun emitProgressEvent() {
        if (isDestroyed || !isInitialized || cachedPause || attachedSurface?.isValid != true) return

        val position = cachedTimePos
        val duration = cachedDuration
        val bufferedDuration = if (cachedCacheDuration.isFinite()) cachedCacheDuration else 0.0
        if (!position.isFinite() || !duration.isFinite()) return

        val positionChangedEnough =
            lastProgressEmitPosition.isNaN() || kotlin.math.abs(position - lastProgressEmitPosition) >= 0.25
        val durationChanged = lastProgressEmitDuration.isNaN() || duration != lastProgressEmitDuration
        val bufferedChangedEnough =
            lastProgressEmitBufferedDuration.isNaN() ||
                kotlin.math.abs(bufferedDuration - lastProgressEmitBufferedDuration) >= 0.25

        if (!positionChangedEnough && !durationChanged && !bufferedChangedEnough) {
            return
        }

        lastProgressEmitPosition = position
        lastProgressEmitDuration = duration
        lastProgressEmitBufferedDuration = bufferedDuration

        listener.onProgress(position, duration, bufferedDuration)
    }

    private fun emitError(message: String) {
        dispatchOnMain {
            listener.onError(message)
        }
    }

    private fun dispatchOnMain(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            if (!isDestroyed) {
                block()
            }
            return
        }

        mainHandler.post {
            if (!isDestroyed) {
                block()
            }
        }
    }

    private fun <T> runOnPlayerThreadSync(defaultValue: T, block: () -> T): T {
        if (isDestroyed) return defaultValue
        if (Looper.myLooper() == playerThread.looper) return block()

        val latch = CountDownLatch(1)
        var result = defaultValue
        val posted = playerHandler.post {
            try {
                if (!isDestroyed) {
                    result = block()
                }
            } finally {
                latch.countDown()
            }
        }

        if (!posted) return defaultValue

        return if (latch.await(3, TimeUnit.SECONDS)) result else defaultValue
    }

    private fun runOnPlayerThread(block: () -> Unit) {
        if (isDestroyed && Looper.myLooper() != playerThread.looper) return
        if (Looper.myLooper() == playerThread.looper) {
            block()
        } else {
            playerHandler.post(block)
        }
    }

    private fun getPropertyDoubleLocked(name: String): Double {
        if (nativePtr == 0L) return 0.0
        return MPVLib.nativeGetPropertyDouble(nativePtr, name)
    }

    private fun getPropertyLongLocked(name: String): Long {
        if (nativePtr == 0L) return 0
        return MPVLib.nativeGetPropertyLong(nativePtr, name)
    }

    private fun getPropertyBooleanLocked(name: String): Boolean {
        if (nativePtr == 0L) return false
        return MPVLib.nativeGetPropertyBoolean(nativePtr, name)
    }

    private fun getPropertyStringLocked(name: String): String? {
        if (nativePtr == 0L) return null
        return MPVLib.nativeGetPropertyString(nativePtr, name)
    }

    private fun setPropertyDoubleLocked(name: String, value: Double) {
        if (nativePtr == 0L) return
        MPVLib.nativeSetPropertyDouble(nativePtr, name, value)
    }

    private fun setPropertyLongLocked(name: String, value: Long) {
        if (nativePtr == 0L) return
        MPVLib.nativeSetPropertyLong(nativePtr, name, value)
    }

    private fun setPropertyBooleanLocked(name: String, value: Boolean) {
        if (nativePtr == 0L) return
        MPVLib.nativeSetPropertyBoolean(nativePtr, name, value)
    }

    private fun setPropertyStringLocked(name: String, value: String) {
        if (nativePtr == 0L) return
        MPVLib.nativeSetPropertyString(nativePtr, name, value)
    }

    private fun commandLocked(vararg args: String) {
        if (nativePtr == 0L) return
        MPVLib.nativeCommand(nativePtr, args.toList().toTypedArray())
    }

    private fun commandArrayLocked(command: String, args: List<String>) {
        if (nativePtr == 0L) return
        MPVLib.nativeCommand(nativePtr, (listOf(command) + args).toTypedArray())
    }

    companion object {
        private fun isEmulator(): Boolean {
            return (
                Build.FINGERPRINT.startsWith("generic") ||
                    Build.FINGERPRINT.startsWith("unknown") ||
                    Build.MODEL.contains("google_sdk") ||
                    Build.MODEL.contains("Emulator") ||
                    Build.MODEL.contains("Android SDK built for x86") ||
                    Build.BOARD == "QC_Reference_Phone" ||
                    Build.MANUFACTURER.contains("Genymotion") ||
                    Build.HOST.startsWith("Build") ||
                    Build.BRAND.startsWith("generic") ||
                    Build.DEVICE.startsWith("generic") ||
                    Build.PRODUCT == "google_sdk" ||
                    Build.PRODUCT.startsWith("sdk") ||
                    Build.PRODUCT.endsWith("_cf") ||
                    Build.HARDWARE.contains("goldfish") ||
                    Build.HARDWARE.contains("ranchu")
                )
        }
    }
}
