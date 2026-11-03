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
    @Test fun emptyFragmentsCannotGrowNanoWsdFragmentListWithoutBound() {
        val bytes = byteArrayOf(2, 0x80.toByte(), 0, 0, 0, 0) +
            ByteArray(6 * 1100) { if (it % 6 == 1) 0x80.toByte() else 0 }
        val source = ByteArrayInputStream(bytes)
        val guard = LanTest.create("CameraLanFrameInput", source) as InputStream
        try { guard.readBytes(); fail("Expected fragment rejection") } catch (_: java.io.IOException) { }
        assertTrue("Reject before retaining over 1024 fragment headers", source.available() >= 6 * 75)
    }

    @Test fun boundedInputPreservesValidMaskedBinaryAndFragmentedMessages() {
        val frames = listOf(
            byteArrayOf(0x82.toByte(), 0x82.toByte(), 0, 0, 0, 0, 1, 2),
            byteArrayOf(2, 0x81.toByte(), 0, 0, 0, 0, 1, 0x80.toByte(), 0x81.toByte(), 0, 0, 0, 0, 2))
        for (bytes in frames) {
            val guard = LanTest.create("CameraLanFrameInput", ByteArrayInputStream(bytes)) as InputStream
            val received = ByteArray(bytes.size)
            for (i in bytes.indices) received[i] = guard.read().toByte()
            assertArrayEquals(bytes, received)
        }
    }

    @Test fun changedConfigDuringInFlightWriteStillHonorsQueueByteCap() {
        val r = relay(); ready(r); drain(r); LanTest.call(r, "takeKeyframeRequest")
        offer(r, frame(1_048_000))
        assertNotNull(poll(r))
        val payload = ByteBuffer.allocate(4 + 2 * 1000).putShort(1000).put(ByteArray(1000) { 0x67 })
            .putShort(1000).put(ByteArray(1000) { 0x68 }).array()
        val changed = ByteBuffer.allocate(24 + payload.size).putInt(0x48564331).put(1).put(1)
            .putShort(0).putInt(4).putLong(0).putInt(payload.size).put(payload).array()
        offer(r, changed)
        assertEquals(true, LanTest.call(r, "takeKeyframeRequest"))
        assertTrue((LanTest.map(LanTest.call(r, "stats"))["bytes"] as Int) <= 1_048_576)
        delivered(r); offer(r, key)
        assertArrayEquals(changed, poll(r))
    }

    @Test fun videoInputSurvivesHttpIdleTimeoutUntilSessionOwnerClosesIt() {
        val bytes = byteArrayOf(0x82.toByte(), 0x81.toByte(), 0, 0, 0, 0, 1)
        val source = object : ByteArrayInputStream(bytes) {
            var timeout = true
            override fun read(): Int {
                if (timeout) { timeout = false; throw java.net.SocketTimeoutException("synthetic HTTP timeout") }
                return super.read()
            }
        }
        val guard = LanTest.create("CameraLanFrameInput", source) as InputStream
        val received = ByteArray(bytes.size)
        for (i in bytes.indices) received[i] = guard.read().toByte()
        assertArrayEquals(bytes, received)
    }

    @Test fun watchdogCompletionBetweenSnapshotAndDeadlineDoesNotDropHealthySession() {
        val entered = java.util.concurrent.CountDownLatch(1)
        val release = java.util.concurrent.CountDownLatch(1)
        val completed = java.util.concurrent.CountDownLatch(1)
        var readingDeadline = false
        val writer = LanTest.create("CameraLanFrameWriter", {
            if (readingDeadline) {
                release.countDown()
                await(completed) // Writer clears its timestamp before deadline evaluation resumes.
                11_000L
            } else 10_000L
        }, { _: fi.iki.elonen.NanoWSD.WebSocketFrame -> entered.countDown(); await(release); Unit })
        val failure = java.util.concurrent.atomic.AtomicReference<Throwable>()
        val sender = kotlin.concurrent.thread {
            try { LanTest.call(writer, "sendFrame", binaryFrame()) } catch (t: Throwable) { failure.set(t) }
            finally { completed.countDown() }
        }
        try {
            await(entered)
            readingDeadline = true
            assertEquals(false, LanTest.call(writer, "writeTimedOut"))
            await(completed)
            assertNull(failure.get())
        } finally { release.countDown(); sender.join(5_000) }
    }

    @Test fun automaticPongAndCloseRepliesParticipateInWatchdogAndAbortCleanup() {
        for (opcode in listOf(fi.iki.elonen.NanoWSD.WebSocketFrame.OpCode.Ping,
                fi.iki.elonen.NanoWSD.WebSocketFrame.OpCode.Close)) {
            assertBlockedFrameIsTimed { socket ->
                val receive = fi.iki.elonen.NanoWSD.WebSocket::class.java.getDeclaredMethod(
                    "handleWebsocketFrame", fi.iki.elonen.NanoWSD.WebSocketFrame::class.java).apply { isAccessible = true }
                try { receive.invoke(socket, fi.iki.elonen.NanoWSD.WebSocketFrame(opcode, true, byteArrayOf())) }
                catch (failure: java.lang.reflect.InvocationTargetException) { throw failure.targetException }
            }
        }
    }

    @Test fun binaryMediaAndTextKeyframeRequestUseTheSameTimedWriter() {
        assertBlockedFrameIsTimed { it.send(config) }
        assertBlockedFrameIsTimed { it.send("{\"type\":\"request_keyframe\"}") }
    }

    @Test fun serializedWriterCompletionCannotClearTheNextWrite() {
        val now = java.util.concurrent.atomic.AtomicLong(1_000)
        val firstEntered = java.util.concurrent.CountDownLatch(1)
        val secondEntered = java.util.concurrent.CountDownLatch(1)
        val releaseFirst = java.util.concurrent.CountDownLatch(1)
        val releaseSecond = java.util.concurrent.CountDownLatch(1)
        val firstCompleted = java.util.concurrent.CountDownLatch(1)
        val call = java.util.concurrent.atomic.AtomicInteger()
        val writer = LanTest.create("CameraLanFrameWriter", { now.get() }, { _: fi.iki.elonen.NanoWSD.WebSocketFrame ->
            if (call.incrementAndGet() == 1) { firstEntered.countDown(); await(releaseFirst) }
            else { secondEntered.countDown(); await(releaseSecond) }
            Unit
        })
        val send = writer.javaClass.getMethod("sendFrame", fi.iki.elonen.NanoWSD.WebSocketFrame::class.java)
        assertTrue("Hold one writer monitor through finally", java.lang.reflect.Modifier.isSynchronized(send.modifiers))
        val failures = java.util.concurrent.ConcurrentLinkedQueue<Throwable>()
        val first = kotlin.concurrent.thread {
            try { LanTest.call(writer, "sendFrame", binaryFrame()) } catch (t: Throwable) { failures.add(t) }
            finally { firstCompleted.countDown() }
        }
        var second: Thread? = null
        try {
            await(firstEntered)
            now.set(2_000)
            second = kotlin.concurrent.thread {
                try { LanTest.call(writer, "sendFrame", binaryFrame()) } catch (t: Throwable) { failures.add(t) }
            }
            releaseFirst.countDown()
            await(secondEntered); await(firstCompleted)
            now.set(5_001)
            assertEquals(true, LanTest.call(writer, "writeTimedOut"))
            releaseSecond.countDown(); second.join(5_000)
            assertFalse(second.isAlive)
            assertEquals(false, LanTest.call(writer, "writeTimedOut"))
            assertTrue(failures.isEmpty())
        } finally { releaseFirst.countDown(); releaseSecond.countDown(); first.join(5_000); second?.join(5_000) }
    }

    @Test fun writeFailureAlwaysClearsWatchdogState() {
        val now = java.util.concurrent.atomic.AtomicLong(1_000)
        val writer = LanTest.create("CameraLanFrameWriter", { now.get() }, { _: fi.iki.elonen.NanoWSD.WebSocketFrame ->
            throw java.io.IOException("synthetic write failure")
        })
        try { LanTest.call(writer, "sendFrame", binaryFrame()); fail("Expected write failure") }
        catch (_: java.io.IOException) { }
        now.set(10_000)
        assertEquals(false, LanTest.call(writer, "writeTimedOut"))
    }

    @Test fun videoSocketInstrumentsTheSharedNanoWsdFrameBoundary() {
        val type = Class.forName("br.com.redesurftank.ecotrip.managers.LocalApiServer\$VideoWebSocket")
        assertTrue("Automatic replies must dispatch through the video override", type.declaredMethods.any {
            it.name == "sendFrame" && it.parameterTypes.contentEquals(arrayOf(fi.iki.elonen.NanoWSD.WebSocketFrame::class.java))
        })
    }

    private fun assertBlockedFrameIsTimed(send: (TimedSocket) -> Unit) {
        val now = java.util.concurrent.atomic.AtomicLong(1_000)
        val entered = java.util.concurrent.CountDownLatch(1)
        val closed = java.util.concurrent.CountDownLatch(1)
        val completed = java.util.concurrent.CountDownLatch(1)
        val input = object : ByteArrayInputStream(byteArrayOf()) {
            override fun close() { closed.countDown() }
        }
        val output = object : java.io.OutputStream() {
            override fun write(value: Int) {
                entered.countDown(); await(closed)
                throw java.io.IOException("synthetic socket abort")
            }
        }
        val socket = TimedSocket(input, output) { now.get() }
        val failure = java.util.concurrent.atomic.AtomicReference<Throwable>()
        val sender = kotlin.concurrent.thread {
            try { send(socket) } catch (t: Throwable) { failure.set(t) }
            finally { completed.countDown() }
        }
        try {
            await(entered)
            now.set(4_000); assertEquals(false, LanTest.call(socket.writer, "writeTimedOut"))
            now.set(4_001); assertEquals(true, LanTest.call(socket.writer, "writeTimedOut"))
            input.close() // The existing session watchdog aborts the underlying socket input.
            await(completed)
            assertTrue(failure.get() is java.io.IOException)
            assertEquals(false, LanTest.call(socket.writer, "writeTimedOut"))
        } finally { input.close(); sender.join(5_000) }
    }

    private class TimedSocket(input: InputStream, output: java.io.OutputStream, clock: () -> Long) :
        fi.iki.elonen.NanoWSD.WebSocket(java.lang.reflect.Proxy.newProxyInstance(
            fi.iki.elonen.NanoHTTPD.IHTTPSession::class.java.classLoader,
            arrayOf(fi.iki.elonen.NanoHTTPD.IHTTPSession::class.java),
        ) { _, method, _ -> if (method.name == "getInputStream") input else null } as fi.iki.elonen.NanoHTTPD.IHTTPSession) {
        val writer = LanTest.create("CameraLanFrameWriter", clock,
            { frame: fi.iki.elonen.NanoWSD.WebSocketFrame -> super.sendFrame(frame) })
        init {
            // Install only the transport boundary; exercise NanoWSD's real automatic reply handlers.
            fi.iki.elonen.NanoWSD.WebSocket::class.java.getDeclaredField("out").apply { isAccessible = true }.set(this, output)
            fi.iki.elonen.NanoWSD.WebSocket::class.java.getDeclaredField("state").apply { isAccessible = true }
                .set(this, fi.iki.elonen.NanoWSD.State.OPEN)
        }
        override fun sendFrame(frame: fi.iki.elonen.NanoWSD.WebSocketFrame) { LanTest.call(writer, "sendFrame", frame) }
        override fun onOpen() { }
        override fun onClose(code: fi.iki.elonen.NanoWSD.WebSocketFrame.CloseCode?, reason: String?, initiatedByRemote: Boolean) { }
        override fun onMessage(message: fi.iki.elonen.NanoWSD.WebSocketFrame) { }
        override fun onPong(pong: fi.iki.elonen.NanoWSD.WebSocketFrame) { }
        override fun onException(exception: java.io.IOException) { }
    }

    private fun binaryFrame() = fi.iki.elonen.NanoWSD.WebSocketFrame(fi.iki.elonen.NanoWSD.WebSocketFrame.OpCode.Binary, true, config)
    private fun await(latch: java.util.concurrent.CountDownLatch) {
        assertTrue("Timed out waiting for controlled interleaving", latch.await(5, java.util.concurrent.TimeUnit.SECONDS))
    }

    private fun frame(payload: Int): ByteArray = ByteBuffer.allocate(24 + payload)
        .putInt(0x48564331).put(1).put(2).putShort(1).putInt(3).putLong(0).putInt(payload)
        .putInt(payload - 4).put(ByteArray(payload - 4) { 0x65 }).array()
    private fun hex(value: String) = value.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
}
