package br.com.redesurftank.ecotrip.managers

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.InputStream
import java.nio.ByteBuffer

class CameraLanRelayTest {
    private val config = hex("48564331010100000000000100000000000000000000000c00046742001f000468ce06e2")
    private val key = hex("485643310102000100000002000000000001046b0000000700000003658884")
    private val delta get() = key.copyOf().also { it[7] = 0 }
    private fun relay() = LanTest.create("CameraLanRelay")
    private fun offer(r: Any, bytes: ByteArray, binary: Boolean = true) = LanTest.call(r, "offer", bytes, binary)
    private fun join(r: Any, role: String) = LanTest.call(r, "join", role)
    private fun poll(r: Any) = LanTest.call(r, "poll") as? ByteArray
    private fun delivered(r: Any) = LanTest.call(r, "delivered")
    private fun ready(r: Any) { join(r, "producer"); join(r, "viewer"); offer(r, config); offer(r, key) }
    private fun drain(r: Any) { while (poll(r) != null) delivered(r) }
    @Test fun oneProducerViewerAndKeyframeOnJoin() {
        val r = relay()
        assertEquals(true, join(r, "producer")); assertEquals(false, join(r, "producer"))
        assertEquals(true, join(r, "viewer")); assertEquals(false, join(r, "viewer"))
        assertEquals(true, LanTest.call(r, "takeKeyframeRequest"))
        assertEquals(false, LanTest.call(r, "takeKeyframeRequest"))
    }
    @Test fun configThenKeyframeRequiredBeforeDeltas() {
        val r = relay(); join(r, "producer"); join(r, "viewer")
        assertEquals(false, offer(r, delta))
        assertEquals(true, offer(r, config))
        assertEquals(true, offer(r, delta))
        assertArrayEquals(config, poll(r)); delivered(r); assertNull(poll(r))
        assertEquals(true, offer(r, key)); assertArrayEquals(key, poll(r)); delivered(r)
        offer(r, delta); assertArrayEquals(delta, poll(r))
    }
    @Test fun rejectsTextBadMagicVersionFlagsLengthsAndNalBoundaries() {
        val r = relay(); join(r, "producer")
        assertEquals(false, offer(r, config, false))
        val invalid = listOf(config.copyOf().also { it[0] = 0 }, config.copyOf().also { it[4] = 2 },
            config.copyOf().also { it[7] = 1 }, key.copyOf().also { it[7] = 2 }, key.copyOf(23),
            key + byteArrayOf(0), key.copyOf().also { it[27] = 0 }, config.copyOf().also { it[25] = 0 })
        for (bytes in invalid) assertEquals(false, offer(r, bytes))
    }
    @Test fun exactFourMiBPayloadIsValidButQueueDropsOversizedAccessUnit() {
        val r = relay(); ready(r); drain(r)
        val max = frame(4 * 1024 * 1024)
        assertEquals(true, offer(r, max))
        assertNull(poll(r))
        assertEquals(true, LanTest.call(r, "takeKeyframeRequest"))
        assertEquals(false, offer(r, frame(4 * 1024 * 1024 + 1)))
    }
    @Test fun queueBoundsCountInFlightAndRecoverWithConfigAndKeyframe() {
        val r = relay(); ready(r); drain(r); LanTest.call(r, "takeKeyframeRequest")
        repeat(30) { offer(r, delta) }
        val stats = LanTest.map(LanTest.call(r, "stats")); assertEquals(30, stats["messages"])
        assertNotNull(poll(r)) // In-flight write must still count against the cap.
        offer(r, delta)
        assertTrue((LanTest.map(LanTest.call(r, "stats"))["messages"] as Int) <= 30)
        delivered(r)
        assertEquals(true, LanTest.call(r, "takeKeyframeRequest"))
        assertNull(poll(r))
        offer(r, delta); assertNull(poll(r))
        offer(r, key)
        assertArrayEquals(config, poll(r)); delivered(r)
        assertArrayEquals(key, poll(r)); delivered(r)
        repeat(8) { offer(r, frame(200_000)) }
        assertTrue((LanTest.map(LanTest.call(r, "stats"))["bytes"] as Int) <= 1_048_576)
    }
    @Test fun disconnectClearsBuffersAndDoesNotAllowStaleFrames() {
        val r = relay(); ready(r)
        LanTest.call(r, "disconnect")
        assertNull(poll(r))
        assertEquals(false, offer(r, config))
        assertEquals(0, LanTest.map(LanTest.call(r, "stats"))["bytes"])
    }
    @Test fun websocketGuardRejectsOversizedAndFragmentedFramesBeforeAllocation() {
        for (header in listOf(byteArrayOf(0x82.toByte(), 0xff.toByte(), 0, 0, 0, 0, 0, 0x40, 0, 0x19),
                byteArrayOf(0x02, 0x80.toByte()), byteArrayOf(0x81.toByte(), 0x80.toByte()))) {
            val stream = LanTest.create("CameraLanFrameInput", ByteArrayInputStream(header)) as InputStream
            try { stream.readBytes(); fail("Unsafe WS frame accepted") } catch (_: java.io.IOException) { }
        }
    }
    private fun frame(payload: Int): ByteArray = ByteBuffer.allocate(24 + payload)
        .putInt(0x48564331).put(1).put(2).putShort(1).putInt(3).putLong(0).putInt(payload)
        .putInt(payload - 4).put(ByteArray(payload - 4) { 0x65 }).array()
    private fun hex(value: String) = value.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
}
