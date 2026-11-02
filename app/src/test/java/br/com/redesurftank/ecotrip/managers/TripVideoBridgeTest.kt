package br.com.redesurftank.ecotrip.managers

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertFalse
import org.junit.Test

class TripVideoBridgeTest {
    private class MemoryState(
        override var lastTripId: Long? = null,
        override var revision: Long = 0,
    ) : TripVideoBridge.StateStore {
        override fun save(lastTripId: Long?, revision: Long): Boolean {
            this.lastTripId = lastTripId
            this.revision = revision
            return true
        }
    }

    private class FakeSink : TripVideoBridge.CameraCommandSink {
        val commands = mutableListOf<TripVideoBridge.CameraCommand>()
        var result = TripVideoBridge.CommandResult.applied()
        val queuedResults = mutableListOf<TripVideoBridge.CommandResult>()

        override fun send(command: TripVideoBridge.CameraCommand): TripVideoBridge.CommandResult {
            commands += command
            return if (queuedResults.isEmpty()) result else queuedResults.removeAt(0)
        }
    }

    private fun bridge(
        state: MemoryState = MemoryState(),
        sink: FakeSink = FakeSink(),
    ) = TripVideoBridge(state, sink) { 10_000L }

    @Test fun startsNewTripOnce() {
        val sink = FakeSink()
        val bridge = bridge(sink = sink)

        bridge.reconcile(1_000L, emptyMap())
        bridge.reconcile(1_000L, emptyMap())

        assertEquals(listOf(TripVideoBridge.Action.START_TRIP), sink.commands.map { it.action })
        assertEquals(1_000L, sink.commands.single().startMs)
    }

    @Test fun stopsCompletedTrip() {
        val sink = FakeSink()
        val bridge = bridge(MemoryState(lastTripId = 1_000L, revision = 4), sink)

        bridge.reconcile(null, mapOf(1_000L to 9_000L))

        assertEquals(TripVideoBridge.Action.STOP_TRIP, sink.commands.single().action)
        assertEquals(9_000L, sink.commands.single().endMs)
    }

    @Test fun discardsRejectedTrip() {
        val sink = FakeSink()
        val bridge = bridge(MemoryState(lastTripId = 1_000L, revision = 4), sink)

        bridge.reconcile(null, emptyMap())

        assertEquals(TripVideoBridge.Action.DISCARD_TRIP, sink.commands.single().action)
    }

    @Test fun closesAndStartsWhenTripChangesBetweenPolls() {
        val sink = FakeSink()
        val bridge = bridge(MemoryState(lastTripId = 1_000L, revision = 4), sink)

        bridge.reconcile(2_000L, mapOf(1_000L to 8_000L))

        assertEquals(
            listOf(TripVideoBridge.Action.STOP_TRIP, TripVideoBridge.Action.START_TRIP),
            sink.commands.map { it.action },
        )
    }

    @Test fun startupReconcilesAfterProcessRestart() {
        val sink = FakeSink()
        val state = MemoryState(lastTripId = 1_000L, revision = 9)
        val bridge = bridge(state, sink)

        bridge.reconcileStartup(1_000L)

        assertEquals(TripVideoBridge.Action.RECONCILE, sink.commands.single().action)
        assertEquals(10_000L, state.revision)
    }

    @Test fun missingCameraPreservesActiveTripForRetry() {
        val sink = FakeSink().apply { result = TripVideoBridge.CommandResult.unavailable() }
        val state = MemoryState()
        val bridge = bridge(state, sink)

        bridge.reconcile(1_000L, emptyMap())

        assertNull(state.lastTripId)
        assertEquals(0L, state.revision)
    }

    @Test fun staleRevisionRetriesAboveCameraRevision() {
        val sink = FakeSink().apply {
            queuedResults += TripVideoBridge.CommandResult.stale(20_000)
            queuedResults += TripVideoBridge.CommandResult.applied()
        }
        val state = MemoryState(lastTripId = 1_000L, revision = 2)
        val bridge = bridge(state, sink)

        bridge.reconcileStartup(1_000L)

        assertEquals(listOf(10_000L, 20_001L), sink.commands.map { it.revision })
        assertEquals(20_001L, state.revision)
    }

    @Test fun rejectionAndErrorNeverPersistCommandedState() {
        for (failure in listOf(
            TripVideoBridge.CommandResult.rejected(),
            TripVideoBridge.CommandResult.error(),
        )) {
            val state = MemoryState()
            val sink = FakeSink().apply { result = failure }
            assertFalse(bridge(state, sink).reconcile(1_000L, emptyMap()))
            assertNull(state.lastTripId)
            assertEquals(0L, state.revision)
        }
    }

    @Test fun confirmedNoOpPersistsCommandedState() {
        val state = MemoryState()
        val sink = FakeSink().apply { result = TripVideoBridge.CommandResult.noOp() }

        bridge(state, sink).reconcile(1_000L, emptyMap())

        assertEquals(1_000L, state.lastTripId)
        assertEquals(10_000L, state.revision)
    }

    @Test fun stopThenResumeUsesOriginalTripIdentityAndStart() {
        val state = MemoryState(lastTripId = 1_000L, revision = 4)
        val sink = FakeSink()
        val bridge = bridge(state, sink)

        bridge.reconcile(null, mapOf(1_000L to 9_000L))
        bridge.reconcile(1_000L, mapOf(1_000L to 9_000L))

        assertEquals(listOf(TripVideoBridge.Action.STOP_TRIP, TripVideoBridge.Action.START_TRIP),
            sink.commands.map { it.action })
        assertEquals(1_000L, sink.commands.last().tripId)
        assertEquals(1_000L, sink.commands.last().startMs)
    }

    @Test fun failedCatalogRevisionCommitCannotReuseRevision() {
        val backend = FakeCatalogRevisionBackend("old", 7, fail = true)
        val store = CameraCatalogRevisionStore(backend)

        assertFalse(runCatching { store.revisionFor("new") }.isSuccess)
        assertEquals("old", backend.body)
        assertEquals(7L, backend.revision)
        backend.fail = false
        assertEquals(8L, store.revisionFor("new"))
    }

    private class FakeCatalogRevisionBackend(
        override var body: String?,
        override var revision: Long,
        var fail: Boolean,
    ) : CameraCatalogRevisionStore.Backend {
        override fun save(body: String, revision: Long): Boolean {
            if (fail) return false
            this.body = body
            this.revision = revision
            return true
        }
    }
}
