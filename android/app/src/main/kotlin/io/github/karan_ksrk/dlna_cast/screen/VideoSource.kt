package io.github.karan_ksrk.dlna_cast.screen

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.ImageDecoder
import android.graphics.Paint
import android.graphics.RectF
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.projection.MediaProjection
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface
import java.io.File
import kotlin.math.min

/** Draws frames onto the encoder's input surface. */
interface VideoSource {
    fun attach(surface: Surface, width: Int, height: Int)
    fun release()
}

/** The phone screen, mirrored into the encoder through a virtual display. */
class ScreenSource(
    private val projection: MediaProjection,
    private val densityDpi: Int,
    private val handler: Handler,
) : VideoSource {
    private var display: VirtualDisplay? = null

    override fun attach(surface: Surface, width: Int, height: Int) {
        display = projection.createVirtualDisplay(
            "dlna-cast", width, height, densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, surface, null, handler,
        )
    }

    override fun release() {
        display?.release()
        display = null
    }
}

/**
 * A still photo, letterboxed onto black. The goggles have no image support at all (they answer Play on an image
 * item with UPnP 501), so photos go out as a live video stream. [show] swaps the photo without restarting it.
 */
class PhotoSource(photo: Bitmap) : VideoSource {
    companion object {
        /** Decoded no larger than the stream, with EXIF rotation applied. Slow for big photos; call off the main thread. */
        fun decode(file: File, maxWidth: Int, maxHeight: Int): Bitmap =
            ImageDecoder.decodeBitmap(ImageDecoder.createSource(file)) { decoder, info, _ ->
                val (w, h) = info.size.width to info.size.height
                val scale = min(1.0, min(maxWidth.toDouble() / w, maxHeight.toDouble() / h))
                decoder.setTargetSize((w * scale).toInt().coerceAtLeast(1), (h * scale).toInt().coerceAtLeast(1))
            }
    }

    private val paint = Paint(Paint.FILTER_BITMAP_FLAG)
    private val lock = Any()
    private var photo = photo
    private var surface: Surface? = null
    private var thread: HandlerThread? = null
    private var width = 0
    private var height = 0

    override fun attach(surface: Surface, width: Int, height: Int) {
        synchronized(lock) {
            this.surface = surface
            this.width = width
            this.height = height
        }
        val thread = HandlerThread("photo").also { it.start() }
        this.thread = thread
        val handler = Handler(thread.looper)
        // The encoder repeats the last frame on its own; redrawing each second is a backstop for encoders that don't.
        handler.post(object : Runnable {
            override fun run() {
                if (!draw()) return
                handler.postDelayed(this, 1000)
            }
        })
    }

    fun show(next: Bitmap) {
        synchronized(lock) { photo = next }
        draw()
    }

    private fun draw(): Boolean = synchronized(lock) {
        val surface = surface ?: return false
        runCatching {
            // A hardware canvas, since encoder input surfaces don't take software (CPU) locks on every device.
            val canvas = surface.lockHardwareCanvas()
            try {
                canvas.drawColor(Color.BLACK)
                val scale = min(width.toFloat() / photo.width, height.toFloat() / photo.height)
                val (w, h) = photo.width * scale to photo.height * scale
                val target = RectF((width - w) / 2, (height - h) / 2, (width + w) / 2, (height + h) / 2)
                canvas.drawBitmap(photo, null, target, paint)
            } finally {
                surface.unlockCanvasAndPost(canvas)
            }
        }.isSuccess
    }

    override fun release() {
        synchronized(lock) { surface = null }
        thread?.quitSafely()
        thread = null
    }
}
