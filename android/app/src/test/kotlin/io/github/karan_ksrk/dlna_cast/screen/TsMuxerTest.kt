package io.github.karan_ksrk.dlna_cast.screen

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.file.Files
import java.util.concurrent.TimeUnit

class TsMuxerTest {
    private class Packet(val bytes: ByteArray) {
        val pid get() = ((bytes[1].toInt() and 0x1F) shl 8) or (bytes[2].toInt() and 0xFF)
        val unitStart get() = bytes[1].toInt() and 0x40 != 0
        val adaptationControl get() = (bytes[3].toInt() shr 4) and 3
        val continuity get() = bytes[3].toInt() and 0x0F
        val hasPayload get() = adaptationControl and 1 != 0
        val adaptationFlags get() = if (adaptationControl and 2 != 0 && bytes[4].toInt() != 0) bytes[5].toInt() and 0xFF else 0
        val pcr: Long?
            get() {
                if (adaptationFlags and 0x10 == 0) return null
                val b = (6..10).map { bytes[it].toLong() and 0xFF }
                return (b[0] shl 25) or (b[1] shl 17) or (b[2] shl 9) or (b[3] shl 1) or (b[4] shr 7)
            }
    }

    private fun mux(block: (TsMuxer) -> Unit): List<Packet> {
        val out = ByteArrayOutputStream()
        val muxer = TsMuxer { data, length ->
            assertEquals("the sink gets whole packets", 0, length % TsMuxer.PACKET_BYTES)
            out.write(data, 0, length)
        }
        block(muxer)
        return out.toByteArray().toList().chunked(TsMuxer.PACKET_BYTES).map { Packet(it.toByteArray()) }
    }

    private fun crc32Mpeg2(data: ByteArray, length: Int): Int {
        var crc = -1
        for (i in 0 until length) {
            crc = crc xor ((data[i].toInt() and 0xFF) shl 24)
            repeat(8) { crc = if (crc < 0) (crc shl 1) xor 0x04C11DB7 else crc shl 1 }
        }
        return crc
    }

    private val sps = byteArrayOf(0, 0, 0, 1, 0x67, 0x4D, 0x40, 0x1F, 0x11, 0x22)
    private val idr = byteArrayOf(0, 0, 0, 1, 0x65) + ByteArray(5000) { (it % 251).toByte() }
    private val slice = byteArrayOf(0, 0, 0, 1, 0x41) + ByteArray(700) { (it % 13).toByte() }

    @Test
    fun `packets are well formed and continuity counters advance per PID`() {
        val packets = mux { muxer ->
            muxer.setCodecConfig(sps)
            for (frame in 0 until 30) {
                muxer.writeVideo(if (frame % 10 == 0) idr else slice, 1_000_000L + frame * 33_333L, frame % 10 == 0)
                muxer.writeAudio(ByteArray(300) { 7 }, 1_000_000L + frame * 21_333L, 48000, 2)
            }
        }
        assertTrue(packets.all { it.bytes.size == 188 && it.bytes[0] == 0x47.toByte() })
        assertEquals(setOf(0, 0x1000, 0x100, 0x101), packets.map { it.pid }.toSet())

        val last = HashMap<Int, Int>()
        for (packet in packets.filter { it.hasPayload }) {
            last[packet.pid]?.let { assertEquals("continuity on PID ${packet.pid}", (it + 1) and 0x0F, packet.continuity) }
            last[packet.pid] = packet.continuity
        }
    }

    @Test
    fun `PAT and PMT carry valid CRCs and come before every video frame`() {
        val packets = mux { muxer ->
            for (frame in 0 until 5) muxer.writeVideo(slice, frame * 33_333L, false)
        }
        for (pid in listOf(0, 0x1000)) {
            val table = packets.first { it.pid == pid }.bytes
            val sectionLength = ((table[6].toInt() and 0x0F) shl 8) or (table[7].toInt() and 0xFF)
            val end = 5 + 3 + sectionLength
            val crc = crc32Mpeg2(table.copyOfRange(5, end - 4), sectionLength - 1)
            val stored = table.copyOfRange(end - 4, end).fold(0) { acc, b -> (acc shl 8) or (b.toInt() and 0xFF) }
            assertEquals("CRC of table on PID $pid", crc, stored)
        }
        val starts = packets.filter { it.unitStart }.map { it.pid }
        assertEquals(List(5) { listOf(0, 0x1000, 0x100) }.flatten(), starts)
    }

    @Test
    fun `keyframes are random access points with SPS and the first packet of each stream is flagged discontinuous`() {
        val packets = mux { muxer ->
            muxer.setCodecConfig(sps)
            muxer.writeVideo(idr, 0, true)
            muxer.writeVideo(slice, 33_333, false)
        }
        val videoStarts = packets.filter { it.pid == 0x100 && it.unitStart }
        assertEquals(0x80 or 0x40 or 0x10, videoStarts[0].adaptationFlags)
        assertEquals(0x10, videoStarts[1].adaptationFlags)
        val firstPayload = videoStarts[0].bytes.let { it.copyOfRange(5 + (it[4].toInt() and 0xFF), 188) }
        val es = firstPayload.copyOfRange(14, 14 + 6 + sps.size)
        assertTrue("AUD, then SPS", es.contentEquals(byteArrayOf(0, 0, 0, 1, 9, 0xF0.toByte()) + sps))
    }

