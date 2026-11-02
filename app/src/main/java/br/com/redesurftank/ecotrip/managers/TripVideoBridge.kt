package br.com.redesurftank.ecotrip.managers

import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID
import kotlin.math.max

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
}

class TripVideoBridge(
    private val state: StateStore,
    private val sink: CameraCommandSink,
    private val wallClockMs: () -> Long = System::currentTimeMillis,
) {
    enum class Action {
        START_TRIP, STOP_TRIP, DISCARD_TRIP, RECONCILE,
        START_LIVE, STOP_LIVE, TRANSFER, CANCEL_TRANSFER,
    }

    data class CameraCommand(
        val action: Action,
        val revision: Long,
        val requestId: String,
        val tripId: Long? = null,
        val startMs: Long? = null,
        val endMs: Long? = null,
        val sessionUrl: String? = null,
        val sessionId: String? = null,
        val producerToken: String? = null,
        val expiresAtMs: Long? = null,
        val segmentIds: List<String> = emptyList(),
        val viewerSession: String? = null,
    )

    data class CommandResult(val status: Status, val cameraRevision: Long = -1) {
        enum class Status { APPLIED, STALE, UNAVAILABLE }
        companion object {
            fun applied() = CommandResult(Status.APPLIED)
            fun stale(cameraRevision: Long) = CommandResult(Status.STALE, cameraRevision)
            fun unavailable() = CommandResult(Status.UNAVAILABLE)
        }
    }

    interface StateStore {
        val lastTripId: Long?
        val revision: Long
        fun save(lastTripId: Long?, revision: Long): Boolean
    }

    fun interface CameraCommandSink {
        fun send(command: CameraCommand): CommandResult
    }

    @Synchronized
    fun reconcileStartup(activeTripId: Long?): Boolean = send(
        Action.RECONCILE,
        newLastTripId = activeTripId,
        tripId = activeTripId,
        startMs = activeTripId,
    )

    @Synchronized
    fun reconcile(activeTripId: Long?, completedEndMs: Map<Long, Long>): Boolean {
        val previous = state.lastTripId
        if (previous == activeTripId) return true
        if (previous != null) {
            val endMs = completedEndMs[previous]
            val stopped = if (endMs != null) {
                send(Action.STOP_TRIP, null, previous, endMs = endMs)
            } else {
                send(Action.DISCARD_TRIP, null, previous)
            }
            if (!stopped) return false
        }
        return activeTripId == null || send(
            Action.START_TRIP,
            newLastTripId = activeTripId,
            tripId = activeTripId,
            startMs = activeTripId,
        )
    }

    @Synchronized
    fun sendRemote(command: CameraCommand): Boolean = send(
        action = command.action,
        newLastTripId = state.lastTripId,
        tripId = command.tripId,
        startMs = command.startMs,
        endMs = command.endMs,
        sessionUrl = command.sessionUrl,
        sessionId = command.sessionId,
        producerToken = command.producerToken,
        expiresAtMs = command.expiresAtMs,
        segmentIds = command.segmentIds,
        viewerSession = command.viewerSession,
        suppliedRequestId = command.requestId,
    )

    private fun send(
        action: Action,
        newLastTripId: Long?,
        tripId: Long? = null,
        startMs: Long? = null,
        endMs: Long? = null,
        sessionUrl: String? = null,
        sessionId: String? = null,
        producerToken: String? = null,
        expiresAtMs: Long? = null,
        segmentIds: List<String> = emptyList(),
        viewerSession: String? = null,
        suppliedRequestId: String? = null,
    ): Boolean {
        // Epoch milliseconds keep revisions ahead after an EcoTrip reinstall while
        // max() preserves monotonicity if the head-unit clock moves backwards.
        var revision = max(state.revision + 1, wallClockMs())
        repeat(2) {
            val requestId = suppliedRequestId
                ?: "ecotrip-$revision-${action.name.lowercase()}-${wallClockMs()}-${UUID.randomUUID()}"
            val command = CameraCommand(
                action, revision, requestId, tripId, startMs, endMs, sessionUrl, sessionId,
                producerToken, expiresAtMs, segmentIds, viewerSession,
            )
            val result = runCatching { sink.send(command) }.getOrElse { CommandResult.unavailable() }
            when (result.status) {
                CommandResult.Status.APPLIED -> return state.save(newLastTripId, revision)
                CommandResult.Status.UNAVAILABLE -> return false
                CommandResult.Status.STALE -> {
                    if (result.cameraRevision < 0) return false
                    val observed = max(revision, result.cameraRevision)
                    if (!state.save(state.lastTripId, observed)) return false
                    revision = observed + 1
                }
            }
        }
        return false
    }

    private class PreferencesState(context: Context) : StateStore {
        private val prefs = context.getSharedPreferences("camera-video-bridge", Context.MODE_PRIVATE)
        override val lastTripId: Long?
            get() = prefs.getLong("lastTripId", -1L).takeIf { it >= 0 }
        override val revision: Long get() = prefs.getLong("revision", 0L)
        override fun save(lastTripId: Long?, revision: Long): Boolean {
            val editor = prefs.edit().putLong("revision", revision)
            if (lastTripId == null) editor.remove("lastTripId") else editor.putLong("lastTripId", lastTripId)
            return editor.commit()
        }
    }

    private class AndroidSink(private val context: Context) : CameraCommandSink {
        override fun send(command: CameraCommand): CommandResult {
            context.packageManager.getPackageInfo(CameraVideoContract.PACKAGE, 0)
            val intent = Intent(actionName(command.action)).apply {
                component = ComponentName(CameraVideoContract.PACKAGE, CameraVideoContract.SERVICE)
                putExtra(CameraVideoContract.EXTRA_PROTOCOL_VERSION, CameraVideoContract.PROTOCOL_VERSION)
                putExtra(CameraVideoContract.EXTRA_REQUEST_ID, command.requestId)
                putExtra(CameraVideoContract.EXTRA_STATE_REVISION, command.revision)
                command.tripId?.let { putExtra(CameraVideoContract.EXTRA_TRIP_ID, it.toString()) }
                command.startMs?.let { putExtra(CameraVideoContract.EXTRA_START_MS, it) }
                command.endMs?.let { putExtra(CameraVideoContract.EXTRA_END_MS, it) }
                command.sessionUrl?.let { putExtra(CameraVideoContract.EXTRA_SESSION_URL, it) }
                command.sessionId?.let { putExtra(CameraVideoContract.EXTRA_SESSION_ID, it) }
                command.producerToken?.let { putExtra(CameraVideoContract.EXTRA_PRODUCER_TOKEN, it) }
                command.expiresAtMs?.let { putExtra(CameraVideoContract.EXTRA_EXPIRES_AT_MS, it) }
                if (command.segmentIds.isNotEmpty()) {
                    putStringArrayListExtra(CameraVideoContract.EXTRA_SEGMENT_IDS, ArrayList(command.segmentIds))
                }
                command.viewerSession?.let { putExtra(CameraVideoContract.EXTRA_VIEWER_SESSION, it) }
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(intent)
            else context.startService(intent)
            return CommandResult.applied()
        }

        private fun actionName(action: Action): String = when (action) {
            Action.START_TRIP -> CameraVideoContract.ACTION_START_TRIP
            Action.STOP_TRIP -> CameraVideoContract.ACTION_STOP_TRIP
            Action.DISCARD_TRIP -> CameraVideoContract.ACTION_DISCARD_TRIP
            Action.RECONCILE -> CameraVideoContract.ACTION_RECONCILE
            Action.START_LIVE -> CameraVideoContract.ACTION_START_LIVE
            Action.STOP_LIVE -> CameraVideoContract.ACTION_STOP_LIVE
            Action.TRANSFER -> CameraVideoContract.ACTION_TRANSFER
            Action.CANCEL_TRANSFER -> CameraVideoContract.ACTION_CANCEL_TRANSFER
        }
    }

    companion object {
        private const val TAG = "TripVideoBridge"
        private const val POLL_MS = 2_000L
        private val handler = Handler(Looper.getMainLooper())
        @Volatile private var runtime: TripVideoBridge? = null
        @Volatile private var running = false
        @Volatile private var remoteLive = false
        @Volatile private var unavailableLogged = false
        private var lastObservedActive: Long? = null

        private val poll = object : Runnable {
            override fun run() {
                if (!running) return
                reconcileRuntime(startup = false)
                handler.postDelayed(this, POLL_MS)
            }
        }

        fun start(context: Context) {
            if (running) return
            val app = context.applicationContext
            runtime = TripVideoBridge(PreferencesState(app), AndroidSink(app))
            running = true
            reconcileRuntime(startup = true)
            handler.postDelayed(poll, POLL_MS)
            CameraSettingsReader.start(app)
            publishCatalog(app)
        }

        fun stop() {
            running = false
            handler.removeCallbacks(poll)
            runtime = null
            remoteLive = false
            lastObservedActive = null
            CameraSettingsReader.stop()
        }

        fun isRecordingOrLiveActive(): Boolean =
            (runtime?.state?.lastTripId != null && CameraSettingsReader.automaticRecordingEnabled()) ||
                (remoteLive && CameraSettingsReader.remoteLiveEnabled())

        fun handleRemoteCommand(command: String, payload: String): JSONObject {
            if (command == "video_catalog") {
                val context = CameraSettingsReader.contextOrNull()
                    ?: return error("ponte indisponível")
                return publishCatalog(context)
            }
            if (command == "video_settings_get" || command == "video_settings_update") {
                return CameraSettingsReader.handleRemoteCommand(command, payload)
            }
            val bridge = runtime ?: return error("ponte indisponível")
            return runCatching {
                val json = JSONObject(payload.ifBlank { "{}" })
                val now = System.currentTimeMillis()
                val requestId = requiredId(json.optString("requestId"), "requestId")
                val cameraCommand = when (command) {
                    "video_live_start" -> {
                        val url = requiredSecureUrl(json.getString("sessionUrl"))
                        val token = json.getString("producerToken").also {
                            require(it.length in 32..512) { "producerToken inválido" }
                        }
                        val expires = json.getLong("expiresAt")
                        require(expires > now && expires - now <= 30 * 60_000L) { "expiração inválida" }
                        CameraCommand(
                            Action.START_LIVE, 0, requestId,
                            sessionUrl = url, producerToken = token, expiresAtMs = expires,
                        )
                    }
                    "video_live_stop" -> CameraCommand(
                        Action.STOP_LIVE, 0, requestId,
                        sessionId = requiredId(json.getString("sessionId"), "sessionId"),
                    )
                    "video_transfer" -> {
                        val tripId = json.getString("tripId").toLongOrNull()
                            ?: throw IllegalArgumentException("tripId inválido")
                        require(tripId > 0) { "tripId inválido" }
                        val segments = json.getJSONArray("segmentIds").toStringList()
                        require(segments.isNotEmpty() && segments.size <= 256) { "segmentIds inválidos" }
                        segments.forEach { requiredId(it, "segmentId") }
                        CameraCommand(
                            Action.TRANSFER, 0, requestId, tripId = tripId,
                            segmentIds = segments,
                            viewerSession = requiredId(json.getString("viewerSession"), "viewerSession"),
                        )
                    }
                    "video_transfer_cancel" -> CameraCommand(Action.CANCEL_TRANSFER, 0, requestId)
                    else -> throw IllegalArgumentException("comando de vídeo desconhecido")
                }
                val ok = bridge.sendRemote(cameraCommand)
                if (ok) {
                    if (command == "video_live_start") remoteLive = true
                    if (command == "video_live_stop") remoteLive = false
                    JSONObject().put("ok", true).put("requestId", requestId)
                } else error("Haval Camera indisponível")
            }.getOrElse { error(it.message ?: it.javaClass.simpleName) }
        }

        fun publishCatalog(context: Context): JSONObject {
            val result = JSONObject().put("ok", false)
            return try {
                val trips = JSONArray()
                context.contentResolver.query(
                    Uri.parse("content://${CameraVideoContract.AUTHORITY}/trips"),
                    null, null, null, null,
                )?.use { cursor ->
                    fun column(name: String) = cursor.getColumnIndexOrThrow(name)
                    val id = column("trip_id")
                    val source = column("source")
                    val start = column("start_ms")
                    val end = column("end_ms")
                    val bytes = column("byte_size")
                    val segments = column("segments")
                    while (cursor.moveToNext()) {
                        trips.put(JSONObject()
                            .put("tripId", cursor.getLong(id).toString())
                            .put("source", cursor.getString(source))
                            .put("startMs", cursor.getLong(start))
                            .put("endMs", cursor.getLong(end))
                            .put("byteSize", cursor.getLong(bytes))
                            .put("segments", cursor.getInt(segments)))
                    }
                } ?: throw IllegalStateException("provider ausente")
                val revision = catalogRevision(context, trips.toString())
                result.put("ok", true)
                    .put("catalogRevision", revision)
                    .put("updatedAt", System.currentTimeMillis())
                    .put("trips", trips)
                MqttManager.getInstance().publicarVideoCatalogo(result.toString())
                noteAvailable()
                result
            } catch (failure: Exception) {
                noteUnavailable("catálogo: ${failure.message}")
                result.put("erro", failure.message ?: failure.javaClass.simpleName)
            }
        }

        private fun reconcileRuntime(startup: Boolean) {
            val bridge = runtime ?: return
            try {
                val trips = TripManager.getInstance()
                val active = trips.getActiveAutoTripStartMs()
                val completed = trips.getAutoTripHistory().associate { it.startMs to it.endMs }
                val ok = if (startup) {
                    val transitionOk = if (bridge.state.lastTripId != null && bridge.state.lastTripId != active) {
                        bridge.reconcile(active, completed)
                    } else true
                    transitionOk && bridge.reconcileStartup(active)
                } else bridge.reconcile(active, completed)
                if (ok) {
                    noteAvailable()
                    if (lastObservedActive != active) publishCatalog(CameraSettingsReader.contextOrNull() ?: return)
                    lastObservedActive = active
                } else {
                    noteUnavailable("reconciliação; viagens e telemetria seguem normais")
                }
            } catch (failure: Exception) {
                noteUnavailable("reconciliação: ${failure.message}")
            }
        }

        private fun catalogRevision(context: Context, body: String): Long {
            val preferences = context.getSharedPreferences("camera-video-bridge", Context.MODE_PRIVATE)
            val old = preferences.getString("catalogBody", null)
            val revision = preferences.getLong("catalogRevision", 0L) + if (old == body) 0 else 1
            if (old != body) preferences.edit()
                .putString("catalogBody", body)
                .putLong("catalogRevision", revision)
                .commit()
            return revision
        }

        internal fun noteUnavailable(detail: String?) {
            if (unavailableLogged) return
            unavailableLogged = true
            AppLogger.w(TAG, "Haval Camera indisponível${detail?.let { ": $it" } ?: ""}")
        }

        internal fun noteAvailable() {
            unavailableLogged = false
        }

        private fun requiredId(value: String, name: String): String {
            require(value.matches(Regex("[A-Za-z0-9._:-]{1,128}"))) { "$name inválido" }
            return value
        }

        private fun requiredSecureUrl(value: String): String {
            val uri = Uri.parse(value)
            require(uri.scheme in setOf("https", "wss") && !uri.host.isNullOrBlank()) { "URL segura inválida" }
            require(uri.userInfo == null && uri.fragment == null) { "URL segura inválida" }
            return value
        }

        private fun JSONArray.toStringList(): List<String> =
            (0 until length()).map { getString(it) }

        private fun error(message: String): JSONObject = JSONObject().put("ok", false).put("erro", message)
    }
}

class CameraCatalogChangedReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == CameraVideoContract.CATALOG_CHANGED) {
            TripVideoBridge.publishCatalog(context.applicationContext)
        }
    }
}
