package br.com.redesurftank.ecotrip.managers

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.InputStream

class CameraLanDownloadsTest {
    private var closed = 0
    private var opened = 0
    private var requested = ""
    private val trips = listOf(
        mapOf("tripId" to "1000", "endMs" to 2000L, "segments" to 2, "completed" to true),
        mapOf("tripId" to "2000", "endMs" to 0L, "segments" to 1, "completed" to false))
    private fun downloads(failRead: Boolean = false) = LanTest.create("CameraLanDownloads", { trips },
        { trip: String, segment: String ->
            opened++; requested = "$trip/$segment"
            val input = object : ByteArrayInputStream("0123456789".toByteArray()) {
                override fun close() { closed++; super.close() }
                override fun read(b: ByteArray, off: Int, len: Int): Int {
                    if (failRead) throw java.io.IOException("synthetic read failure")
                    return super.read(b, off, len)
                }
            }
            Pair(input as InputStream, 10L)
        })
    private fun open(d: Any, trip: String = "1000", segment: String = "1", range: String? = null) =
        LanTest.map(LanTest.call(d, "open", trip, segment, range))
    @Test fun catalogOnlyExposesCompletedProviderMetadata() {
        val catalog = LanTest.call(downloads(), "catalog") as List<*>
        assertEquals(1, catalog.size)
        assertEquals("1000", (catalog.single() as Map<*, *>)["tripId"])
    }
    @Test fun strictIdsAndCompletedMembershipBeforeProviderOpen() {
        val d = downloads()
        for ((trip, segment) in listOf("../1000" to "1", "1000" to "1.partial", "01000" to "1",
                "1000" to "0", "1000" to "3", "2000" to "1", "9223372036854775808" to "1",
                "1000" to "%2e%2e", "1000" to "1/../../secret")) {
            assertEquals(404, open(d, trip, segment)["status"])
        }
        assertEquals(0, opened)
    }
    @Test fun fullResponseHoldsLeaseUntilStreamClose() {
        val result = open(downloads())
        assertEquals(200, result["status"]); assertEquals("1000/1", requested)
        assertEquals(0, closed)
        val body = result["body"] as InputStream
        assertEquals("0123456789", String(body.readBytes()))
        assertEquals(0, closed)
        body.close(); body.close(); assertEquals(1, closed)
    }
    @Test fun byteRangesOpenEndedSuffixAndClampedEnd() {
        val d = downloads()
        for ((range, want, contentRange) in listOf(
            Triple("bytes=2-4", "234", "bytes 2-4/10"),
            Triple("bytes=7-", "789", "bytes 7-9/10"),
            Triple("bytes=-3", "789", "bytes 7-9/10"),
            Triple("bytes=8-999", "89", "bytes 8-9/10"))) {
            val result = open(d, range = range)
            assertEquals(206, result["status"]); assertEquals(contentRange, result["contentRange"])
            (result["body"] as InputStream).use { assertEquals(want, String(it.readBytes())) }
        }
        assertEquals(4, closed)
    }
    @Test fun unsatisfiableMalformedOverflowAndMultiRangesReturn416AndRelease() {
        val d = downloads()
        for (range in listOf("bytes=10-", "bytes=5-2", "bytes=-0", "bytes=0-1,4-5",
                "items=0-1", "bytes=9223372036854775808-", "bytes=+1-3")) {
            val result = open(d, range = range)
            assertEquals(416, result["status"]); assertEquals("bytes */10", result["contentRange"])
        }
        assertEquals(opened, closed)
    }
    @Test fun httpResponseReleasesLeaseWhenClientWriteFails() {
        val result = open(downloads())
        val response = LanTest.create("CameraLanDownloadResponse", result)
        val send = response.javaClass.getDeclaredMethod("send", java.io.OutputStream::class.java).apply { isAccessible = true }
        val output = object : java.io.OutputStream() {
            override fun write(value: Int) { throw java.io.IOException("synthetic disconnect") }
        }
        send.invoke(response, output)
        assertEquals(1, closed)
    }

    @Test fun disconnectAndReadFailureReleaseExactlyOnce() {
        val result = open(downloads(), range = "bytes=1-8")
        val body = result["body"] as InputStream
        assertEquals('1'.code, body.read()); body.close(); assertEquals(1, closed)
        val broken = open(downloads(true))["body"] as InputStream
        try { broken.read(ByteArray(2)); fail("Expected read failure") } catch (_: java.io.IOException) { }
        broken.close(); assertEquals(2, closed)
    }
}
