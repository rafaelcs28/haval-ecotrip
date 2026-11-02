package br.com.redesurftank.ecotrip.managers

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraVideoContractTest {
    @Test fun exactCameraResultContractAndSerializationAreStable() {
        assertEquals("br.com.redesurftank.havalcamera.action.COMMAND_RESULT", CameraVideoContract.ACTION_COMMAND_RESULT)
        assertEquals("br.com.redesurftank.havalcamera.extra.COMMAND_STATUS", CameraVideoContract.EXTRA_COMMAND_STATUS)
        assertEquals("br.com.redesurftank.havalcamera.extra.CAMERA_REVISION", CameraVideoContract.EXTRA_CAMERA_REVISION)
        assertEquals("br.com.redesurftank.havalcamera.extra.ERROR_MESSAGE", CameraVideoContract.EXTRA_ERROR_MESSAGE)

        val command = TripVideoBridge.CameraCommand(
            TripVideoBridge.Action.START_LIVE, 9, "request-9",
            sessionUrl = "wss://video.example/session",
            producerToken = "t".repeat(32), expiresAtMs = 20_000,
        )
        val envelope = CameraCommandCodec.encode(command)

        assertEquals(CameraVideoContract.ACTION_START_LIVE, envelope.action)
        assertEquals(CameraVideoContract.PROTOCOL_VERSION, envelope.extras[CameraVideoContract.EXTRA_PROTOCOL_VERSION])
        assertEquals("request-9", envelope.extras[CameraVideoContract.EXTRA_REQUEST_ID])
        assertEquals(9L, envelope.extras[CameraVideoContract.EXTRA_STATE_REVISION])
        assertEquals("wss://video.example/session", envelope.extras[CameraVideoContract.EXTRA_SESSION_URL])
        assertEquals("t".repeat(32), envelope.extras[CameraVideoContract.EXTRA_PRODUCER_TOKEN])
        assertEquals(20_000L, envelope.extras[CameraVideoContract.EXTRA_EXPIRES_AT_MS])
    }

    @Test fun remoteValidationRejectsUnsafeCredentialsAndSessions() {
        val now = 1_000L
        assertEquals("wss://video.example/live", CameraRemoteValidation.secureUrl("wss://video.example/live"))
        assertEquals("https://video.example/upload", CameraRemoteValidation.secureUrl("https://video.example/upload"))
        for (bad in listOf(
            "ws://video.example/live", "http://video.example/live",
            "wss://user@video.example/live", "wss://video.example/live#secret", "wss:///missing-host",
        )) assertFalse(runCatching { CameraRemoteValidation.secureUrl(bad) }.isSuccess)

        assertFalse(runCatching { CameraRemoteValidation.token("x".repeat(31)) }.isSuccess)
        assertFalse(runCatching { CameraRemoteValidation.token("x".repeat(513)) }.isSuccess)
        assertEquals("x".repeat(32), CameraRemoteValidation.token("x".repeat(32)))
        assertFalse(runCatching { CameraRemoteValidation.expiry(now, now) }.isSuccess)
        assertFalse(runCatching { CameraRemoteValidation.expiry(now + 30 * 60_000L + 1, now) }.isSuccess)
        assertEquals(now + 30 * 60_000L, CameraRemoteValidation.expiry(now + 30 * 60_000L, now))
        assertEquals("session-1", CameraRemoteValidation.id("session-1", "sessionId"))
        assertFalse(runCatching { CameraRemoteValidation.id("bad session", "sessionId") }.isSuccess)
    }

    @Test fun videoCommandLogCannotAcceptOrExposePayload() {
        val message = CameraCommandLog.received("video_live_start")
        assertEquals("Comando recebido: video_live_start", message)
        assertFalse(message.contains("token"))
    }
}
