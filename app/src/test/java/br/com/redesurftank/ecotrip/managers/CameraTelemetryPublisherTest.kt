package br.com.redesurftank.ecotrip.managers

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraTelemetryPublisherTest {
    private class FakeSink : CameraTelemetryPublisher.Sink {
        val samples = mutableListOf<CameraTelemetryPublisher.Sample>()
        var fail = false
        override fun send(sample: CameraTelemetryPublisher.Sample): Boolean {
            samples += sample
            if (fail) throw IllegalStateException("camera absent")
            return true
        }
    }

    @Test fun publishesAtMostFiveHertzWhileActive() {
        var mono = 1_000L
        val sink = FakeSink()
        val publisher = CameraTelemetryPublisher(sink, { true }, { mono }, { 10_000L + mono })
        publisher.onCanValue(CameraTelemetryPublisher.SPEED_KEY, "42.5")
        publisher.onCanValue(CameraTelemetryPublisher.MOTOR_POWER_KEY, "-12.25")

        assertTrue(publisher.publishIfDue())
        mono += 199
        assertFalse(publisher.publishIfDue())
        mono += 1
        assertTrue(publisher.publishIfDue())
        assertEquals(2, sink.samples.size)
    }

    @Test fun rejectsStaleSourcesAndDoesNothingWhileInactive() {
        var mono = 1_000L
        val sink = FakeSink()
        var active = true
        val publisher = CameraTelemetryPublisher(sink, { active }, { mono }, { 50_000L })
        publisher.onCanValue(CameraTelemetryPublisher.SPEED_KEY, "20")
        mono += 2_001

        assertFalse(publisher.publishIfDue())
        active = false
        publisher.onCanValue(CameraTelemetryPublisher.SPEED_KEY, "21")
        assertFalse(publisher.publishIfDue())
        assertTrue(sink.samples.isEmpty())
    }

    @Test fun cameraFailureNeverEscapesTelemetryPath() {
        var mono = 1_000L
        val sink = FakeSink().apply { fail = true }
        val publisher = CameraTelemetryPublisher(sink, { true }, { mono }, { 50_000L })
        publisher.onCanValue(CameraTelemetryPublisher.SPEED_KEY, "20")

        assertFalse(publisher.publishIfDue())
        mono += 200
        assertFalse(publisher.publishIfDue())
    }
}
