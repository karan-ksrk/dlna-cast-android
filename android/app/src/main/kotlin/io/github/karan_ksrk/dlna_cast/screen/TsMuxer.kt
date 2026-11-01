package io.github.karan_ksrk.dlna_cast.screen

import java.io.ByteArrayOutputStream

/**
 * A minimal MPEG-TS muxer for one H.264 and one AAC stream. Its output mirrors the ffmpeg settings the desktop app
 * uses, which the goggles are known to accept: PAT/PMT before every video frame, a PCR at least every 20 ms, the
 * discontinuity flag on each stream's first packet, and SPS/PPS repeated before every keyframe so a renderer that
 * joins mid-stream can start decoding at the next one.
 *
 * [sink] receives whole 188-byte packets, a PES at a time. Video and audio are written from different threads.
 */
class TsMuxer(private val sink: (ByteArray, Int) -> Unit) {
    companion object {
        const val PACKET_BYTES = 188
        private const val PMT_PID = 0x1000
        private const val VIDEO_PID = 0x100
        private const val AUDIO_PID = 0x101
        private const val PCR_PERIOD = 1800L // 20 ms at 90 kHz
        // Timestamps lead the PCR by 100 ms so a frame that took a little longer to encode still isn't late.
        private const val PTS_LEAD = 9000L
        private val AUD = byteArrayOf(0, 0, 0, 1, 9, 0xF0.toByte())

        private val PAT = psiSection(
            0x00, 0x00, 0x01, 0xC1, 0x00, 0x00,
            0x00, 0x01, 0xE0 or (PMT_PID shr 8), PMT_PID and 0xFF,
        )
        private val PMT = psiSection(
            0x02, 0x00, 0x01, 0xC1, 0x00, 0x00,
            0xE0 or (VIDEO_PID shr 8), VIDEO_PID and 0xFF, 0xF0, 0x00,
            0x1B, 0xE0 or (VIDEO_PID shr 8), VIDEO_PID and 0xFF, 0xF0, 0x00, // H.264
            0x0F, 0xE0 or (AUDIO_PID shr 8), AUDIO_PID and 0xFF, 0xF0, 0x00, // AAC in ADTS
        )

        /** table_id, then the section body after section_length; section_length and the CRC are filled in. */
        private fun psiSection(tableId: Int, vararg body: Int): ByteArray {
            val length = body.size + 4
            val section = byteArrayOf(tableId.toByte(), (0xB0 or (length shr 8)).toByte(), length.toByte()) +
                ByteArray(body.size) { body[it].toByte() }
            val crc = crc32Mpeg2(section)
            return section + byteArrayOf((crc ushr 24).toByte(), (crc ushr 16).toByte(), (crc ushr 8).toByte(), crc.toByte())
        }

        private fun crc32Mpeg2(data: ByteArray): Int {
            var crc = -1
            for (byte in data) {
                crc = crc xor ((byte.toInt() and 0xFF) shl 24)
                repeat(8) { crc = if (crc < 0) (crc shl 1) xor 0x04C11DB7 else crc shl 1 }
            }
            return crc
        }

        private val ADTS_RATES = intArrayOf(96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000)
    }

    private val continuity = HashMap<Int, Int>()
    private val started = HashSet<Int>()
    private val out = ByteArrayOutputStream(64 * 1024)
    private val packet = ByteArray(PACKET_BYTES)
    private var baseUs = Long.MIN_VALUE
    private var lastPcr = -1L
    private var codecConfig: ByteArray? = null

    /** The SPS and PPS from the encoder's codec-config buffer. */
    @Synchronized
    fun setCodecConfig(config: ByteArray) {
        codecConfig = config
    }

    @Synchronized
    fun writeVideo(frame: ByteArray, ptsUs: Long, keyframe: Boolean) {
        val ticks = ticks(ptsUs) ?: return
        writePsi(0, PAT)
        writePsi(PMT_PID, PMT)
        val es = ByteArrayOutputStream(frame.size + 64)
        if (nalType(frame) != 9) es.write(AUD)
        if (keyframe) codecConfig?.let { es.write(it) }
        es.write(frame)
        val pcr = maxOf(lastPcr, ticks).also { lastPcr = it }
        // PES_packet_length 0 (unbounded) is allowed for video in a transport stream.
        writePes(VIDEO_PID, pesHeader(0xE0, ticks + PTS_LEAD, 0) + es.toByteArray(), pcr, keyframe)
        flush()
    }

    /** One raw AAC-LC frame as MediaCodec produces it; an ADTS header is added. */
    @Synchronized
    fun writeAudio(aac: ByteArray, ptsUs: Long, sampleRate: Int, channels: Int) {
        val ticks = ticks(ptsUs) ?: return
        if (lastPcr < 0 || ticks - lastPcr >= PCR_PERIOD) writePcrOnly(maxOf(lastPcr, ticks).also { lastPcr = it })
        val es = adtsHeader(aac.size, sampleRate, channels) + aac
        writePes(AUDIO_PID, pesHeader(0xC0, ticks + PTS_LEAD, 8 + es.size) + es, null, false)
        flush()
    }

    // Both streams share the System.nanoTime clock; the first timestamp seen becomes zero.
    private fun ticks(ptsUs: Long): Long? {
        if (baseUs == Long.MIN_VALUE) baseUs = ptsUs
        val ticks = (ptsUs - baseUs) * 9 / 100
        return if (ticks < 0) null else ticks and 0x1FFFFFFFFL
    }

