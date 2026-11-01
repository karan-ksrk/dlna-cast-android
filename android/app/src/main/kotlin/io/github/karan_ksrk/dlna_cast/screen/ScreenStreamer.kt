package io.github.karan_ksrk.dlna_cast.screen

import android.annotation.SuppressLint
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaRecorder
import android.media.projection.MediaProjection
import android.os.Handler
import android.os.Looper
import android.util.Log
import kotlin.concurrent.thread

private const val TAG = "ScreenStreamer"
private const val SAMPLE_RATE = 48000
private const val CHANNELS = 2
private const val AAC_FRAME_SAMPLES = 1024

enum class AudioSource { DEVICE, MIC, NONE }

data class StreamConfig(
    val width: Int,
    val height: Int,
    val fps: Int,
    val bitrateKbps: Int,
    val audio: AudioSource,
)

/**
 * Encodes a [VideoSource] (the screen, or a still photo) with a hardware H.264 encoder, the phone's sound (or the
 * microphone, or silence) into AAC, and muxes both into MPEG-TS for a [LiveBroadcast]. The encoder runs at a fixed
 * 16:9 size: the system letterboxes a portrait screen into it, so rotating the phone never restarts the stream.
 * [projection] is only needed for screen capture and the phone's sound.
 *
 * [onStopped] is called once if capture ends on its own (the user revoked it, or an encoder failed).
 */
