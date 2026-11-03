package br.com.redesurftank.ecotrip.managers

import android.content.Context
import android.net.Uri
import android.os.ParcelFileDescriptor
import java.io.InputStream
import java.io.IOException

/** Catalog membership and Range decisions. Only the provider opens a completed segment. */
class CameraLanDownloads(
    private val completedTrips: () -> List<Map<String, Any>>,
    private val openSegment: (String, String) -> Pair<InputStream, Long>,
) {
    fun catalog(): List<Map<String, Any>> = completedTrips().filter {
        it["completed"] == true && numeric(it["tripId"]?.toString() ?: "") &&
            (it["endMs"] as? Number)?.toLong()?.let { end -> end > 0 } == true
    }.map { it - "completed" }

    fun open(tripId: String, segmentId: String, range: String?): Map<String, Any> {
        if (!numeric(tripId) || !numeric(segmentId)) return mapOf("status" to 404)
        val trip = catalog().find { it["tripId"] == tripId } ?: return mapOf("status" to 404)
        if (segmentId.toLong() > ((trip["segments"] as? Number)?.toLong() ?: 0L)) return mapOf("status" to 404)
        val (input, size) = try { openSegment(tripId, segmentId) } catch (_: Exception) { return mapOf("status" to 404) }
        try {
            val bounds = bounds(range, size)
            if (bounds == null) {
                input.close()
                return mapOf("status" to 416, "contentRange" to "bytes */${maxOf(size, 0)}")
            }
            val (start, end) = bounds
            var skipped = 0L
            while (skipped < start) {
                val n = input.skip(start - skipped)
                if (n > 0) skipped += n else {
                    if (input.read() < 0) throw IOException("Segment unavailable")
                    skipped++
                }
            }
            val length = end - start + 1
            val body = LeaseStream(input, length)
            return mapOf("status" to if (range == null) 200 else 206, "body" to body,
                "length" to length, "contentRange" to "bytes $start-$end/$size")
        } catch (_: Exception) {
            runCatching { input.close() }
            return mapOf("status" to 404)
        }
    }

    private fun numeric(value: String) = value.matches(Regex("[1-9][0-9]{0,18}")) && value.toLongOrNull() != null
    private fun bounds(range: String?, size: Long): Pair<Long, Long>? {
        if (size <= 0) return null
        if (range == null) return 0L to size - 1
        val match = Regex("bytes=([0-9]*)-([0-9]*)").matchEntire(range) ?: return null
        val (a, b) = match.destructured
        if (a.isEmpty()) {
            val suffix = b.toLongOrNull()?.takeIf { it > 0 } ?: return null
            return maxOf(0, size - suffix) to size - 1
        }
        val start = a.toLongOrNull()?.takeIf { it < size } ?: return null
        val end = if (b.isEmpty()) size - 1 else b.toLongOrNull() ?: return null
        return if (end < start) null else start to minOf(end, size - 1)
    }

    private class LeaseStream(private val source: InputStream, private var remaining: Long) : InputStream() {
        private var closed = false
        override fun read(): Int {
            val b = ByteArray(1)
            return if (read(b, 0, 1) < 0) -1 else b[0].toInt() and 255
        }
        override fun read(b: ByteArray, off: Int, len: Int): Int {
            if (len == 0) return 0
            if (closed || remaining == 0L) return -1
            return try {
                val n = source.read(b, off, minOf(remaining, len.toLong()).toInt())
                if (n < 0) throw IOException("Truncated segment")
                remaining -= n; n
            } catch (failure: Exception) { close(); throw failure }
        }
        @Synchronized override fun close() { if (!closed) { closed = true; source.close() } }
    }

    companion object {
        fun from(context: Context): CameraLanDownloads = CameraLanDownloads({
            val trips = mutableListOf<Map<String, Any>>()
            context.contentResolver.query(Uri.parse("content://${CameraVideoContract.AUTHORITY}/trips"), null, null, null, null)?.use { c ->
                while (c.moveToNext()) {
                    fun number(name: String) = c.getLong(c.getColumnIndexOrThrow(name))
                    trips += mapOf("tripId" to number("trip_id").toString(), "startMs" to number("start_ms"),
                        "endMs" to number("end_ms"), "byteSize" to number("byte_size"),
                        "segments" to number("segments"), "source" to c.getString(c.getColumnIndexOrThrow("source")),
                        "completed" to true)
                }
            } ?: throw IOException("Camera unavailable")
            trips
        }, { trip, segment ->
            val uri = Uri.parse("content://${CameraVideoContract.AUTHORITY}/trips/$trip/segments/$segment")
            val descriptor = context.contentResolver.openFileDescriptor(uri, "r") ?: throw IOException("Segment unavailable")
            val size = descriptor.statSize
            ParcelFileDescriptor.AutoCloseInputStream(descriptor) to size
        })
    }
}
