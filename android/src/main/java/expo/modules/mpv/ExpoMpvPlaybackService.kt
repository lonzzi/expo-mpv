package expo.modules.mpv

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors
import java.util.concurrent.Future

/** The service holds the active engine, independently of its video Surface. */
class ExpoMpvPlaybackService : Service() {
    companion object {
        private const val CHANNEL = "expo-mpv-playback"
        private const val NOTIFICATION = 47821
        private var owner: MpvPlayer? = null
        private var metadata: Map<String, String> = emptyMap()
        private var instance: ExpoMpvPlaybackService? = null
        private var application: Context? = null
        private val handler = Handler(Looper.getMainLooper())

        internal fun attach(context: Context, player: MpvPlayer, info: Map<String, String>) {
            if (owner === player && metadata == info) return
            val previous = owner
            owner = player
            metadata = info
            application = context.applicationContext
            try {
                val service = instance
                if (service != null) {
                    service.publish()
                } else {
                    val intent = Intent(context, ExpoMpvPlaybackService::class.java)
                    if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent)
                    else context.startService(intent)
                }
            } catch (error: RuntimeException) {
                owner = previous
                Log.e("ExpoMpv", "Unable to start media playback service", error)
            }
        }

        internal fun update(player: MpvPlayer) {
            if (owner === player) instance?.publish()
        }

        internal fun cancelFocusResume(player: MpvPlayer) {
            if (owner === player) instance?.resumeAfterFocus = false
        }

