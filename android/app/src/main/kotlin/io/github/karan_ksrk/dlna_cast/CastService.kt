package io.github.karan_ksrk.dlna_cast

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import io.github.karan_ksrk.dlna_cast.screen.LiveServer
import io.github.karan_ksrk.dlna_cast.screen.PhotoSource
import io.github.karan_ksrk.dlna_cast.screen.ScreenSource
import io.github.karan_ksrk.dlna_cast.screen.ScreenStreamer
import io.github.karan_ksrk.dlna_cast.screen.StreamConfig
import io.github.karan_ksrk.dlna_cast.screen.VideoSource
import java.io.File
import kotlin.concurrent.thread

private const val TAG = "CastService"
private const val CHANNEL_ID = "casting"
private const val NOTIFICATION_ID = 1

/**
 * Keeps a cast alive while the app is in the background or the screen is off: a foreground service with Wi-Fi and
 * wake locks. File casts are served from Dart and only need the service to stay alive; screen shares and photos
 * run their whole capture (or draw), encode and serve pipeline here, so the stream doesn't depend on the Flutter UI.
 */
class CastService : Service() {
    class ScreenRequest(
        val resultCode: Int,
        val data: Intent,
        val config: StreamConfig,
        val host: String,
        val allow: List<String>,
        val deviceName: String,
        val callback: (Result<Map<String, Any?>>) -> Unit,
    )

    class PhotoRequest(
        val path: String,
        val config: StreamConfig,
        val host: String,
        val allow: List<String>,
        val deviceName: String,
        val callback: (Result<Map<String, Any?>>) -> Unit,
    )

    companion object {
        const val ACTION_SCREEN = "io.github.karan_ksrk.dlna_cast.SCREEN"
        const val ACTION_PHOTO = "io.github.karan_ksrk.dlna_cast.PHOTO"
        const val ACTION_MEDIA = "io.github.karan_ksrk.dlna_cast.MEDIA"
        const val ACTION_STOP = "io.github.karan_ksrk.dlna_cast.STOP"
        const val EXTRA_TITLE = "title"
        const val EXTRA_DEVICE = "device"

        /** Handed over by MainActivity just before it starts the service, since an Intent can't carry a callback. */
        @Volatile var pendingScreen: ScreenRequest? = null
        @Volatile var pendingPhoto: PhotoRequest? = null

        /** Events for Dart: {"event": "screenStopped" | "stopRequested" | "status", ...}. */
        var events: ((Map<String, Any?>) -> Unit)? = null

        @Volatile var instance: CastService? = null
            private set
    }

