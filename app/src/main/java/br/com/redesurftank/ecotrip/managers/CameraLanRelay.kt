package br.com.redesurftank.ecotrip.managers

import java.io.IOException
import java.io.InputStream
import java.nio.ByteBuffer
import java.util.ArrayDeque

/** One live pair; no network write or recorder call is made under this monitor. */
class CameraLanRelay {
    private var producer = false
    private var viewer = false
    private var config: ByteArray? = null
    private var deliveredConfig: ByteArray? = null
    private var recovering = true
    private var keyframeRequested = false
    private val queue = ArrayDeque<ByteArray>()
    private var queuedBytes = 0
    private var inFlight: ByteArray? = null

    @Synchronized fun join(role: String): Boolean = when (role) {
        "producer" -> if (producer) false else { producer = true; true }
        "viewer" -> if (viewer) false else {
            viewer = true; deliveredConfig = null; recovering = true; keyframeRequested = true
            config?.let { enqueue(it) }; true
        }
        else -> false
    }

    @Synchronized fun offer(bytes: ByteArray, binary: Boolean): Boolean {
        if (!producer || !binary) return false
        val kind = validate(bytes) ?: return false
        if (kind == 1) {
            config = bytes.copyOf()
            queue.clear(); queuedBytes = 0; recovering = true
            if (viewer) {
                if (fits(config!!.size, 1)) enqueue(config!!) else drop()
            }
            return true
        }
        val currentConfig = config ?: return false
        if (!viewer) return true
        val key = kind == 3
        if (recovering && !key) return true
        if (recovering && deliveredConfig !== currentConfig && queue.none { it === currentConfig } && inFlight !== currentConfig) {
            if (!fits(currentConfig.size + bytes.size, 2)) { drop(); return true }
            enqueue(currentConfig)
        }
        if (!fits(bytes.size, 1)) { drop(); return true }
        enqueue(bytes.copyOf())
        if (key) recovering = false
        return true
    }

    @Synchronized fun poll(): ByteArray? {
        if (inFlight != null) return null
        return queue.pollFirst()?.also { queuedBytes -= it.size; inFlight = it }
    }
    @Synchronized fun delivered() {
        inFlight?.takeIf { it[5].toInt() == 1 }?.let { deliveredConfig = it }
        inFlight = null
    }
    @Synchronized fun takeKeyframeRequest(): Boolean = keyframeRequested.also { keyframeRequested = false }
    @Synchronized fun stats(): Map<String, Int> = mapOf("messages" to queue.size + if (inFlight == null) 0 else 1,
        "bytes" to queuedBytes + (inFlight?.size ?: 0))
    @Synchronized fun disconnect() {
        producer = false; viewer = false; config = null; deliveredConfig = null; recovering = true
        queue.clear(); queuedBytes = 0; inFlight = null; keyframeRequested = false
    }
    private fun fits(bytes: Int, messages: Int) = queuedBytes + (inFlight?.size ?: 0) + bytes <= 1_048_576 &&
        queue.size + (if (inFlight == null) 0 else 1) + messages <= 30
    private fun enqueue(bytes: ByteArray) { queue.addLast(bytes); queuedBytes += bytes.size }
    private fun drop() { queue.clear(); queuedBytes = 0; deliveredConfig = null; recovering = true; keyframeRequested = true }

    private fun validate(bytes: ByteArray): Int? {
        if (bytes.size !in 25..4_194_328) return null
        val b = ByteBuffer.wrap(bytes)
        if (b.int != 0x48564331 || b.get().toInt() != 1) return null
        val type = b.get().toInt(); val flags = b.short.toInt() and 0xffff
        b.int
        if (b.long < 0 || b.int != b.remaining() || type !in 1..2 || flags !in 0..1 || (type == 1 && flags != 0)) return null
        if (type == 1) {
            repeat(2) {
                if (b.remaining() < 2) return null
                val size = b.short.toInt() and 0xffff
                if (size == 0 || size > b.remaining()) return null
                b.position(b.position() + size)
            }
            return if (b.hasRemaining()) null else 1
        }
        var count = 0
        while (b.hasRemaining()) {
            if (b.remaining() < 4) return null
            val size = b.int
            if (size <= 0 || size > b.remaining()) return null
            b.position(b.position() + size); count++
        }
        return if (count == 0) null else if (flags == 1) 3 else 2
    }
}

/** Validates WS lengths before NanoWSD allocates payloads; fragmented messages share a cap. */
class CameraLanFrameInput(private val source: InputStream) : InputStream() {
    private var header = ByteArray(0)
    private var headerOffset = 0
    private var remaining = 0L
    private var fragmented = false
    private var messageBytes = 0L
    private var fragments = 0
    override fun read(): Int {
        if (headerOffset < header.size) return header[headerOffset++].toInt() and 255
        if (remaining > 0) { remaining--; return required() }
        readHeader()
        return header[headerOffset++].toInt() and 255
    }
    override fun read(bytes: ByteArray, off: Int, len: Int): Int {
        if (len == 0) return 0
        if (headerOffset < header.size || remaining == 0L) { bytes[off] = read().toByte(); return 1 }
        val n = readWithSessionTimeout { source.read(bytes, off, minOf(len.toLong(), remaining).toInt()) }
        if (n < 0) throw IOException("Truncated video frame")
        remaining -= n
        return n
    }
    private fun required(): Int = readWithSessionTimeout { source.read() }.also {
        if (it < 0) throw IOException("Truncated video frame")
    }
    private fun readWithSessionTimeout(read: () -> Int): Int {
        while (true) {
            try { return read() } catch (_: java.net.SocketTimeoutException) {
                // HTTP's idle timeout does not end a receive-only viewer. The owner closes
                // this input on session expiry, failed output, disconnect or server shutdown.
            }
        }
    }
    private fun readHeader() {
        val first = required(); val second = required()
        val op = first and 15; val fin = first and 128 != 0
        if (first and 112 != 0 || second and 128 == 0 || op !in setOf(0, 2, 8, 9, 10)) throw IOException("Invalid video frame")
        val h = ArrayList<Byte>(); h.add(first.toByte()); h.add(second.toByte())
        var length = (second and 127).toLong()
        if (length >= 126) {
            val n = if (length == 126L) 2 else 8
            length = 0
            repeat(n) { val v = required(); h.add(v.toByte()); if (length > 4_194_328L) throw IOException("Video frame too large"); length = (length shl 8) or v.toLong() }
        }
        if (op >= 8) {
            if (!fin || length > 125) throw IOException("Invalid video control")
        } else {
            if ((op == 0) != fragmented) throw IOException("Invalid video fragmentation")
            if (op == 2) { messageBytes = 0; fragments = 0 }
            if (++fragments > 1024) throw IOException("Too many video fragments")
            messageBytes += length
            if (messageBytes > 4_194_328L) throw IOException("Video frame too large")
            fragmented = !fin
        }
        repeat(4) { h.add(required().toByte()) }
        header = h.toByteArray(); headerOffset = 0; remaining = length
    }
    override fun close() = source.close()
}
