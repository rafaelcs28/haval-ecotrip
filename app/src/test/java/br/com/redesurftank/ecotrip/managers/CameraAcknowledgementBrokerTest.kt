package br.com.redesurftank.ecotrip.managers

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
        assertEquals(8L, stale.cameraRevision)
        assertEquals(TripVideoBridge.CommandResult.Status.REJECTED,
            execute(broker, "rejected", 4, "REJECTED", 8).status)
        assertEquals(TripVideoBridge.CommandResult.Status.ERROR,
            execute(broker, "error", 5, "ERROR", 8).status)
        assertEquals(TripVideoBridge.CommandResult.Status.UNAVAILABLE,
            broker.dispatchAndAwait("timeout", 6) {}.status)
    }

    @Test fun mismatchedRevisionCannotCompleteAnotherRequest() {
        val broker = CameraAcknowledgementBroker(40)
        val result = broker.dispatchAndAwait("same", 7) {
            broker.complete(CameraCommandAcknowledgement("same", 8, 8, "APPLIED"))
        }
        assertEquals(TripVideoBridge.CommandResult.Status.UNAVAILABLE, result.status)
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
