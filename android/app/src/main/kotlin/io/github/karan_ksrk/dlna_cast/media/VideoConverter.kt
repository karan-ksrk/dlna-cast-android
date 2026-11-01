package io.github.karan_ksrk.dlna_cast.media

import android.content.Context
import android.media.MediaCodecInfo.CodecProfileLevel
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.effect.Presentation
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import java.io.File
import java.security.MessageDigest

private const val TAG = "VideoConverter"
private const val KEEP_CONVERTED = 3

/** The first video track's MIME type (e.g. "video/hevc"), or null if the file has none or can't be read. */
fun videoMimeType(path: String): String? {
    val extractor = MediaExtractor()
    return try {
        extractor.setDataSource(path)
        (0 until extractor.trackCount)
            .map { extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME) }
            .firstOrNull { it?.startsWith("video/") == true }
    } catch (error: Exception) {
        Log.w(TAG, "Can't read $path: ${error.message}")
        null
    } finally {
        extractor.release()
    }
}

/**
 * Re-encodes a video the renderer can't decode (the goggles have no HEVC decoder, and phone cameras record HEVC)
 * into what the desktop app sends them: H.264 main profile in a 1920x1080 frame, AAC sound. Portrait video is
 * pillarboxed rather than tagged with a rotation, and a silent track is added when there is no sound, since some
 * renderers refuse video without one. Results are cached by source path, size and date, so a replay is instant.
 */
class VideoConverter(private val context: Context) {
    private val handler = Handler(Looper.getMainLooper())
    private val directory = File(context.cacheDir, "converted").apply { mkdirs() }
    private var transformer: Transformer? = null
    private var cancelled: (() -> Unit)? = null

    fun cachedOutput(source: File): File {
        val key = "${source.absolutePath}|${source.length()}|${source.lastModified()}"
        val hash = MessageDigest.getInstance("SHA-256").digest(key.toByteArray())
            .take(12).joinToString("") { "%02x".format(it) }
        return File(directory, "$hash.mp4")
    }

    /** Main thread only. [onProgress] gets 0-100; [onDone] gets the converted file or the failure, once. */
    fun convert(source: File, onProgress: (Int) -> Unit, onDone: (Result<File>) -> Unit) {
        cancel()
        val output = cachedOutput(source)
        if (output.exists()) return onDone(Result.success(output.also { it.setLastModified(System.currentTimeMillis()) }))
        val partial = File(directory, "${output.name}.part").apply { delete() }

        val progress = ProgressHolder()
        val poll = object : Runnable {
            override fun run() {
                val current = transformer ?: return
                if (current.getProgress(progress) == Transformer.PROGRESS_STATE_AVAILABLE) onProgress(progress.progress)
                handler.postDelayed(this, 500)
            }
        }
        fun finish(result: Result<File>) {
            handler.removeCallbacks(poll)
            transformer = null
            cancelled = null
            if (result.isFailure) partial.delete()
            onDone(result)
        }

        val encoders = DefaultEncoderFactory.Builder(context)
            .setRequestedVideoEncoderSettings(
                VideoEncoderSettings.Builder()
                    .setBitrate(8_000_000)
                    // Level 4.2 covers 1080p60, which the goggles play.
                    .setEncodingProfileLevel(CodecProfileLevel.AVCProfileMain, CodecProfileLevel.AVCLevel42)
                    .build(),
            )
            .build()
        val transformer = Transformer.Builder(context)
            .setVideoMimeType(MimeTypes.VIDEO_H264)
            .setAudioMimeType(MimeTypes.AUDIO_AAC)
            .setEncoderFactory(encoders)
            .addListener(object : Transformer.Listener {
                override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                    if (partial.renameTo(output)) {
                        prune()
                        finish(Result.success(output))
                    } else {
                        finish(Result.failure(IllegalStateException("Couldn't save the converted video")))
                    }
                }

                override fun onError(composition: Composition, exportResult: ExportResult, exception: ExportException) {
                    Log.w(TAG, "Conversion failed", exception)
                    finish(Result.failure(IllegalStateException("Conversion failed: ${exception.errorCodeName}")))
                }
            })
            .build()

        val item = EditedMediaItem.Builder(MediaItem.fromUri(Uri.fromFile(source)))
            .setEffects(
                Effects(
                    emptyList(),
                    listOf(Presentation.createForWidthAndHeight(1920, 1080, Presentation.LAYOUT_SCALE_TO_FIT)),
                ),
            )
            .build()
        // Declaring both track types makes the output carry audio, silence when the source has none. (The older
        // force-audio flags are deprecated in Media3 1.10, and Composition's version throws.)
        val sequence = EditedMediaItemSequence.withAudioAndVideoFrom(listOf(item))

        this.transformer = transformer
        cancelled = { finish(Result.failure(InterruptedException("Conversion cancelled"))) }
        try {
            transformer.start(Composition.Builder(sequence).build(), partial.absolutePath)
        } catch (error: Exception) {
            Log.w(TAG, "Conversion didn't start", error)
            return finish(Result.failure(IllegalStateException("Conversion didn't start: ${error.message}")))
        }
        handler.post(poll)
    }

    fun cancel() {
        val current = transformer ?: return
        current.cancel()
        cancelled?.invoke()
    }

    // Converted videos are big; keep the few most recently used.
    private fun prune() {
        directory.listFiles { file -> file.extension == "mp4" }
            ?.sortedByDescending { it.lastModified() }
            ?.drop(KEEP_CONVERTED)
            ?.forEach { it.delete() }
    }
}
