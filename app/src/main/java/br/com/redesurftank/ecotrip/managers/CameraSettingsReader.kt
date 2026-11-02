package br.com.redesurftank.ecotrip.managers

import android.content.Context
import android.net.Uri
import android.os.Bundle
import org.json.JSONObject
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

object CameraSettingsReader {
    data class ConfirmedSettings(
        val revision: Long,
        val applied: Boolean,
        val snapshot: Map<String, Any>,
    )

    private const val TAG = "CameraSettings"
    private val executor = Executors.newSingleThreadScheduledExecutor { runnable ->
        Thread(runnable, "camera-settings").apply { isDaemon = true }
    }
    private var poll: ScheduledFuture<*>? = null
    @Volatile private var appContext: Context? = null
    @Volatile private var lastPublished: String? = null
    @Volatile private var automaticRecording = false
    @Volatile private var remoteLive = false

    private val booleanKeys = setOf(
        "automaticRecording", "recordParkedLive", "remoteLive", "remoteDownloads",
        "automaticDeletion", "overlayMaster", "overlayDateTime", "overlaySpeed",
        "overlayAcceleration", "overlayDriveState", "overlayDecelerationRegen",
    )
    private val allowedKeys = booleanKeys + setOf("quality", "reserveGb", "overlayPosition")

    fun start(context: Context) {
        if (appContext != null) return
        appContext = context.applicationContext
        executor.execute { publishConfirmed("startup") }
        poll = executor.scheduleWithFixedDelay(
            { publishConfirmed("poll") }, 60, 60, TimeUnit.SECONDS,
        )
    }

    fun stop() {
        appContext = null
        poll?.cancel(false)
        poll = null
        lastPublished = null
        automaticRecording = false
        remoteLive = false
    }

    internal fun contextOrNull(): Context? = appContext
    internal fun automaticRecordingEnabled(): Boolean = automaticRecording
    internal fun remoteLiveEnabled(): Boolean = remoteLive

    fun handleRemoteCommand(command: String, payload: String): JSONObject {
        val context = appContext ?: return error("leitor indisponível")
        return try {
            when (command) {
                "video_settings_get" -> confirmedJson(query(context))
                "video_settings_update" -> {
                    val request = JSONObject(payload)
                    val requestId = request.getString("requestId")
                    require(requestId.matches(Regex("[^\\n]{1,128}"))) { "requestId inválido" }
                    val expectedRevision = request.getLong("expectedRevision")
                    require(expectedRevision >= 0) { "expectedRevision inválida" }
                    val patch = validatePatch(request.getJSONObject("patch").toTypedMap())
                    val extras = Bundle().apply {
                        putLong(CameraVideoContract.EXTRA_EXPECTED_SETTINGS_REVISION, expectedRevision)
                        putString(CameraVideoContract.EXTRA_REQUEST_ID, requestId)
                        putBundle(CameraVideoContract.EXTRA_SETTINGS_PATCH, patch.toBundle())
                    }
                    val update = context.contentResolver.call(
                        Uri.parse("content://${CameraVideoContract.AUTHORITY}"),
                        "updateSettings", null, extras,
                    ) ?: throw IllegalStateException("provider não respondeu")
                    // O provider é a autoridade. Sempre releia; nunca trate o pedido como estado confirmado.
                    val confirmed = query(context).copy(applied = update.getBoolean("applied", false))
                    confirmedJson(confirmed).put("requestId", requestId)
                }
                else -> error("comando de configuração desconhecido")
            }.also {
                MqttManager.getInstance().publicarCameraSettings(it.toString())
                lastPublished = it.toString()
            }
        } catch (failure: Exception) {
            TripVideoBridge.noteUnavailable("configurações: ${failure.message}")
            error(failure.message ?: failure.javaClass.simpleName)
        }
    }