        internal fun detach(player: MpvPlayer) {
            if (owner !== player) return
            owner = null
            metadata = emptyMap()
            // React can drop the previous view immediately before mounting the
            // next one. Do not enqueue a service stop that kills its successor.
            handler.postDelayed({
                if (owner == null) {
                    instance?.stopSelf() ?: application?.let {
                        it.stopService(Intent(it, ExpoMpvPlaybackService::class.java))
                    }
                }
            }, 500)
        }
    }

    private lateinit var session: MediaSession
    private lateinit var audio: AudioManager
    private var focusRequest: AudioFocusRequest? = null
    private var hasFocus = false
    private var resumeAfterFocus = false
    private var foreground = false
    private var artworkUri: String? = null
    private var artwork: Bitmap? = null
    private val artworkExecutor = Executors.newSingleThreadExecutor()
    private var artworkTask: Future<*>? = null
    private var artworkGeneration = 0
    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        when (change) {
            AudioManager.AUDIOFOCUS_LOSS, AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                resumeAfterFocus = change != AudioManager.AUDIOFOCUS_LOSS && owner?.sessionPlaying == true
                owner?.pauseForAudioFocus()
                hasFocus = false
            }
            AudioManager.AUDIOFOCUS_GAIN -> {
                hasFocus = true
                if (resumeAfterFocus) owner?.play()
                resumeAfterFocus = false
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        audio = getSystemService(AUDIO_SERVICE) as AudioManager
        session = MediaSession(this, "ExpoMpv").apply {
            setFlags(MediaSession.FLAG_HANDLES_MEDIA_BUTTONS or MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS)
            setCallback(object : MediaSession.Callback() {
                override fun onPlay() { owner?.play() }
                override fun onPause() { owner?.pause() }
                override fun onSeekTo(pos: Long) { owner?.seekTo(pos / 1000.0) }
                override fun onStop() { owner?.stop() }
            }, Handler(Looper.getMainLooper()))
            isActive = true
        }
        if (Build.VERSION.SDK_INT >= 26) {
            (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).createNotificationChannel(
                NotificationChannel(CHANNEL, "Media playback", NotificationManager.IMPORTANCE_LOW)
            )
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (owner == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        when (intent?.action) {
            "play" -> owner?.play()
            "pause" -> owner?.pause()
        }
        publish()
        return START_NOT_STICKY
    }

    private fun action(name: String): PendingIntent = PendingIntent.getService(
        this, if (name == "play") 1 else 2,
        Intent(this, ExpoMpvPlaybackService::class.java).setAction(name),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    private fun publish() {
        val player = owner ?: return
        updateArtwork(metadata["artwork"]?.takeIf { it.isNotBlank() })
        val playing = player.sessionPlaying
        val title = metadata["title"]?.takeIf { it.isNotBlank() }
            ?: applicationInfo.loadLabel(packageManager).toString()
        val position = player.sessionPosition
        session.setMetadata(MediaMetadata.Builder()
            .putString(MediaMetadata.METADATA_KEY_TITLE, title)
            .putString(MediaMetadata.METADATA_KEY_ARTIST, metadata["artist"])
            .putString(MediaMetadata.METADATA_KEY_ALBUM, metadata["albumTitle"])
            .putLong(MediaMetadata.METADATA_KEY_DURATION, player.sessionDuration)
            .putBitmap(MediaMetadata.METADATA_KEY_ART, artwork)
            .putBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART, artwork)
            .build())
        session.setPlaybackState(PlaybackState.Builder()
            .setActions(PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or
                PlaybackState.ACTION_PLAY_PAUSE or PlaybackState.ACTION_SEEK_TO or PlaybackState.ACTION_STOP)
            .setState(if (playing) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED,
                position, if (playing) player.sessionSpeed else 0f)
            .build())
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL)
            else Notification.Builder(this)
        val notification = builder
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle(title)
            .setContentText(metadata["artist"])
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setOnlyAlertOnce(true)
            .setOngoing(playing)
            .setLargeIcon(artwork)
            .setStyle(Notification.MediaStyle().setMediaSession(session.sessionToken).setShowActionsInCompactView(0))
            .addAction(Notification.Action.Builder(
                if (playing) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
                if (playing) "Pause" else "Play", action(if (playing) "pause" else "play")
            ).build())
        packageManager.getLaunchIntentForPackage(packageName)?.let { launch ->
            val pending = PendingIntent.getActivity(this, 0, launch,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            builder.setContentIntent(pending)
            session.setSessionActivity(pending)
        }
        if (Build.VERSION.SDK_INT >= 29) startForeground(NOTIFICATION, notification.build(), ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        else startForeground(NOTIFICATION, notification.build())
        foreground = true
        // Android 15 requires a foreground app/service before requesting focus.
        if (playing && !hasFocus && !resumeAfterFocus) requestFocus()
        if (!playing && hasFocus && !resumeAfterFocus) abandonFocus()
    }

    private fun updateArtwork(uri: String?) {
        if (artworkUri == uri) return
        artworkUri = uri
        artwork = null
        artworkTask?.cancel(true)
        val generation = ++artworkGeneration
        if (uri == null) return
        artworkTask = artworkExecutor.submit {
            val image = try { loadArtwork(uri) } catch (_: Exception) { null }
            handler.post {
                // A slow image from a retired episode must not replace its successor.
                if (instance === this && generation == artworkGeneration && owner != null) {
                    artwork = image
                    publish()
                }
            }
        }
    }

    private fun loadArtwork(value: String): Bitmap? {
        val uri = Uri.parse(value)
        val connection = if (uri.scheme == "http" || uri.scheme == "https") {
            (URL(value).openConnection() as HttpURLConnection).apply {
                connectTimeout = 5000
                readTimeout = 5000
            }
        } else null
        val bytes = try {
            val input = if (connection != null) connection.inputStream
                else if (uri.scheme == "file" || uri.scheme == "content") contentResolver.openInputStream(uri)
                else null
            input?.use { stream ->
                val result = ByteArrayOutputStream()
                val buffer = ByteArray(8192)
                while (true) {
                    if (Thread.currentThread().isInterrupted) return null
                    val count = stream.read(buffer)
                    if (count < 0) break
                    if (result.size() + count > 8 * 1024 * 1024) return null
                    result.write(buffer, 0, count)
                }
                result.toByteArray()
            } ?: return null
        } finally { connection?.disconnect() }
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        val options = BitmapFactory.Options().apply { inSampleSize = 1 }
        while (maxOf(bounds.outWidth, bounds.outHeight) / options.inSampleSize > 512) {
            options.inSampleSize *= 2
        }
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
    }

    @Suppress("DEPRECATION")
    private fun requestFocus() {
        val granted = if (Build.VERSION.SDK_INT >= 26) {
            val request = focusRequest ?: AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE).build())
                .setOnAudioFocusChangeListener(focusListener, Handler(Looper.getMainLooper()))
                .build().also { focusRequest = it }
            audio.requestAudioFocus(request)
        } else audio.requestAudioFocus(focusListener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN)
        hasFocus = granted == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        if (!hasFocus) owner?.pause()
    }

    @Suppress("DEPRECATION")
    private fun abandonFocus() {
        if (Build.VERSION.SDK_INT >= 26) focusRequest?.let { audio.abandonAudioFocusRequest(it) }
        else audio.abandonAudioFocus(focusListener)
        hasFocus = false
    }

    override fun onDestroy() {
        artworkGeneration++
        artworkTask?.cancel(true)
        artworkExecutor.shutdownNow()
        artwork = null
        if (instance === this) {
            instance = null
            owner?.pause()
            owner = null
        }
        abandonFocus()
        session.isActive = false
        session.release()
        if (foreground) {
            if (Build.VERSION.SDK_INT >= 24) stopForeground(STOP_FOREGROUND_REMOVE)
            else @Suppress("DEPRECATION") stopForeground(true)
        }
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