class ScreenStreamer(
    private val source: VideoSource,
    private val projection: MediaProjection?,
    private val config: StreamConfig,
    private val onStatus: (String) -> Unit,
    private val onStopped: (String) -> Unit,
) {
    val broadcast = LiveBroadcast()
    private val muxer = TsMuxer { data, length -> broadcast.push(data, length) }
    private val handler = Handler(Looper.getMainLooper())
    private var video: MediaCodec? = null
    @Volatile private var running = false
    @Volatile private var stopReported = false
    var audioDescription = "none"
        private set
    var encoderName = ""
        private set

    private val projectionCallback = object : MediaProjection.Callback() {
        override fun onStop() = fail("Screen sharing was stopped")
    }

    fun start() {
        running = true
        // Required before createVirtualDisplay on Android 14.
        projection?.registerCallback(projectionCallback, handler)
        startVideo()
        startAudio()
    }

    private fun videoFormat(strict: Boolean) =
        MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, config.width, config.height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, config.bitrateKbps * 1000)
            setInteger(MediaFormat.KEY_FRAME_RATE, config.fps)
            // A keyframe every second, so a renderer that joins mid-stream starts decoding within a second.
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            // The screen only produces frames when it changes; renderers stall without a steady stream.
            setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, 1_000_000L / config.fps)
            setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
            setInteger(MediaFormat.KEY_PRIORITY, 0) // realtime
            if (strict) {
                setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)
                setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.AVCProfileMain)
                setInteger(MediaFormat.KEY_LEVEL, MediaCodecInfo.CodecProfileLevel.AVCLevel41)
            }
        }

    private fun startVideo() {
        val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        encoderName = codec.name
        try {
            codec.configure(videoFormat(strict = true), null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        } catch (error: Exception) {
            // Some encoders reject an explicit profile or CBR; let them pick.
            Log.w(TAG, "Encoder ${codec.name} rejected main profile with CBR: ${error.message}")
            codec.reset()
            codec.configure(videoFormat(strict = false), null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        }
        val surface = codec.createInputSurface()
        codec.start()
        video = codec
        source.attach(surface, config.width, config.height)

        thread(name = "video-drain") {
            val info = MediaCodec.BufferInfo()
            try {
                while (running) {
                    val index = codec.dequeueOutputBuffer(info, 10_000)
                    if (index < 0) continue
                    val buffer = codec.getOutputBuffer(index)!!
                    val bytes = ByteArray(info.size)
                    buffer.position(info.offset)
                    buffer.get(bytes)
                    codec.releaseOutputBuffer(index, false)
                    when {
                        info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0 -> muxer.setCodecConfig(bytes)
                        info.size > 0 -> muxer.writeVideo(
                            bytes, info.presentationTimeUs, info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0,
                        )
                    }
                }
            } catch (error: Exception) {
                if (running) fail("Video encoder stopped: ${error.message}")
            } finally {
                // Released here rather than in stop(), so it can't be torn down mid-dequeue.
                runCatching { codec.stop() }
                codec.release()
            }
        }
    }

    @SuppressLint("MissingPermission") // RECORD_AUDIO is requested before sharing starts; failure falls back to silence.
    private fun openRecorder(): AudioRecord? {
        val format = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(SAMPLE_RATE)
            .setChannelMask(AudioFormat.CHANNEL_IN_STEREO)
            .build()
        val bufferBytes = maxOf(
            AudioRecord.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_IN_STEREO, AudioFormat.ENCODING_PCM_16BIT),
            AAC_FRAME_SAMPLES * CHANNELS * 2 * 8,
        )
        return try {
            val builder = AudioRecord.Builder().setAudioFormat(format).setBufferSizeInBytes(bufferBytes)
            when (config.audio) {
                AudioSource.DEVICE -> builder.setAudioPlaybackCaptureConfig(
                    AudioPlaybackCaptureConfiguration.Builder(projection ?: return null)
                        .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                        .addMatchingUsage(AudioAttributes.USAGE_GAME)
                        .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
                        .build(),
                )
                AudioSource.MIC -> builder.setAudioSource(MediaRecorder.AudioSource.MIC)
                AudioSource.NONE -> return null
            }
            builder.build().takeIf { it.state == AudioRecord.STATE_INITIALIZED }?.also { it.startRecording() }
        } catch (error: Exception) {
            Log.w(TAG, "Audio capture unavailable: ${error.message}")
            null
        }
    }

    /**
     * Many renderers refuse a stream with no audio track, so there is always one. Frames are paced by the clock
     * rather than by the recorder: whatever PCM is ready goes in and silence fills the rest, so the audio never
     * stalls the stream when nothing is playing.
     */
    private fun startAudio() {
        val recorder = openRecorder()
        audioDescription = when {
            recorder == null && config.audio != AudioSource.NONE -> "silence (capture unavailable)"
            recorder == null -> "silence"
            config.audio == AudioSource.DEVICE -> "phone sound"
            else -> "microphone"
        }
        if (recorder == null && config.audio != AudioSource.NONE) {
            onStatus("Phone sound isn't available, so the stream carries silence")
        }

        val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
        codec.configure(
            MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, SAMPLE_RATE, CHANNELS).apply {
                setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                setInteger(MediaFormat.KEY_BIT_RATE, 128_000)
                setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, AAC_FRAME_SAMPLES * CHANNELS * 2)
            },
            null, null, MediaCodec.CONFIGURE_FLAG_ENCODE,
        )
        codec.start()

        thread(name = "audio") {
            val frameBytes = AAC_FRAME_SAMPLES * CHANNELS * 2
            val pcm = ByteArray(frameBytes)
            val info = MediaCodec.BufferInfo()
            val startUs = System.nanoTime() / 1000
            var frames = 0L
            try {
                while (running) {
                    val dueUs = startUs + frames * AAC_FRAME_SAMPLES * 1_000_000L / SAMPLE_RATE
                    val waitMs = (dueUs - System.nanoTime() / 1000) / 1000
                    if (waitMs > 0) Thread.sleep(waitMs)
                    val read = recorder?.read(pcm, 0, frameBytes, AudioRecord.READ_NON_BLOCKING)?.coerceAtLeast(0) ?: 0
                    pcm.fill(0, read, frameBytes)

                    val input = codec.dequeueInputBuffer(10_000)
                    if (input >= 0) {
                        codec.getInputBuffer(input)!!.apply { clear(); put(pcm) }
                        codec.queueInputBuffer(input, 0, frameBytes, dueUs, 0)
                    }
                    frames++

                    while (true) {
                        val index = codec.dequeueOutputBuffer(info, 0)
                        if (index < 0) break
                        if (info.size > 0 && info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                            val buffer = codec.getOutputBuffer(index)!!
                            val bytes = ByteArray(info.size)
                            buffer.position(info.offset)
                            buffer.get(bytes)
                            muxer.writeAudio(bytes, info.presentationTimeUs, SAMPLE_RATE, CHANNELS)
                        }
                        codec.releaseOutputBuffer(index, false)
                    }
                }
            } catch (error: Exception) {
                if (running) fail("Audio encoder stopped: ${error.message}")
            } finally {
                runCatching { recorder?.stop() }
                recorder?.release()
                runCatching { codec.stop() }
                codec.release()
            }
        }
    }

    private fun fail(reason: String) {
        if (!running) return
        Log.w(TAG, reason)
        stop()
        if (!stopReported) {
            stopReported = true
            handler.post { onStopped(reason) }
        }
    }

    fun stop() {
        if (!running) return
        running = false
        source.release()
        video?.let { runCatching { it.signalEndOfInputStream() } }
        video = null
        projection?.unregisterCallback(projectionCallback)
        runCatching { projection?.stop() }
        broadcast.end()
    }
}