    private fun nalType(frame: ByteArray): Int {
        val start = when {
            frame.size > 4 && frame[0].toInt() == 0 && frame[1].toInt() == 0 && frame[2].toInt() == 0 && frame[3].toInt() == 1 -> 4
            frame.size > 3 && frame[0].toInt() == 0 && frame[1].toInt() == 0 && frame[2].toInt() == 1 -> 3
            else -> return -1
        }
        return frame[start].toInt() and 0x1F
    }

    private fun pesHeader(streamId: Int, pts: Long, packetLength: Int): ByteArray {
        val length = if (packetLength > 0xFFFF) 0 else packetLength
        val p = pts and 0x1FFFFFFFFL
        return byteArrayOf(
            0, 0, 1, streamId.toByte(), (length shr 8).toByte(), length.toByte(),
            0x80.toByte(), 0x80.toByte(), 5, // marker bits, PTS only, 5 header bytes
            (0x21 or ((p shr 29) and 0x0E).toInt()).toByte(),
            (p shr 22).toByte(),
            (((p shr 14) and 0xFE) or 1).toByte(),
            (p shr 7).toByte(),
            (((p shl 1) and 0xFE) or 1).toByte(),
        )
    }

    private fun adtsHeader(aacLength: Int, sampleRate: Int, channels: Int): ByteArray {
        val frameLength = aacLength + 7
        val rateIndex = ADTS_RATES.indexOf(sampleRate).takeIf { it >= 0 } ?: 3
        val profile = 1 // AAC LC
        return byteArrayOf(
            0xFF.toByte(), 0xF1.toByte(),
            ((profile shl 6) or (rateIndex shl 2) or (channels shr 2)).toByte(),
            (((channels and 3) shl 6) or (frameLength shr 11)).toByte(),
            (frameLength shr 3).toByte(),
            (((frameLength and 7) shl 5) or 0x1F).toByte(),
            0xFC.toByte(),
        )
    }

    private fun nextContinuity(pid: Int): Int {
        val cc = continuity[pid] ?: 0
        continuity[pid] = (cc + 1) and 0x0F
        return cc
    }

    private fun writePcr(at: Int, pcr: Long) {
        packet[at] = (pcr shr 25).toByte()
        packet[at + 1] = (pcr shr 17).toByte()
        packet[at + 2] = (pcr shr 9).toByte()
        packet[at + 3] = (pcr shr 1).toByte()
        packet[at + 4] = (((pcr and 1) shl 7) or 0x7E).toByte()
        packet[at + 5] = 0
    }

    private fun writePsi(pid: Int, section: ByteArray) {
        packet.fill(0xFF.toByte())
        packet[0] = 0x47
        packet[1] = (0x40 or (pid shr 8)).toByte()
        packet[2] = pid.toByte()
        packet[3] = (0x10 or nextContinuity(pid)).toByte()
        packet[4] = 0 // pointer_field
        section.copyInto(packet, 5)
        out.write(packet)
    }

    // An adaptation-field-only packet carrying a PCR; it doesn't advance the continuity counter.
    private fun writePcrOnly(pcr: Long) {
        packet.fill(0xFF.toByte())
        packet[0] = 0x47
        packet[1] = (VIDEO_PID shr 8).toByte()
        packet[2] = VIDEO_PID.toByte()
        packet[3] = (0x20 or ((continuity[VIDEO_PID] ?: 0) - 1 and 0x0F)).toByte()
        packet[4] = 183.toByte()
        packet[5] = (0x10 or if (started.add(VIDEO_PID)) 0x80 else 0).toByte()
        writePcr(6, pcr)
        out.write(packet)
    }

    private fun writePes(pid: Int, pes: ByteArray, pcr: Long?, randomAccess: Boolean) {
        var position = 0
        var first = true
        while (position < pes.size) {
            packet.fill(0xFF.toByte())
            var flags = 0
            if (first) {
                if (started.add(pid)) flags = flags or 0x80 // discontinuity_indicator
                if (randomAccess) flags = flags or 0x40
                if (pcr != null) flags = flags or 0x10
            }
            // Adaptation field size including its length byte: flags (+ PCR) when needed, then stuffing.
            var adaptation = if (flags != 0) 2 + (if (flags and 0x10 != 0) 6 else 0) else 0
            val payload = minOf(pes.size - position, 184 - adaptation)
            adaptation += 184 - adaptation - payload

            packet[0] = 0x47
            packet[1] = ((if (first) 0x40 else 0) or (pid shr 8)).toByte()
            packet[2] = pid.toByte()
            packet[3] = ((if (adaptation > 0) 0x30 else 0x10) or nextContinuity(pid)).toByte()
            if (adaptation > 0) {
                packet[4] = (adaptation - 1).toByte()
                if (adaptation > 1) {
                    packet[5] = flags.toByte()
                    if (flags and 0x10 != 0) writePcr(6, pcr!!)
                }
            }
            pes.copyInto(packet, 4 + adaptation, position, position + payload)
            out.write(packet)
            position += payload
            first = false
        }
    }

    private fun flush() {
        if (out.size() == 0) return
        sink(out.toByteArray(), out.size())
        out.reset()
    }
}