    fun validatePatch(patch: Map<String, Any>): Map<String, Any> {
        require(patch.isNotEmpty() && patch.size <= 16) { "patch vazio ou grande demais" }
        val result = linkedMapOf<String, Any>()
        for ((key, value) in patch) {
            require(key in allowedKeys) { "configuração desconhecida: $key" }
            result[key] = when {
                key in booleanKeys -> value.also { require(it is Boolean) { "$key exige boolean" } }
                key == "quality" -> value.toString().also {
                    require(value is String && it in setOf("economy", "standard", "high")) { "quality inválida" }
                }
                key == "reserveGb" -> (value as? Number)?.let { number ->
                    val integer = number.toInt()
                    require(number.toDouble() == integer.toDouble() && integer in setOf(5, 10, 20)) {
                        "reserveGb inválido"
                    }
                    integer
                } ?: throw IllegalArgumentException("reserveGb inválido")
                key == "overlayPosition" -> value.toString().also {
                    require(value is String && it in setOf(
                        "top_left", "top_right", "bottom_left", "bottom_right",
                    )) { "overlayPosition inválida" }
                }
                else -> throw IllegalArgumentException("configuração desconhecida")
            }
        }
        return result
    }

    private fun publishConfirmed(origin: String): JSONObject {
        val context = appContext ?: return error("leitor indisponível")
        return try {
            val json = confirmedJson(query(context))
            MqttManager.getInstance().publicarCameraSettings(json.toString())
            if (json.toString() != lastPublished) AppLogger.i(TAG, "configurações confirmadas ($origin)")
            lastPublished = json.toString()
            TripVideoBridge.noteAvailable()
            json
        } catch (failure: Exception) {
            TripVideoBridge.noteUnavailable("configurações: ${failure.message}")
            error(failure.message ?: failure.javaClass.simpleName)
        }
    }

    private fun query(context: Context): ConfirmedSettings {
        val result = context.contentResolver.call(
            Uri.parse("content://${CameraVideoContract.AUTHORITY}"),
            "getSettings", null, null,
        ) ?: throw IllegalStateException("provider não respondeu")
        val revision = result.getLong(CameraVideoContract.EXTRA_SETTINGS_REVISION, -1)
        require(revision >= 0) { "revision ausente" }
        val snapshot = result.getBundle(CameraVideoContract.EXTRA_SETTINGS_SNAPSHOT)
            ?: throw IllegalStateException("snapshot ausente")
        val typed = snapshot.toTypedMap()
        automaticRecording = typed["automaticRecording"] == true
        remoteLive = typed["remoteLive"] == true
        return ConfirmedSettings(revision, result.getBoolean("applied", true), typed)
    }

    private fun confirmedJson(value: ConfirmedSettings): JSONObject = JSONObject()
        .put("ok", true)
        .put("revision", value.revision)
        .put("applied", value.applied)
        .put("conflict", !value.applied)
        .put("settings", JSONObject(value.snapshot))

    private fun Bundle.toTypedMap(): Map<String, Any> {
        val result = linkedMapOf<String, Any>()
        for (key in keySet()) {
            when (val value = get(key)) {
                is Boolean, is Int, is Long, is Double, is Float, is String -> result[key] = value
                null -> Unit
                else -> throw IllegalArgumentException("tipo não suportado em $key")
            }
        }
        return result
    }

    private fun JSONObject.toTypedMap(): Map<String, Any> {
        val result = linkedMapOf<String, Any>()
        val names = keys()
        while (names.hasNext()) {
            val key = names.next()
            val value = get(key)
            result[key] = when (value) {
                is Boolean, is Int, is Long, is Double, is String -> value
                else -> throw IllegalArgumentException("tipo não suportado em $key")
            }
        }
        return result
    }

    private fun Map<String, Any>.toBundle(): Bundle = Bundle().also { bundle ->
        for ((key, value) in this) when (value) {
            is Boolean -> bundle.putBoolean(key, value)
            is Int -> bundle.putInt(key, value)
            is Long -> bundle.putLong(key, value)
            is Double -> bundle.putDouble(key, value)
            is String -> bundle.putString(key, value)
            else -> throw IllegalArgumentException("tipo não suportado em $key")
        }
    }

    private fun error(message: String): JSONObject = JSONObject().put("ok", false).put("erro", message)
}
