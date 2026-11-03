package io.github.karan_ksrk.dlna_cast

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.projection.MediaProjectionManager
import android.net.wifi.WifiManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.github.karan_ksrk.dlna_cast.media.VideoConverter
import io.github.karan_ksrk.dlna_cast.media.videoMimeType
import io.github.karan_ksrk.dlna_cast.screen.AudioSource
import io.github.karan_ksrk.dlna_cast.screen.StreamConfig
import java.io.File
import kotlin.concurrent.thread

private const val REQUEST_PERMISSIONS = 1
private const val REQUEST_PROJECTION = 2

/**
 * The bridge Dart talks to over "dlna_cast/native": the multicast lock for discovery, the foreground service for
 * file casts, the screen-share flow (permissions, the system consent dialog, then [CastService]), photo streams,
 * and converting videos the renderer can't decode.
 */
class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null
    private var events: EventChannel.EventSink? = null
    private var screenCall: MethodCall? = null
    private var screenResult: MethodChannel.Result? = null
    private val converter by lazy { VideoConverter(applicationContext) }
    private var launchSound: MediaPlayer? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // The intro's first frame is the splash picture itself, so cut straight to it; the system fade dims the mark.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) splashScreen.setOnExitAnimationListener { it.remove() }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "dlna_cast/native").setMethodCallHandler { call, result ->
            when (call.method) {
                "setMulticastLock" -> {
                    setMulticastLock(call.arguments as Boolean)
                    result.success(null)
                }
                "startMediaService" -> {
                    startForegroundService(
                        Intent(this, CastService::class.java)
                            .setAction(CastService.ACTION_MEDIA)
                            .putExtra(CastService.EXTRA_TITLE, call.argument<String>("title"))
                            .putExtra(CastService.EXTRA_DEVICE, call.argument<String>("device")),
                    )
                    result.success(null)
                }
                "startScreen" -> startScreen(call, result)
                "startPhoto" -> startPhoto(call, result)
                "showPhoto" -> {
                    val service = CastService.instance ?: return@setMethodCallHandler result.success(false)
                    service.showPhoto(call.argument<String>("path")!!) { outcome ->
                        outcome.fold(
                            onSuccess = { result.success(it) },
                            onFailure = { result.error("failed", it.message ?: it.toString(), null) },
                        )
                    }
                }
                "videoMimeType" -> {
                    val path = call.arguments as String
                    thread(name = "probe") { videoMimeType(path).let { runOnUiThread { result.success(it) } } }
                }
                "convertVideo" -> converter.convert(
                    File(call.arguments as String),
                    onProgress = { percent -> events?.success(mapOf("event" to "convertProgress", "percent" to percent)) },
                    onDone = { outcome ->
                        outcome.fold(
                            onSuccess = { result.success(it.absolutePath) },
                            onFailure = { result.error("failed", it.message ?: it.toString(), null) },
                        )
                    },
                )
                "openUrl" -> {
                    val opened = runCatching {
                        startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(call.arguments as String)))
                    }.isSuccess
                    result.success(opened)
                }
                "playLaunchSound" -> result.success(playLaunchSound())
                "stopLaunchSound" -> {
                    launchSound?.release()
                    launchSound = null
                    result.success(null)
                }
                "cancelConvert" -> {
                    converter.cancel()
                    result.success(null)
                }
                "stopCast" -> {
                    CastService.instance?.stopEverything()
                    result.success(null)
                }
                "screenStats" -> result.success(CastService.instance?.stats())
                else -> result.notImplemented()
            }
        }
        EventChannel(messenger, "dlna_cast/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                events = sink
            }

            override fun onCancel(arguments: Any?) {
                events = null
            }
        })
        CastService.events = { event -> runOnUiThread { events?.success(event) } }
    }

    // Android drops multicast packets addressed to other hosts unless an app holds this, and SSDP NOTIFYs are exactly that.
    private fun setMulticastLock(held: Boolean) {
        if (held) {
            if (multicastLock?.isHeld == true) return
            multicastLock = (applicationContext.getSystemService(WIFI_SERVICE) as WifiManager)
                .createMulticastLock("dlna-cast:ssdp")
                .apply { setReferenceCounted(false); acquire() }
        } else {
            multicastLock?.takeIf { it.isHeld }?.release()
        }
    }

    /**
     * The intro's sound. Silent and vibrate mode keep it silent, like any other UI sound, and so does music already
     * playing, so the intro never talks over it.
     */
    private fun playLaunchSound(): Boolean {
        val audio = getSystemService(AudioManager::class.java)
        if (audio.ringerMode != AudioManager.RINGER_MODE_NORMAL || audio.isMusicActive) return false
        val attributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
        val player = MediaPlayer.create(this, R.raw.launch_sound, attributes, audio.generateAudioSessionId())
            ?: return false
        player.setOnCompletionListener {
            it.release()
            if (launchSound === it) launchSound = null
        }
        launchSound = player
        player.start()
        return true
    }

    private fun startScreen(call: MethodCall, result: MethodChannel.Result) {
        if (screenResult != null) return result.error("busy", "A screen share is already starting", null)
        screenCall = call
        screenResult = result
        val needed = buildList {
            if (call.argument<String>("audio") != "none") add(Manifest.permission.RECORD_AUDIO)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) add(Manifest.permission.POST_NOTIFICATIONS)
        }.filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        // Denied permissions aren't fatal: no RECORD_AUDIO means a silent track, no notifications means no Stop button.
        if (needed.isEmpty()) requestProjection() else requestPermissions(needed.toTypedArray(), REQUEST_PERMISSIONS)
    }

    @Deprecated("FlutterActivity is not a ComponentActivity, so the Activity Result API isn't available")
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_PERMISSIONS) requestProjection()
    }

    private fun requestProjection() {
        val manager = getSystemService(MediaProjectionManager::class.java)
        @Suppress("DEPRECATION")
        startActivityForResult(manager.createScreenCaptureIntent(), REQUEST_PROJECTION)
    }

    @Deprecated("FlutterActivity is not a ComponentActivity, so the Activity Result API isn't available")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_PROJECTION) return
        val call = screenCall
        val result = screenResult ?: return
        screenCall = null
        screenResult = null
        if (resultCode != RESULT_OK || data == null || call == null) {
            return result.error("cancelled", "Screen sharing wasn't allowed", null)
        }

        CastService.pendingScreen = CastService.ScreenRequest(
            resultCode = resultCode,
            data = data,
            config = streamConfig(call),
            host = call.argument<String>("host")!!,
            allow = call.argument<List<String>>("allow") ?: emptyList(),
            deviceName = call.argument<String>("device") ?: "renderer",
            callback = replyOnUiThread(result),
        )
        startForegroundService(Intent(this, CastService::class.java).setAction(CastService.ACTION_SCREEN))
    }

    private fun startPhoto(call: MethodCall, result: MethodChannel.Result) {
        CastService.pendingPhoto = CastService.PhotoRequest(
            path = call.argument<String>("path")!!,
            config = streamConfig(call),
            host = call.argument<String>("host")!!,
            allow = call.argument<List<String>>("allow") ?: emptyList(),
            deviceName = call.argument<String>("device") ?: "renderer",
            callback = replyOnUiThread(result),
        )
        startForegroundService(Intent(this, CastService::class.java).setAction(CastService.ACTION_PHOTO))
    }

    private fun streamConfig(call: MethodCall) = StreamConfig(
        width = call.argument<Int>("width") ?: 1280,
        height = call.argument<Int>("height") ?: 720,
        fps = call.argument<Int>("fps") ?: 30,
        bitrateKbps = call.argument<Int>("bitrateKbps") ?: 4000,
        audio = when (call.argument<String>("audio")) {
            "mic" -> AudioSource.MIC
            "none" -> AudioSource.NONE
            else -> AudioSource.DEVICE
        },
    )

    private fun replyOnUiThread(result: MethodChannel.Result): (Result<Map<String, Any?>>) -> Unit = { outcome ->
        runOnUiThread {
            outcome.fold(
                onSuccess = { result.success(it) },
                onFailure = { result.error("failed", it.message ?: it.toString(), null) },
            )
        }
    }

    override fun onDestroy() {
        setMulticastLock(false)
        converter.cancel()
        launchSound?.release()
        launchSound = null
        super.onDestroy()
    }
}