    private var streamer: ScreenStreamer? = null
    private var server: LiveServer? = null
    private var photo: PhotoSource? = null
    private var liveConfig: StreamConfig? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    // Bumped on every stop, so a photo still decoding when the cast stops doesn't start a stream afterwards.
    private var generation = 0
    private var wifiLock: WifiManager.WifiLock? = null
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Casting", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Shown while dlna-cast is casting to a renderer"
            },
        )
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_SCREEN -> startScreen()
            ACTION_PHOTO -> startPhoto()
            ACTION_MEDIA -> {
                val title = intent.getStringExtra(EXTRA_TITLE) ?: "Media"
                val device = intent.getStringExtra(EXTRA_DEVICE) ?: "renderer"
                stopScreen()
                startForeground(
                    NOTIFICATION_ID, notification("Casting to $device", title),
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK,
                )
                acquireLocks()
            }
            ACTION_STOP -> {
                events?.invoke(mapOf("event" to "stopRequested"))
                stopEverything()
            }
            else -> stopEverything()
        }
        return START_NOT_STICKY
    }

    private fun startScreen() {
        val request = pendingScreen ?: return stopEverything()
        pendingScreen = null
        stopScreen()
        // On Android 14 the mediaProjection service must be in the foreground before getMediaProjection.
        startForeground(
            NOTIFICATION_ID, notification("Sharing your screen", "to ${request.deviceName}"),
            ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
        )
        acquireLocks()
        try {
            val projection = getSystemService(MediaProjectionManager::class.java)
                .getMediaProjection(request.resultCode, request.data)
                ?: throw IllegalStateException("Screen capture permission was not granted")
            val source = ScreenSource(projection, resources.displayMetrics.densityDpi, mainHandler)
            startLive(source, projection, request.config, request.host, request.allow, request.callback)
        } catch (error: Exception) {
            Log.e(TAG, "Screen share failed to start", error)
            stopEverything()
            request.callback(Result.failure(error))
        }
    }

    private fun startPhoto() {
        val request = pendingPhoto ?: return stopEverything()
        pendingPhoto = null
        stopScreen()
        startForeground(
            NOTIFICATION_ID, notification("Showing a photo", "on ${request.deviceName}"),
            ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK,
        )
        acquireLocks()
        val started = generation
        val (width, height) = request.config.width to request.config.height
        thread(name = "photo-decode") {
            val decoded = runCatching { PhotoSource.decode(File(request.path), width, height) }
            mainHandler.post {
                try {
                    if (generation != started) throw IllegalStateException("The cast was stopped")
                    val source = PhotoSource(decoded.getOrThrow())
                    startLive(source, null, request.config, request.host, request.allow, request.callback)
                    photo = source
                } catch (error: Exception) {
                    Log.e(TAG, "Photo stream failed to start", error)
                    if (generation == started) stopEverything()
                    request.callback(Result.failure(error))
                }
            }
        }
    }

    /** Swaps the photo in a running photo stream; false if there is none, so Dart starts a new cast instead. */
    fun showPhoto(path: String, callback: (Result<Boolean>) -> Unit) {
        val source = photo
        val config = liveConfig
        if (source == null || config == null) return callback(Result.success(false))
        thread(name = "photo-decode") {
            val outcome = runCatching { PhotoSource.decode(File(path), config.width, config.height) }
            mainHandler.post {
                callback(outcome.map { bitmap -> (photo === source).also { if (it) source.show(bitmap) } })
            }
        }
    }

    private fun startLive(
        source: VideoSource,
        projection: MediaProjection?,
        config: StreamConfig,
        host: String,
        allow: List<String>,
        callback: (Result<Map<String, Any?>>) -> Unit,
    ) {
        val streamer = ScreenStreamer(
            source,
            projection,
            config,
            onStatus = { message -> events?.invoke(mapOf("event" to "status", "message" to message)) },
            onStopped = { reason ->
                events?.invoke(mapOf("event" to "screenStopped", "error" to reason))
                stopEverything()
            },
        )
        this.streamer = streamer
        liveConfig = config
        streamer.start()
        val server = LiveServer(host, streamer.broadcast, allow)
        this.server = server
        callback(
            Result.success(
                mapOf("url" to server.url, "encoder" to streamer.encoderName, "audio" to streamer.audioDescription),
            ),
        )
    }

    fun stats(): Map<String, Any?> {
        val broadcast = streamer?.broadcast
        return mapOf(
            "bytesSent" to (broadcast?.bytesSent?.get() ?: 0L),
            "skippedBytes" to (broadcast?.skippedBytes?.get() ?: 0L),
            "clients" to (broadcast?.clientCount ?: 0),
        )
    }

    private fun stopScreen() {
        generation++
        streamer?.stop()
        streamer = null
        photo = null
        liveConfig = null
        server?.close()
        server = null
    }

    fun stopEverything() {
        stopScreen()
        wifiLock?.takeIf { it.isHeld }?.release()
        wakeLock?.takeIf { it.isHeld }?.release()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        stopScreen()
        wifiLock?.takeIf { it.isHeld }?.release()
        wakeLock?.takeIf { it.isHeld }?.release()
        instance = null
        super.onDestroy()
    }

    private fun acquireLocks() {
        if (wifiLock?.isHeld != true) {
            wifiLock = getSystemService(WifiManager::class.java)
                .createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "dlna-cast:stream")
                .apply { setReferenceCounted(false); acquire() }
        }
        if (wakeLock?.isHeld != true) {
            wakeLock = getSystemService(PowerManager::class.java)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "dlna-cast:stream")
                .apply { setReferenceCounted(false); acquire() }
        }
    }

    private fun notification(title: String, text: String): Notification {
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE,
        )
        val stop = PendingIntent.getService(
            this, 1, Intent(this, CastService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_IMMUTABLE,
        )
        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_cast)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
            .addAction(Notification.Action.Builder(null, "Stop", stop).build())
            .build()
    }
}
