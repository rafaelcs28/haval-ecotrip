package br.com.redesurftank.ecotrip.managers

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max

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
        enum class Status { APPLIED, NO_OP, STALE, REJECTED, ERROR, UNAVAILABLE }
        companion object {
            fun applied() = CommandResult(Status.APPLIED)
            fun noOp() = CommandResult(Status.NO_OP)
            fun stale(cameraRevision: Long) = CommandResult(Status.STALE, cameraRevision)
            fun rejected() = CommandResult(Status.REJECTED)
            fun error() = CommandResult(Status.ERROR)
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

    @Synchronized
    fun startLanLive(sessionId: String, port: Int, producerToken: String, expiresAtMs: Long): Boolean {
        require(sessionId.matches(Regex("[A-Za-z0-9_-]{1,128}")))
        require(port in 1..65535 && port != 80)
        require(producerToken.matches(Regex("[A-Za-z0-9_-]{32,512}")))
        CameraRemoteValidation.expiry(expiresAtMs, wallClockMs())
        return send(Action.START_LIVE, state.lastTripId,
            sessionUrl = "ws://127.0.0.1:$port/ws/video/lan/car?session=$sessionId",
            sessionId = sessionId, producerToken = producerToken, expiresAtMs = expiresAtMs)
    }

    @Synchronized
    fun stopLanLive(sessionId: String): Boolean {
        require(sessionId.matches(Regex("[A-Za-z0-9_-]{1,128}")))
        return send(Action.STOP_LIVE, state.lastTripId, sessionId = sessionId)
    }

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
                CommandResult.Status.APPLIED, CommandResult.Status.NO_OP ->
                    return state.save(newLastTripId, revision)
                CommandResult.Status.UNAVAILABLE, CommandResult.Status.REJECTED,
                CommandResult.Status.ERROR -> return false
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
            val envelope = CameraCommandCodec.encode(command)
            val extras = Bundle().apply {
                for ((key, value) in envelope.extras) when (value) {
                    is Int -> putInt(key, value)
                    is Long -> putLong(key, value)
                    is String -> putString(key, value)
                    is List<*> -> putStringArrayList(key, ArrayList(value.filterIsInstance<String>()))
                    else -> throw IllegalArgumentException("extra não suportado: $key")
                }
            }
            val result = context.contentResolver.call(
                Uri.parse("content://${CameraVideoContract.AUTHORITY}"),
                "command", envelope.action, extras,
            ) ?: return CommandResult.unavailable()
            return when (result.getString(CameraVideoContract.EXTRA_COMMAND_STATUS)) {
                CameraVideoContract.STATUS_APPLIED -> CommandResult.applied()
                CameraVideoContract.STATUS_NO_OP -> CommandResult.noOp()
                CameraVideoContract.STATUS_STALE -> CommandResult.stale(
                    result.getLong(CameraVideoContract.EXTRA_CAMERA_REVISION, -1),
                )
                CameraVideoContract.STATUS_REJECTED -> CommandResult.rejected()
                CameraVideoContract.STATUS_ERROR -> CommandResult.error()
                else -> CommandResult.unavailable()
            }
        }
    }

    companion object {
        private const val TAG = "TripVideoBridge"
        private const val POLL_MS = 2_000L
        private val handler by lazy { Handler(Looper.getMainLooper()) }
        private val catalogExecutor = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "camera-catalog").apply { isDaemon = true }
        }
        private val reconcileExecutor = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "camera-reconcile").apply { isDaemon = true }
        }
        private val reconcileInFlight = AtomicBoolean(false)
        @Volatile private var catalogRevisionStore: CameraCatalogRevisionStore? = null
        @Volatile private var runtime: TripVideoBridge? = null
        @Volatile private var running = false
        @Volatile private var remoteLive = false
        @Volatile private var remoteLiveExpiresAtMs = 0L
        @Volatile private var unavailableLogged = false
        private var lastObservedActive: Long? = null
        private var catalogPolls = 0

        private val poll = object : Runnable {
            override fun run() {
                if (!running) return
                scheduleReconcile(startup = false)
                handler.postDelayed(this, POLL_MS)
            }
        }

        fun start(context: Context) {
            if (running) return
            val app = context.applicationContext
            runtime = TripVideoBridge(PreferencesState(app), AndroidSink(app))
            running = true
            scheduleReconcile(startup = true)
            handler.postDelayed(poll, POLL_MS)
            CameraSettingsReader.start(app)
            requestCatalogPublish(app)
        }

        fun stop() {
            running = false
            handler.removeCallbacks(poll)
            runtime = null
            remoteLive = false
            remoteLiveExpiresAtMs = 0L
            lastObservedActive = null
            catalogPolls = 0
            CameraSettingsReader.stop()
        }

        fun isRecordingOrLiveActive(): Boolean =
            (runtime?.state?.lastTripId != null && CameraSettingsReader.automaticRecordingEnabled()) ||
                (remoteLive && System.currentTimeMillis() < remoteLiveExpiresAtMs &&
                    CameraSettingsReader.remoteLiveEnabled()) ||
                LocalApiServer.current?.isCameraLanLiveActive() == true

        fun startLanSession(id: String, port: Int, token: String, expiry: Long): Boolean {
            return runtime?.startLanLive(id, port, token, expiry) == true
        }

        fun stopLanSession(id: String) {
            runtime?.stopLanLive(id)
        }

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
                val requestId = CameraRemoteValidation.id(json.optString("requestId"), "requestId")
                val cameraCommand = when (command) {
                    "video_live_start" -> {
                        val url = CameraRemoteValidation.secureUrl(json.getString("sessionUrl"))
                        val token = CameraRemoteValidation.token(json.getString("producerToken"))
                        val expires = CameraRemoteValidation.expiry(json.getLong("expiresAt"), now)
                        CameraCommand(
                            Action.START_LIVE, 0, requestId,
                            sessionUrl = url, producerToken = token, expiresAtMs = expires,
                        )
                    }
                    "video_live_stop" -> CameraCommand(
                        Action.STOP_LIVE, 0, requestId,
                        sessionId = CameraRemoteValidation.id(json.getString("sessionId"), "sessionId"),
                    )
                    "video_transfer" -> {
                        val tripId = json.getString("tripId").toLongOrNull()
                            ?: throw IllegalArgumentException("tripId inválido")
                        require(tripId > 0) { "tripId inválido" }
                        val segments = json.getJSONArray("segmentIds").toStringList()
                        require(segments.isNotEmpty() && segments.size <= 256) { "segmentIds inválidos" }
                        segments.forEach { CameraRemoteValidation.id(it, "segmentId") }
                        CameraCommand(
                            Action.TRANSFER, 0, requestId, tripId = tripId,
                            segmentIds = segments,
                            viewerSession = CameraRemoteValidation.id(json.getString("viewerSession"), "viewerSession"),
                        )
                    }
                    "video_transfer_cancel" -> CameraCommand(Action.CANCEL_TRANSFER, 0, requestId)
                    else -> throw IllegalArgumentException("comando de vídeo desconhecido")
                }
                val ok = bridge.sendRemote(cameraCommand)
                if (ok) {
                    if (command == "video_live_start") {
                        remoteLive = true
                        remoteLiveExpiresAtMs = cameraCommand.expiresAtMs ?: 0L
                    }
                    if (command == "video_live_stop") {
                        remoteLive = false
                        remoteLiveExpiresAtMs = 0L
                    }
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
                    val segmentMetadata = column("segment_metadata_json")
                    while (cursor.moveToNext()) {
                        val canonical = canonicalCatalogTrip(linkedMapOf(
                            "tripId" to cursor.getLong(id).toString(),
                            "source" to cursor.getString(source),
                            "startMs" to cursor.getLong(start),
                            "endMs" to cursor.getLong(end),
                            "byteSize" to cursor.getLong(bytes),
                            "segments" to cursor.getLong(segments),
                            "segmentMetadataJson" to cursor.getString(segmentMetadata),
                            "completed" to true,
                        )) ?: continue
                        trips.put(JSONObject(canonical))
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

        @JvmStatic fun canonicalCatalogTrip(raw: Map<String, Any>): Map<String, Any>? =
            CameraLanDownloads.canonicalCatalogTrip(raw)

        fun requestCatalogPublish(context: Context) {
            val app = context.applicationContext
            catalogExecutor.execute { publishCatalog(app) }
        }

        private fun scheduleReconcile(startup: Boolean) {
            if (!running || !reconcileInFlight.compareAndSet(false, true)) return
            reconcileExecutor.execute {
                try {
                    if (running) reconcileRuntime(startup)
                } finally {
                    reconcileInFlight.set(false)
                }
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
                    catalogPolls++
                    if (lastObservedActive != active || catalogPolls >= 30) {
                        CameraSettingsReader.contextOrNull()?.let(::requestCatalogPublish)
                        catalogPolls = 0
                    }
                    lastObservedActive = active
                } else {
                    noteUnavailable("reconciliação; viagens e telemetria seguem normais")
                }
            } catch (failure: Exception) {
                noteUnavailable("reconciliação: ${failure.message}")
            }
        }

        @Synchronized
        private fun catalogRevision(context: Context, body: String): Long {
            val store = catalogRevisionStore ?: run {
                val preferences = context.getSharedPreferences("camera-video-bridge", Context.MODE_PRIVATE)
                CameraCatalogRevisionStore(object : CameraCatalogRevisionStore.Backend {
                    override val body: String? get() = preferences.getString("catalogBody", null)
                    override val revision: Long get() = preferences.getLong("catalogRevision", 0L)
                    override fun save(body: String, revision: Long): Boolean = preferences.edit()
                        .putString("catalogBody", body)
                        .putLong("catalogRevision", revision)
                        .commit()
                }).also { catalogRevisionStore = it }
            }
            return store.revisionFor(body)
        }

        internal fun noteUnavailable(detail: String?) {
            if (unavailableLogged) return
            unavailableLogged = true
            AppLogger.w(TAG, "Haval Camera indisponível${detail?.let { ": $it" } ?: ""}")
        }

        internal fun noteAvailable() {
            unavailableLogged = false
        }

        private fun JSONArray.toStringList(): List<String> =
            (0 until length()).map { getString(it) }

        private fun error(message: String): JSONObject = JSONObject().put("ok", false).put("erro", message)
    }
}

class CameraCatalogChangedReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == CameraVideoContract.CATALOG_CHANGED) {
            TripVideoBridge.requestCatalogPublish(context.applicationContext)
        }
    }
}

class CameraCommandResultReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != CameraVideoContract.ACTION_COMMAND_RESULT ||
            intent.getIntExtra(CameraVideoContract.EXTRA_PROTOCOL_VERSION, -1) !=
            CameraVideoContract.PROTOCOL_VERSION) return
        val requestId = intent.getStringExtra(CameraVideoContract.EXTRA_REQUEST_ID) ?: return
        val requestRevision = intent.getLongExtra(CameraVideoContract.EXTRA_STATE_REVISION, -1)
        val cameraRevision = intent.getLongExtra(CameraVideoContract.EXTRA_CAMERA_REVISION, -1)
        val status = intent.getStringExtra(CameraVideoContract.EXTRA_COMMAND_STATUS) ?: return
        if (requestRevision < 0) return
        CameraAcknowledgements.broker.complete(
            CameraCommandAcknowledgement(requestId, requestRevision, cameraRevision, status),
        )
    }
}
