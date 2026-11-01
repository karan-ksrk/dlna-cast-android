package io.github.karan_ksrk.dlna_cast.screen

import android.util.Log
import java.io.BufferedOutputStream
import java.io.InputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException
import java.security.SecureRandom
import java.time.ZoneOffset
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.concurrent.CopyOnWriteArraySet
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlin.concurrent.thread

private const val TAG = "LiveServer"
private const val SERVER_HEADER = "dlna-cast-android/0.1 UPnP/1.0 DLNADOC/1.50"
private const val CONTENT_FEATURES = "DLNA.ORG_OP=00;DLNA.ORG_CI=1;DLNA.ORG_FLAGS=8D100000000000000000000000000000"

/**
 * Fans one live MPEG-TS stream out to every connected renderer. Data arrives in whole TS packets, so a client that
 * joins late, or loses data because it fell behind, still receives packets it can resync on.
 */
class LiveBroadcast(private val maxBacklogBytes: Int = 2 * 1024 * 1024) {
    private class Client {
        val queue = LinkedBlockingQueue<ByteArray>()
        val queuedBytes = AtomicInteger()
    }

    private val clients = CopyOnWriteArraySet<Client>()
    private val end = ByteArray(0)
    @Volatile private var ended = false
    val bytesSent = AtomicLong()
    val skippedBytes = AtomicLong()
    val clientCount get() = clients.size

    fun push(data: ByteArray, length: Int) {
        if (ended) return
        val chunk = data.copyOf(length)
        for (client in clients) {
            // A renderer that can't keep up loses whole packets instead of stalling the encoder or growing memory.
            if (client.queuedBytes.get() > maxBacklogBytes) {
                skippedBytes.addAndGet(length.toLong())
                continue
            }
            client.queuedBytes.addAndGet(length)
            client.queue.put(chunk)
            bytesSent.addAndGet(length.toLong())
        }
    }

    /** Writes the stream to [write] on the calling thread until the stream ends or the client goes away. */
    fun serve(write: (ByteArray) -> Unit) {
        if (ended) return
        val client = Client()
        clients.add(client)
        try {
            while (true) {
                val chunk = client.queue.take()
                if (chunk === end) return
                client.queuedBytes.addAndGet(-chunk.size)
                write(chunk)
            }
        } finally {
            clients.remove(client)
        }
    }

    fun end() {
        ended = true
        for (client in clients) client.queue.put(end)
    }
}

/**
 * Serves a [LiveBroadcast] at an unguessable path to the renderer's address only, with the headers dlna-cast's
 * desktop media server sends for live streams. Renderers often match DLNA header names case-sensitively.
 */
class LiveServer(host: String, private val broadcast: LiveBroadcast, allow: Collection<String>) {
    private val allowed = allow.toSet()
    private val socket = ServerSocket(0, 8, InetAddress.getByName(host))
    private val mediaPath = "/media/${nonce()}/media.ts"
    private val connections = CopyOnWriteArraySet<Socket>()
    val url = "http://$host:${socket.localPort}$mediaPath"

    init {
        thread(name = "live-accept", isDaemon = true) {
            while (!socket.isClosed) {
                val client = try {
                    socket.accept()
                } catch (_: SocketException) {
                    break
                }
                connections.add(client)
                thread(name = "live-client", isDaemon = true) {
                    try {
                        handle(client)
                    } catch (error: Exception) {
                        Log.d(TAG, "Client ${client.inetAddress.hostAddress} went away: ${error.message}")
                    } finally {
                        connections.remove(client)
                        runCatching { client.close() }
                    }
                }
            }
        }
    }

    private fun nonce(): String {
        val bytes = ByteArray(16).also { SecureRandom().nextBytes(it) }
        return bytes.joinToString("") { "%02x".format(it) }
    }

    private fun readHead(input: InputStream): List<String>? {
        val head = StringBuilder()
        while (head.length < 8192) {
            val byte = input.read()
            if (byte < 0) return null
            head.append(byte.toChar())
            if (head.endsWith("\r\n\r\n") || head.endsWith("\n\n")) return head.lines().filter { it.isNotBlank() }
        }
        return null
    }

    private fun handle(client: Socket) {
        client.soTimeout = 10_000
        client.tcpNoDelay = true
        val lines = readHead(client.getInputStream()) ?: return
        client.soTimeout = 0
        val (method, target, version) = lines.first().split(" ").let {
            Triple(it.getOrElse(0) { "" }, it.getOrElse(1) { "" }, it.getOrElse(2) { "HTTP/1.0" })
        }
        val out = BufferedOutputStream(client.getOutputStream(), 64 * 1024)
        val date = DateTimeFormatter.RFC_1123_DATE_TIME.format(ZonedDateTime.now(ZoneOffset.UTC))

        fun reject(status: String, vararg extra: String) {
            val headers = listOf("HTTP/1.1 $status", "Content-Length: 0", "Connection: close", "Date: $date", *extra)
            out.write((headers.joinToString("\r\n") + "\r\n\r\n").toByteArray())
            out.flush()
        }

        val remote = client.inetAddress.hostAddress?.removePrefix("::ffff:")
        if (remote !in allowed) return reject("403 Forbidden")
        if (target.substringBefore('?') != mediaPath) return reject("404 Not Found")
        if (method != "GET" && method != "HEAD") return reject("405 Method Not Allowed", "Allow: GET, HEAD")

        // HTTP/1.1 clients get chunked encoding, as Node sends; HTTP/1.0 clients get raw data until close.
        val chunked = version == "HTTP/1.1"
        val headers = listOf(
            "HTTP/1.1 200 OK",
            "Content-Type: video/mp2t",
            "transferMode.dlna.org: Streaming",
            "contentFeatures.dlna.org: $CONTENT_FEATURES",
            "Server: $SERVER_HEADER",
            "Accept-Ranges: none",
            "Cache-Control: no-cache",
            "Date: $date",
            if (chunked) "Transfer-Encoding: chunked" else "Connection: close",
            // One request per connection: say so after HEAD rather than leave the renderer a socket that closes.
            *(if (chunked && method == "HEAD") arrayOf("Connection: close") else emptyArray()),
        )
        out.write((headers.joinToString("\r\n") + "\r\n\r\n").toByteArray())
        out.flush()
        if (method == "HEAD") return

        Log.i(TAG, "Streaming to $remote")
        broadcast.serve { chunk ->
            if (chunked) {
                out.write("${Integer.toHexString(chunk.size)}\r\n".toByteArray())
                out.write(chunk)
                out.write("\r\n".toByteArray())
            } else {
                out.write(chunk)
            }
            out.flush()
        }
        if (chunked) out.write("0\r\n\r\n".toByteArray())
        out.flush()
    }

    fun close() {
        runCatching { socket.close() }
        for (connection in connections) runCatching { connection.close() }
    }
}
