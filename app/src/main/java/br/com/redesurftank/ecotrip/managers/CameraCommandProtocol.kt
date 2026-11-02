package br.com.redesurftank.ecotrip.managers

import java.net.URI
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

internal object CameraVideoContract {
    const val PACKAGE = "br.com.redesurftank.havalcamera"
    const val SERVICE = "$PACKAGE.TripVideoService"
    const val AUTHORITY = "$PACKAGE.video"
    const val CONTROL_PERMISSION = "$PACKAGE.permission.CONTROL"
    const val READ_PERMISSION = "$PACKAGE.permission.READ_VIDEO"
    const val CATALOG_CHANGED = "$PACKAGE.action.CATALOG_CHANGED"
    const val PROTOCOL_VERSION = 1

    private const val ACTION_PREFIX = "$PACKAGE.action."
    private const val EXTRA_PREFIX = "$PACKAGE.extra."
    const val ACTION_START_TRIP = "${ACTION_PREFIX}START_TRIP"
    const val ACTION_STOP_TRIP = "${ACTION_PREFIX}STOP_TRIP"
    const val ACTION_DISCARD_TRIP = "${ACTION_PREFIX}DISCARD_TRIP"
    const val ACTION_RECONCILE = "${ACTION_PREFIX}RECONCILE"
    const val ACTION_START_LIVE = "${ACTION_PREFIX}START_LIVE"
    const val ACTION_STOP_LIVE = "${ACTION_PREFIX}STOP_LIVE"
    const val ACTION_TRANSFER = "${ACTION_PREFIX}TRANSFER"
    const val ACTION_CANCEL_TRANSFER = "${ACTION_PREFIX}CANCEL_TRANSFER"
    const val ACTION_TELEMETRY_SAMPLE = "${ACTION_PREFIX}TELEMETRY_SAMPLE"
    const val ACTION_COMMAND_RESULT = "${ACTION_PREFIX}COMMAND_RESULT"

    const val EXTRA_PROTOCOL_VERSION = "${EXTRA_PREFIX}PROTOCOL_VERSION"
    const val EXTRA_REQUEST_ID = "${EXTRA_PREFIX}REQUEST_ID"
    const val EXTRA_STATE_REVISION = "${EXTRA_PREFIX}STATE_REVISION"
    const val EXTRA_TRIP_ID = "${EXTRA_PREFIX}TRIP_ID"
    const val EXTRA_START_MS = "${EXTRA_PREFIX}START_MS"
    const val EXTRA_END_MS = "${EXTRA_PREFIX}END_MS"
    const val EXTRA_SESSION_URL = "${EXTRA_PREFIX}SESSION_URL"
    const val EXTRA_SESSION_ID = "${EXTRA_PREFIX}SESSION_ID"
    const val EXTRA_PRODUCER_TOKEN = "${EXTRA_PREFIX}PRODUCER_TOKEN"
    const val EXTRA_EXPIRES_AT_MS = "${EXTRA_PREFIX}EXPIRES_AT_MS"
    const val EXTRA_SEGMENT_IDS = "${EXTRA_PREFIX}SEGMENT_IDS"
    const val EXTRA_VIEWER_SESSION = "${EXTRA_PREFIX}VIEWER_SESSION"
    const val EXTRA_MONOTONIC_MS = "${EXTRA_PREFIX}MONOTONIC_MS"
    const val EXTRA_WALL_CLOCK_MS = "${EXTRA_PREFIX}WALL_CLOCK_MS"
    const val EXTRA_SPEED_KMH = "${EXTRA_PREFIX}SPEED_KMH"
    const val EXTRA_MOTOR_POWER_KW = "${EXTRA_PREFIX}MOTOR_POWER_KW"
    const val EXTRA_VALIDITY_FLAGS = "${EXTRA_PREFIX}VALIDITY_FLAGS"
    const val EXTRA_EXPECTED_SETTINGS_REVISION = "${EXTRA_PREFIX}EXPECTED_SETTINGS_REVISION"
    const val EXTRA_SETTINGS_REVISION = "${EXTRA_PREFIX}SETTINGS_REVISION"
    const val EXTRA_SETTINGS_PATCH = "${EXTRA_PREFIX}SETTINGS_PATCH"
    const val EXTRA_SETTINGS_SNAPSHOT = "${EXTRA_PREFIX}SETTINGS_SNAPSHOT"
    const val EXTRA_COMMAND_STATUS = "${EXTRA_PREFIX}COMMAND_STATUS"
    const val EXTRA_CAMERA_REVISION = "${EXTRA_PREFIX}CAMERA_REVISION"
    const val EXTRA_ERROR_MESSAGE = "${EXTRA_PREFIX}ERROR_MESSAGE"

    const val STATUS_APPLIED = "APPLIED"
    const val STATUS_NO_OP = "NO_OP"
    const val STATUS_STALE = "STALE"
    const val STATUS_REJECTED = "REJECTED"
    const val STATUS_ERROR = "ERROR"
}

internal data class CameraCommandEnvelope(val action: String, val extras: Map<String, Any>)

