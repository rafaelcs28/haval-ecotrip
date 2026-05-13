package br.com.redesurftank.ecotrip.managers

import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import br.com.redesurftank.ecotrip.BuildConfig
import br.com.redesurftank.ecotrip.models.SharedPreferencesKeys
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class BackupManager private constructor() {

    companion object {
        @Volatile private var instance: BackupManager? = null
        fun getInstance() = instance ?: synchronized(this) {
            instance ?: BackupManager().also { instance = it }
        }
        const val BACKUP_FORMAT_VERSION = 1
        const val BACKUP_FILENAME = "ecotrip-backup.json"
    }

    private lateinit var prefs: SharedPreferences
    private lateinit var appContext: Context

    fun init(context: Context) {
        appContext = context.applicationContext
        val ctx = try { context.createDeviceProtectedStorageContext() } catch (_: Exception) { context }
        prefs = ctx.getSharedPreferences(SharedPreferencesKeys.PREFS_NAME, Context.MODE_PRIVATE)
    }

    /** URL base do Home Assistant para export direto (ex: "http://192.168.1.10:8123"). */
    var haExportUrl: String
        get() = prefs.getString(SharedPreferencesKeys.HA_EXPORT_URL, "") ?: ""
        set(v) { prefs.edit().putString(SharedPreferencesKeys.HA_EXPORT_URL, v.trim()).apply() }

    /** Exports all app data to JSON. Returns (file, absolutePath). */
    fun exportBackup(): Pair<File, String> {
        val json = buildBackupJson()
        val dir = appContext.getExternalFilesDir(null) ?: appContext.filesDir
        dir.mkdirs()
        val file = File(dir, BACKUP_FILENAME)
        file.writeText(json)
        return Pair(file, file.absolutePath)
    }

    /** Imports backup from a content URI (SAF file picker). Returns backup timestamp string. */
    fun importBackupFromUri(uri: Uri): String {
        val json = appContext.contentResolver.openInputStream(uri)?.bufferedReader()?.readText()
            ?: throw Exception("Não foi possível ler o arquivo selecionado")
        return applyBackupJson(json)
    }

    /**
     * POSTs o backup JSON direto para o webhook do HA.
     * O HA deve ter uma automação no webhook_id="ecotrip_backup" que salva o arquivo.
     * Retorna o timestamp do backup enviado.
     */
    fun exportToHomeAssistant(haBaseUrl: String): String {
        val json = buildBackupJson()
        val ts   = org.json.JSONObject(json).optString("timestamp", "desconhecido")
        val url  = URL("${haBaseUrl.trimEnd('/')}/api/webhook/ecotrip_backup")
        val conn = url.openConnection() as HttpURLConnection
        conn.requestMethod = "POST"
        conn.setRequestProperty("Content-Type", "application/json; charset=utf-8")
        conn.setRequestProperty("User-Agent", "EcotripImpulse/${BuildConfig.VERSION_NAME}")
        conn.connectTimeout = 15_000
        conn.readTimeout    = 15_000
        conn.doOutput       = true
        conn.outputStream.use { it.write(json.toByteArray(Charsets.UTF_8)) }
        val code = conn.responseCode
        if (code !in 200..299) throw Exception("HA retornou HTTP $code")
        return ts
    }

    /** Downloads and imports backup from a URL. Returns backup timestamp string. */
    fun importBackupFromUrl(url: String): String {
        val conn = URL(url.trim()).openConnection() as HttpURLConnection
        conn.connectTimeout = 15_000
        conn.readTimeout    = 30_000
        conn.setRequestProperty("User-Agent", "EcotripImpulse/${BuildConfig.VERSION_NAME}")
        val json = conn.inputStream.bufferedReader().readText()
        return applyBackupJson(json)
    }

    // ── Private ──────────────────────────────────────────────────────────────

    private fun buildBackupJson(): String {
        val ts = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.getDefault()).format(Date())
        val j = JSONObject()
        j.put("backup_format_version", BACKUP_FORMAT_VERSION)
        j.put("app_version", BuildConfig.VERSION_NAME)
        j.put("timestamp", ts)

        // Settings
        j.put(SharedPreferencesKeys.TANK_CAPACITY_L,      prefs.getFloat(SharedPreferencesKeys.TANK_CAPACITY_L, 51f).toDouble())
        j.put(SharedPreferencesKeys.PRICE_GASOLINE_PER_L, prefs.getFloat(SharedPreferencesKeys.PRICE_GASOLINE_PER_L, 6.0f).toDouble())
        j.put(SharedPreferencesKeys.PRICE_ENERGY_PER_KWH, prefs.getFloat(SharedPreferencesKeys.PRICE_ENERGY_PER_KWH, 0.9f).toDouble())
        j.put(SharedPreferencesKeys.MAX_HISTORY_ENTRIES,  prefs.getInt(SharedPreferencesKeys.MAX_HISTORY_ENTRIES, 50))

        // MQTT
        j.put(SharedPreferencesKeys.MQTT_ENABLED,  prefs.getBoolean(SharedPreferencesKeys.MQTT_ENABLED, false))
        j.put(SharedPreferencesKeys.MQTT_HOST,     prefs.getString(SharedPreferencesKeys.MQTT_HOST,     "") ?: "")
        j.put(SharedPreferencesKeys.MQTT_PORT,     prefs.getInt(SharedPreferencesKeys.MQTT_PORT,        1883))
        j.put(SharedPreferencesKeys.MQTT_USERNAME, prefs.getString(SharedPreferencesKeys.MQTT_USERNAME, "") ?: "")
        j.put(SharedPreferencesKeys.MQTT_PASSWORD, prefs.getString(SharedPreferencesKeys.MQTT_PASSWORD, "") ?: "")
        j.put(SharedPreferencesKeys.MQTT_PREFIX,   prefs.getString(SharedPreferencesKeys.MQTT_PREFIX,   "haval/ecotrip") ?: "haval/ecotrip")
        j.put(SharedPreferencesKeys.MQTT_PUBLISH_INTERVAL_WIFI_MS,     prefs.getInt(SharedPreferencesKeys.MQTT_PUBLISH_INTERVAL_WIFI_MS,     5_000))
        j.put(SharedPreferencesKeys.MQTT_PUBLISH_INTERVAL_CELLULAR_MS, prefs.getInt(SharedPreferencesKeys.MQTT_PUBLISH_INTERVAL_CELLULAR_MS, 30_000))

        // Lifetime
        j.put(SharedPreferencesKeys.LIFETIME_FUEL_L,      prefs.getFloat(SharedPreferencesKeys.LIFETIME_FUEL_L,      0f).toDouble())
        j.put(SharedPreferencesKeys.LIFETIME_ENERGY_KWH,  prefs.getFloat(SharedPreferencesKeys.LIFETIME_ENERGY_KWH,  0f).toDouble())
        j.put(SharedPreferencesKeys.LIFETIME_REGEN_KWH,   prefs.getFloat(SharedPreferencesKeys.LIFETIME_REGEN_KWH,   0f).toDouble())
        j.put(SharedPreferencesKeys.LIFETIME_DISTANCE_KM, prefs.getFloat(SharedPreferencesKeys.LIFETIME_DISTANCE_KM, 0f).toDouble())
        j.put(SharedPreferencesKeys.LIFETIME_TIME_SEC,    prefs.getLong(SharedPreferencesKeys.LIFETIME_TIME_SEC,     0L))
        j.put(SharedPreferencesKeys.LIFETIME_CHARGE_KWH,  prefs.getFloat(SharedPreferencesKeys.LIFETIME_CHARGE_KWH,  0f).toDouble())
        j.put(SharedPreferencesKeys.LIFETIME_CHARGE_SEC,  prefs.getLong(SharedPreferencesKeys.LIFETIME_CHARGE_SEC,   0L))

        // Rolling
        j.put(SharedPreferencesKeys.ROLLING_FUEL_L,        prefs.getFloat(SharedPreferencesKeys.ROLLING_FUEL_L,        0f).toDouble())
        j.put(SharedPreferencesKeys.ROLLING_ENERGY_KWH,    prefs.getFloat(SharedPreferencesKeys.ROLLING_ENERGY_KWH,    0f).toDouble())
        j.put(SharedPreferencesKeys.ROLLING_REGEN_KWH,     prefs.getFloat(SharedPreferencesKeys.ROLLING_REGEN_KWH,     0f).toDouble())
        j.put(SharedPreferencesKeys.ROLLING_DISTANCE_KM,   prefs.getFloat(SharedPreferencesKeys.ROLLING_DISTANCE_KM,   0f).toDouble())
        j.put(SharedPreferencesKeys.ROLLING_SHUTDOWN_MS,   prefs.getLong(SharedPreferencesKeys.ROLLING_SHUTDOWN_MS,    0L))
        j.put(SharedPreferencesKeys.ROLLING_START_SOC_PCT, prefs.getFloat(SharedPreferencesKeys.ROLLING_START_SOC_PCT, 0f).toDouble())
        j.put(SharedPreferencesKeys.ROLLING_START_TANK_L,  prefs.getFloat(SharedPreferencesKeys.ROLLING_START_TANK_L,  0f).toDouble())

        // Latest sensor readings
        j.put(SharedPreferencesKeys.LATEST_FUEL_PCT,     prefs.getFloat(SharedPreferencesKeys.LATEST_FUEL_PCT,     0f).toDouble())
        j.put(SharedPreferencesKeys.LATEST_SOC_PCT,      prefs.getFloat(SharedPreferencesKeys.LATEST_SOC_PCT,      0f).toDouble())
        j.put(SharedPreferencesKeys.LATEST_OUTSIDE_TEMP, prefs.getFloat(SharedPreferencesKeys.LATEST_OUTSIDE_TEMP, 0f).toDouble())
        j.put(SharedPreferencesKeys.LATEST_INSIDE_TEMP,  prefs.getFloat(SharedPreferencesKeys.LATEST_INSIDE_TEMP,  0f).toDouble())

        // History JSON blobs
        prefs.getString(SharedPreferencesKeys.TRIP_HISTORY_JSON,      null)?.let { j.put(SharedPreferencesKeys.TRIP_HISTORY_JSON,      it) }
        prefs.getString(SharedPreferencesKeys.CHARGE_HISTORY_JSON,    null)?.let { j.put(SharedPreferencesKeys.CHARGE_HISTORY_JSON,    it) }

        return j.toString(2)
    }

    private fun applyBackupJson(jsonStr: String): String {
        val j = JSONObject(jsonStr)
        val version = j.optInt("backup_format_version", 1)
        if (version > BACKUP_FORMAT_VERSION)
            throw Exception("Versão do backup ($version) não suportada. Atualize o app.")
        val timestamp = j.optString("timestamp", "desconhecido")

        val ed = prefs.edit()
        fun pf(key: String) { if (j.has(key)) ed.putFloat(key,   j.getDouble(key).toFloat()) }
        fun pl(key: String) { if (j.has(key)) ed.putLong(key,    j.getLong(key)) }
        fun pi(key: String) { if (j.has(key)) ed.putInt(key,     j.getInt(key)) }
        fun ps(key: String) { if (j.has(key)) ed.putString(key,  j.getString(key)) }
        fun pb(key: String) { if (j.has(key)) ed.putBoolean(key, j.getBoolean(key)) }

        pf(SharedPreferencesKeys.TANK_CAPACITY_L);      pf(SharedPreferencesKeys.PRICE_GASOLINE_PER_L)
        pf(SharedPreferencesKeys.PRICE_ENERGY_PER_KWH); pi(SharedPreferencesKeys.MAX_HISTORY_ENTRIES)
        pb(SharedPreferencesKeys.MQTT_ENABLED);          ps(SharedPreferencesKeys.MQTT_HOST)
        pi(SharedPreferencesKeys.MQTT_PORT);             ps(SharedPreferencesKeys.MQTT_USERNAME)
        ps(SharedPreferencesKeys.MQTT_PASSWORD);         ps(SharedPreferencesKeys.MQTT_PREFIX)
        pi(SharedPreferencesKeys.MQTT_PUBLISH_INTERVAL_WIFI_MS)
        pi(SharedPreferencesKeys.MQTT_PUBLISH_INTERVAL_CELLULAR_MS)
        pf(SharedPreferencesKeys.LIFETIME_FUEL_L);      pf(SharedPreferencesKeys.LIFETIME_ENERGY_KWH)
        pf(SharedPreferencesKeys.LIFETIME_REGEN_KWH);   pf(SharedPreferencesKeys.LIFETIME_DISTANCE_KM)
        pl(SharedPreferencesKeys.LIFETIME_TIME_SEC);     pf(SharedPreferencesKeys.LIFETIME_CHARGE_KWH)
        pl(SharedPreferencesKeys.LIFETIME_CHARGE_SEC)
        pf(SharedPreferencesKeys.ROLLING_FUEL_L);       pf(SharedPreferencesKeys.ROLLING_ENERGY_KWH)
        pf(SharedPreferencesKeys.ROLLING_REGEN_KWH);    pf(SharedPreferencesKeys.ROLLING_DISTANCE_KM)
        pl(SharedPreferencesKeys.ROLLING_SHUTDOWN_MS);  pf(SharedPreferencesKeys.ROLLING_START_SOC_PCT)
        pf(SharedPreferencesKeys.ROLLING_START_TANK_L)
        pf(SharedPreferencesKeys.LATEST_FUEL_PCT);      pf(SharedPreferencesKeys.LATEST_SOC_PCT)
        pf(SharedPreferencesKeys.LATEST_OUTSIDE_TEMP);  pf(SharedPreferencesKeys.LATEST_INSIDE_TEMP)
        ps(SharedPreferencesKeys.TRIP_HISTORY_JSON);    ps(SharedPreferencesKeys.CHARGE_HISTORY_JSON)
        ed.putBoolean(SharedPreferencesKeys.SESSION_ENDED_CLEANLY, true)
        ed.commit()

        return timestamp
    }
}