    @Test
    fun `PCR is monotonic and arrives at least every 20 ms while only audio flows`() {
        val packets = mux { muxer ->
            muxer.writeVideo(slice, 0, false)
            for (frame in 0 until 50) muxer.writeAudio(ByteArray(200), frame * 21_333L, 48000, 2)
        }
        val pcrs = packets.mapNotNull { it.pcr }
        assertTrue(pcrs.zipWithNext().all { (a, b) -> b >= a })
        assertTrue("one PCR per audio frame at this spacing", pcrs.size >= 50)
    }

    // The same check as the desktop project's screen test: the real decoder must accept the stream.
    @Test
    fun `ffmpeg decodes muxed H264 and AAC without errors`() {
        val ffmpeg = findOnPath("ffmpeg")
        assumeTrue("ffmpeg not found", ffmpeg != null)
        val dir = Files.createTempDirectory("tsmuxer").toFile()
        try {
            val h264 = File(dir, "in.h264")
            val adts = File(dir, "in.aac")
            run(ffmpeg!!, "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30", "-t", "3", "-c:v", "libx264",
                "-profile:v", "main", "-bf", "0", "-g", "30", "-x264-params", "aud=1", "-f", "h264", h264.path)
            run(ffmpeg, "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-ac", "2", "-t", "3",
                "-c:a", "aac", "-b:a", "128k", "-f", "adts", adts.path)

            val video = splitAccessUnits(h264.readBytes()).mapIndexed { i, au -> Triple(i * 33_333L, true, au) }
            val audio = splitAdts(adts.readBytes()).mapIndexed { i, frame -> Triple(i * 21_333L, false, frame) }
            val out = File(dir, "out.ts")
            out.outputStream().use { stream ->
                val muxer = TsMuxer { data, length -> stream.write(data, 0, length) }
                for ((pts, isVideo, data) in (video + audio).sortedBy { it.first }) {
                    if (isVideo) muxer.writeVideo(data, pts, containsIdr(data)) else muxer.writeAudio(data, pts, 48000, 2)
                }
            }

            val decode = ProcessBuilder(ffmpeg, "-v", "error", "-i", out.path, "-f", "null", "-").redirectErrorStream(true).start()
            val errors = decode.inputStream.bufferedReader().readText()
            assertTrue(decode.waitFor(60, TimeUnit.SECONDS))
            assertEquals("ffmpeg errors: $errors", 0, decode.exitValue())
            assertEquals("ffmpeg errors: $errors", "", errors.trim())

            val probe = ProcessBuilder(ffmpeg, "-hide_banner", "-i", out.path).redirectErrorStream(true).start()
            val info = probe.inputStream.bufferedReader().readText()
            probe.waitFor(30, TimeUnit.SECONDS)
            assertTrue(info, Regex("Video: h264 \\(Main\\).*640x360").containsMatchIn(info))
            assertTrue(info, Regex("Audio: aac \\(LC\\).*48000 Hz, stereo").containsMatchIn(info))
        } finally {
            dir.deleteRecursively()
        }
    }

    private fun findOnPath(name: String): String? =
        System.getenv("PATH").orEmpty().split(File.pathSeparator).flatMap { listOf(File(it, name), File(it, "$name.exe")) }
            .firstOrNull { it.canExecute() }?.path

    private fun run(vararg command: String) {
        val process = ProcessBuilder(*command).redirectErrorStream(true).start()
        val output = process.inputStream.bufferedReader().readText()
        assertTrue(process.waitFor(60, TimeUnit.SECONDS))
        assertEquals(output, 0, process.exitValue())
    }

    private fun nalStarts(data: ByteArray): List<Int> = (0 until data.size - 3).filter {
        data[it].toInt() == 0 && data[it + 1].toInt() == 0 && data[it + 2].toInt() == 1
    }.map { if (it > 0 && data[it - 1].toInt() == 0) it - 1 else it }

    private fun nalTypeAt(data: ByteArray, start: Int) = data[start + if (data[start + 2].toInt() == 1) 3 else 4].toInt() and 0x1F

    // x264 was asked for AUDs, so each access unit starts at one.
    private fun splitAccessUnits(data: ByteArray): List<ByteArray> {
        val auds = nalStarts(data).filter { nalTypeAt(data, it) == 9 }
        return auds.mapIndexed { i, start -> data.copyOfRange(start, auds.getOrElse(i + 1) { data.size }) }
    }

    private fun containsIdr(au: ByteArray) = nalStarts(au).any { nalTypeAt(au, it) == 5 }

    // MediaCodec hands out raw AAC frames, so the ADTS headers ffmpeg wrote are stripped.
    private fun splitAdts(data: ByteArray): List<ByteArray> {
        val frames = mutableListOf<ByteArray>()
        var at = 0
        while (at + 7 <= data.size) {
            val length = ((data[at + 3].toInt() and 3) shl 11) or ((data[at + 4].toInt() and 0xFF) shl 3) or
                ((data[at + 5].toInt() and 0xFF) shr 5)
            val header = if (data[at + 1].toInt() and 1 == 1) 7 else 9
            frames += data.copyOfRange(at + header, at + length)
            at += length
        }
        return frames
    }
}
