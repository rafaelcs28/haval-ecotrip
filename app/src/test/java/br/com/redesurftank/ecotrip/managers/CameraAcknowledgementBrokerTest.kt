package br.com.redesurftank.ecotrip.managers

import java.util.concurrent.Executors
import org.junit.Assert.assertEquals
import org.junit.Test

class CameraAcknowledgementBrokerTest {
    @Test fun confirmedNoOpAndAppliedAreDistinctSuccesses() {
        val broker = CameraAcknowledgementBroker(200)
        assertEquals(TripVideoBridge.CommandResult.Status.APPLIED, execute(broker, "a", 1, "APPLIED", 1).status)
        assertEquals(TripVideoBridge.CommandResult.Status.NO_OP, execute(broker, "b", 2, "NO_OP", 2).status)
    }

    @Test fun staleRejectionErrorAndTimeoutNeverBecomeApplied() {
        val broker = CameraAcknowledgementBroker(40)
        val stale = execute(broker, "stale", 3, "STALE", 8)
        assertEquals(TripVideoBridge.CommandResult.Status.STALE, stale.status)
        assertEquals(8, stale.cameraRevision)
        assertEquals(TripVideoBridge.CommandResult.Status.REJECTED,
            execute(broker, "rejected", 4, "REJECTED", 8).status)
        assertEquals(TripVideoBridge.CommandResult.Status.ERROR,
            execute(broker, "error", 5, "ERROR", 8).status)
        assertEquals(TripVideoBridge.CommandResult.Status.UNAVAILABLE,
            broker.dispatchAndAwait("timeout", 6) {}.status)
    }

    @Test fun mismatchedRevisionCannotCompleteAnotherRequest() {
        val broker = CameraAcknowledgementBroker(40)
        val executor = Executors.newSingleThreadExecutor()
        try {
            val future = executor.submit<TripVideoBridge.CommandResult> {
                broker.dispatchAndAwait("same", 7) { }
            }
            Thread.sleep(5)
            broker.complete(CameraCommandAcknowledgement("same", 8, 8, "APPLIED"))
            assertEquals(TripVideoBridge.CommandResult.Status.UNAVAILABLE, future.get().status)
        } finally {
            executor.shutdownNow()
        }
    }

    private fun execute(
        broker: CameraAcknowledgementBroker,
        requestId: String,
        revision: Long,
        status: String,
        cameraRevision: Long,
    ): TripVideoBridge.CommandResult = broker.dispatchAndAwait(requestId, revision) {
        broker.complete(CameraCommandAcknowledgement(requestId, revision, cameraRevision, status))
    }
}