internal object CameraCommandCodec {
    fun encode(command: TripVideoBridge.CameraCommand): CameraCommandEnvelope {
        val extras = linkedMapOf<String, Any>(
            CameraVideoContract.EXTRA_PROTOCOL_VERSION to CameraVideoContract.PROTOCOL_VERSION,
            CameraVideoContract.EXTRA_REQUEST_ID to command.requestId,
            CameraVideoContract.EXTRA_STATE_REVISION to command.revision,
        )
        command.tripId?.let { extras[CameraVideoContract.EXTRA_TRIP_ID] = it.toString() }
        command.startMs?.let { extras[CameraVideoContract.EXTRA_START_MS] = it }
        command.endMs?.let { extras[CameraVideoContract.EXTRA_END_MS] = it }
        command.sessionUrl?.let { extras[CameraVideoContract.EXTRA_SESSION_URL] = it }
        command.sessionId?.let { extras[CameraVideoContract.EXTRA_SESSION_ID] = it }
        command.producerToken?.let { extras[CameraVideoContract.EXTRA_PRODUCER_TOKEN] = it }
        command.expiresAtMs?.let { extras[CameraVideoContract.EXTRA_EXPIRES_AT_MS] = it }
        if (command.segmentIds.isNotEmpty()) extras[CameraVideoContract.EXTRA_SEGMENT_IDS] = command.segmentIds
        command.viewerSession?.let { extras[CameraVideoContract.EXTRA_VIEWER_SESSION] = it }
        return CameraCommandEnvelope(action(command.action), extras)
    }

    private fun action(action: TripVideoBridge.Action): String = when (action) {
        TripVideoBridge.Action.START_TRIP -> CameraVideoContract.ACTION_START_TRIP
        TripVideoBridge.Action.STOP_TRIP -> CameraVideoContract.ACTION_STOP_TRIP
        TripVideoBridge.Action.DISCARD_TRIP -> CameraVideoContract.ACTION_DISCARD_TRIP
        TripVideoBridge.Action.RECONCILE -> CameraVideoContract.ACTION_RECONCILE
        TripVideoBridge.Action.START_LIVE -> CameraVideoContract.ACTION_START_LIVE
        TripVideoBridge.Action.STOP_LIVE -> CameraVideoContract.ACTION_STOP_LIVE
        TripVideoBridge.Action.TRANSFER -> CameraVideoContract.ACTION_TRANSFER
        TripVideoBridge.Action.CANCEL_TRANSFER -> CameraVideoContract.ACTION_CANCEL_TRANSFER
    }
}

internal object CameraRemoteValidation {
    fun id(value: String, name: String): String {
        require(value.matches(Regex("[A-Za-z0-9._:-]{1,128}"))) { "$name inválido" }
        return value
    }

    fun secureUrl(value: String): String {
        val uri = URI(value)
        require(uri.scheme?.lowercase() in setOf("https", "wss") && !uri.host.isNullOrBlank()) {
            "URL segura inválida"
        }
        require(uri.userInfo == null && uri.fragment == null) { "URL segura inválida" }
        return value
    }

    fun token(value: String): String {
        require(value.length in 32..512) { "producerToken inválido" }
        return value
    }

    fun expiry(value: Long, now: Long): Long {
        require(value > now && value - now <= 30 * 60_000L) { "expiração inválida" }
        return value
    }
}

internal object CameraCommandLog {
    fun received(command: String): String = "Comando recebido: $command"
}

internal data class CameraCommandAcknowledgement(
    val requestId: String,
    val requestRevision: Long,
    val cameraRevision: Long,
    val status: String,
)

internal class CameraAcknowledgementBroker(private val timeoutMs: Long) {
    private data class Key(val requestId: String, val revision: Long)
    private val pending = ConcurrentHashMap<Key, CompletableFuture<CameraCommandAcknowledgement>>()

    fun dispatchAndAwait(
        requestId: String,
        revision: Long,
        dispatch: () -> Unit,
    ): TripVideoBridge.CommandResult {
        val key = Key(requestId, revision)
        val future = CompletableFuture<CameraCommandAcknowledgement>()
        check(pending.putIfAbsent(key, future) == null) { "request já pendente" }
        return try {
            dispatch()
            result(future.get(timeoutMs, TimeUnit.MILLISECONDS))
        } catch (_: Exception) {
            TripVideoBridge.CommandResult.unavailable()
        } finally {
            pending.remove(key, future)
        }
    }

    fun complete(value: CameraCommandAcknowledgement): Boolean =
        pending[Key(value.requestId, value.requestRevision)]?.complete(value) == true

    private fun result(value: CameraCommandAcknowledgement): TripVideoBridge.CommandResult = when (value.status) {
        CameraVideoContract.STATUS_APPLIED -> TripVideoBridge.CommandResult.applied()
        CameraVideoContract.STATUS_NO_OP -> TripVideoBridge.CommandResult.noOp()
        CameraVideoContract.STATUS_STALE -> TripVideoBridge.CommandResult.stale(value.cameraRevision)
        CameraVideoContract.STATUS_REJECTED -> TripVideoBridge.CommandResult.rejected()
        CameraVideoContract.STATUS_ERROR -> TripVideoBridge.CommandResult.error()
        else -> TripVideoBridge.CommandResult.error()
    }
}

internal object CameraAcknowledgements {
    val broker = CameraAcknowledgementBroker(1_500)
}

internal class CameraCatalogRevisionStore(private val backend: Backend) {
    interface Backend {
        val body: String?
        val revision: Long
        fun save(body: String, revision: Long): Boolean
    }

    private var confirmedBody: String? = backend.body
    private var confirmedRevision: Long = backend.revision

    @Synchronized fun revisionFor(body: String): Long {
        if (confirmedBody == body) return confirmedRevision
        val next = Math.addExact(confirmedRevision, 1)
        check(backend.save(body, next)) { "falha ao persistir revisão do catálogo" }
        confirmedBody = body
        confirmedRevision = next
        return next
    }
}
