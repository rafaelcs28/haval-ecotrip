package br.com.redesurftank.ecotrip.managers

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.util.Log
import androidx.core.content.ContextCompat
import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import kotlinx.coroutines.*
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

// ── Renomear trip — tarefa pendente recebida do bridge ────────────────────────
data class RenameTask(
    val id:     String,   // UUID gerado pelo bridge (usado no ACK)
    val tripId: String,   // startMs (auto) ou timestampMs (manual) como String
    val type:   String,   // "auto" | "manual"
    val name:   String,   // novo nome desejado
)

// ── Amostra de telemetria por segundo ─────────────────────────────────────────
data class TelemetrySample(
    val t:    Int,     // segundos desde o início do auto-trip
    val lat:  Double,  // latitude  (0.0 quando GPS indisponível)
    val lng:  Double,  // longitude
    val spd:  Float,   // velocidade do veículo em km/h
    val rpm:  Int,     // rotação do motor ICE (0 = modo 100% elétrico)
    val evKw: Float,   // potência elétrica em kW (+ consumindo, − regenerando)
    val pwr:  Int = 0, // % potência bateria: −100=regen máx, +100=consumo máx
)

class TelemetryRecorder(private val context: Context) {

    companion object {
        private const val TAG = "TelemetryRecorder"
    }

    // ── GPS ───────────────────────────────────────────────────────────────────
    private val locationManager =
        context.getSystemService(Context.LOCATION_SERVICE) as LocationManager

    @Volatile var latestLat: Double = 0.0
    @Volatile var latestLng: Double = 0.0
    @Volatile var gpsActive: Boolean = false

    private val locationListener = LocationListener { loc: Location ->
        latestLat = loc.latitude
        latestLng = loc.longitude
    }

    /** Inicia atualizações de localização (chamado de TripManager.startGps()). */
    fun startGps() {
        if (gpsActive) return
        val hasFine = ContextCompat.checkSelfPermission(
            context, Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED
        val hasCoarse = ContextCompat.checkSelfPermission(
            context, Manifest.permission.ACCESS_COARSE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED

        if (!hasFine && !hasCoarse) {
            Log.w(TAG, "Permissão de localização não concedida — GPS desativado")
            return
        }
        try {
            if (hasFine && locationManager.isProviderEnabled(LocationManager.GPS_PROVIDER)) {
                locationManager.requestLocationUpdates(
                    LocationManager.GPS_PROVIDER, 1_000L, 1f, locationListener
                )
            }
            if (locationManager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)) {
                locationManager.requestLocationUpdates(
                    LocationManager.NETWORK_PROVIDER, 1_000L, 1f, locationListener
                )
            }
            gpsActive = true
            Log.i(TAG, "GPS iniciado")
        } catch (e: SecurityException) {
            Log.w(TAG, "GPS — SecurityException: ${e.message}")
        } catch (e: Exception) {
            Log.w(TAG, "GPS — erro ao iniciar: ${e.message}")
        }
    }

    fun stopGps() {
        try { locationManager.removeUpdates(locationListener) } catch (_: Exception) {}
        gpsActive = false
    }

    // ── Valores dos sensores (atualizados por TripManager.onDataChanged) ──────
    @Volatile var latestSpeedKmh:        Float = 0f
    @Volatile var latestEngineRpm:       Int   = 0
    /** kW do motor elétrico — exclusivamente car.ev_info.Instant_energy_consumption. */
    @Volatile var latestMotorPowerKw:    Float = 0f
    /** % da potência da bateria (−100=regen máx, +100=consumo máx). */
    @Volatile var latestBattPowerPct:    Int   = 0

    // ── Gravação ──────────────────────────────────────────────────────────────
    private val samples   = mutableListOf<TelemetrySample>()
    private var startMs   = 0L
    @Volatile private var recording = false
    private var sampleJob: Job? = null
    private val scope    = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val gson     = Gson()
    /** Arquivo de flush em andamento — nulo quando não está gravando. */
    private var flushFile: java.io.File? = null

    /**
     * Inicia (ou retoma após reinício) a gravação de telemetria.
     *
     * @param startMs          Timestamp de início do auto-trip (original, não do reinício).
     * @param preloadedSamples Amostras já salvas em disco antes do reinício do app; serão
     *                         pré-populadas na lista antes de continuar a gravar.
     * @param flushFile        Arquivo onde as amostras serão gravadas a cada 60 s para
     *                         sobreviver a reinícios do app. Null = sem persistência.
     */
    fun startRecording(
        startMs: Long,
        preloadedSamples: List<TelemetrySample> = emptyList(),
        flushFile: java.io.File? = null,
    ) {
        if (recording) return
        recording       = true
        this.startMs    = startMs
        this.flushFile  = flushFile
        synchronized(samples) {
            samples.clear()
            if (preloadedSamples.isNotEmpty()) samples.addAll(preloadedSamples)
        }
        val extra = if (preloadedSamples.isNotEmpty()) " (${preloadedSamples.size} amostras recuperadas do disco)" else ""
        Log.i(TAG, "Gravação de telemetria iniciada$extra")

        sampleJob = scope.launch {
            // Tick de 500 ms — permite capturar variações sem esperar 1 s inteiro.
            // Amostra é gravada quando velocidade varia ≥ 1 km/h, potência ≥ 0,2 kW,
            // ou passaram ≥ 5 s sem nenhuma amostra (garante continuidade do GPS).
            var ticksSinceFlush  = 0  // flush a cada 60 ticks × 500 ms = 30 s
            var ticksSinceRecord = 0  // força registro a cada 10 ticks × 500 ms = 5 s
            var lastSpd  = Float.NaN
            var lastEvKw = Float.NaN
            var lastPwr  = Int.MIN_VALUE

            while (isActive && recording) {
                val spd  = latestSpeedKmh
                val pwr  = latestBattPowerPct
                val evKw = latestMotorPowerKw  // car.ev_info.Instant_energy_consumption

                val speedChanged = lastSpd.isNaN()        || kotlin.math.abs(spd  - lastSpd)  >= 1f
                val powerChanged = lastEvKw.isNaN()       || kotlin.math.abs(evKw - lastEvKw) >= 0.2f
                val pwrChanged   = lastPwr == Int.MIN_VALUE || kotlin.math.abs(pwr  - lastPwr)  >= 2
                val timeForced   = ++ticksSinceRecord >= 10  // máx 5 s sem amostra

                if (speedChanged || powerChanged || pwrChanged || timeForced) {
                    val offsetSec = ((System.currentTimeMillis() - this@TelemetryRecorder.startMs) / 1_000L).toInt()
                    synchronized(samples) {
                        samples.add(TelemetrySample(
                            t    = offsetSec,
                            lat  = latestLat,
                            lng  = latestLng,
                            spd  = spd,
                            rpm  = latestEngineRpm,
                            evKw = evKw,
                            pwr  = pwr,
                        ))
                    }
                    lastSpd  = spd
                    lastEvKw = evKw
                    lastPwr  = pwr
                    ticksSinceRecord = 0
                }

                // Flush para disco a cada 30 s — garante recuperação após reinício do app
                if (++ticksSinceFlush >= 60) {
                    ticksSinceFlush = 0
                    flushFile?.let { f ->
                        val snapshot = synchronized(samples) { samples.toList() }
                        try { f.writeText(gson.toJson(snapshot)) } catch (_: Exception) {}
                    }
                }
                delay(500L)
            }
        }
    }

    /** Para a gravação e retorna as amostras coletadas (inclui amostras pré-carregadas). */
    fun stopRecording(): List<TelemetrySample> {
        recording = false
        sampleJob?.cancel()
        sampleJob  = null
        flushFile  = null
        return synchronized(samples) {
            val result = samples.toList()
            Log.i(TAG, "Gravação encerrada: ${result.size} amostras")
            result
        }
    }

    /**
     * Envia todas as viagens armazenadas para o bridge sem amostras de telemetria.
     * Usado para sincronizar viagens existentes que não foram enviadas anteriormente
     * (ex.: bridge estava offline quando a viagem foi salva).
     * Fire-and-forget; o bridge aceita re-envios e sobrescreve de forma idempotente.
     *
     * @param bridgeUrl URL base do bridge, ex. "http://192.168.1.100:3000"
     * @param trips lista de pares (tripId, autoTripJson) — já serializados pelo caller
     */
    fun bulkPostTrips(
        bridgeUrl:      String,
        bridgeToken:    String = "",
        trips:          List<Pair<String, String>>,
        onAllDone:      (ok: Int, fail: Int) -> Unit = { _, _ -> },
        samplesProvider:(tripId: String) -> String = { "[]" },
        onTripSynced:   (String) -> Unit = {},
    ) {
        if (bridgeUrl.isBlank() || trips.isEmpty()) { onAllDone(0, 0); return }
        scope.launch {
            var ok = 0
            var fail = 0
            for ((tripId, autoTripJson) in trips) {
                try {
                    val samplesJson = samplesProvider(tripId)
                    val payload = """{"tripId":"$tripId","autoTrip":$autoTripJson,"samples":$samplesJson}"""
                    val url  = URL("$bridgeUrl/api/autotrips")
                    val conn = url.openConnection() as HttpURLConnection
                    conn.apply {
                        requestMethod = "POST"
                        setRequestProperty("Content-Type", "application/json; charset=utf-8")
                        if (bridgeToken.isNotBlank()) setRequestProperty("Authorization", "Bearer $bridgeToken")
                        doOutput       = true
                        connectTimeout = 8_000
                        readTimeout    = 8_000
                    }
                    conn.outputStream.use { it.write(payload.toByteArray(Charsets.UTF_8)) }
                    val code = conn.responseCode
                    conn.disconnect()
                    if (code in 200..299) {
                        ok++
                        onTripSynced(tripId)
                    } else {
                        Log.w(TAG, "bulkPost trip $tripId → HTTP $code")
                        fail++
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "bulkPost trip $tripId falhou: ${e.message}")
                    fail++
                }
                delay(80L)
            }
            Log.i(TAG, "bulkPostTrips: $ok OK, $fail falhas (total ${trips.size})")
            android.os.Handler(android.os.Looper.getMainLooper()).post { onAllDone(ok, fail) }
        }
    }

    /**
     * Envia telemetria + resumo do auto-trip para o bridge via HTTP POST.
     * Fire-and-forget: falhas são logadas mas não travam o caller.
     */
    fun postTelemetry(
        bridgeUrl:    String,
        bridgeToken:  String = "",
        tripId:       String,
        autoTripJson: String,
        samples:      List<TelemetrySample>,
        onSuccess:    () -> Unit = {},
    ) {
        if (bridgeUrl.isBlank()) {
            Log.w(TAG, "Bridge URL não configurado — telemetria não enviada")
            return
        }
        scope.launch {
            try {
                val arr = JSONArray()
                for (s in samples) {
                    arr.put(JSONObject().apply {
                        put("t",    s.t)
                        put("lat",  s.lat)
                        put("lng",  s.lng)
                        put("spd",  s.spd.toDouble())
                        put("rpm",  s.rpm)
                        put("evKw", s.evKw.toDouble())
                        put("pwr",  s.pwr)
                    })
                }
                // Monta payload manualmente para evitar double-encoding do autoTripJson
                val payload = """{"tripId":"$tripId","autoTrip":$autoTripJson,"samples":$arr}"""

                val url  = URL("$bridgeUrl/api/autotrips")
                val conn = url.openConnection() as HttpURLConnection
                conn.apply {
                    requestMethod = "POST"
                    setRequestProperty("Content-Type", "application/json; charset=utf-8")
                    if (bridgeToken.isNotBlank()) setRequestProperty("Authorization", "Bearer $bridgeToken")
                    doOutput      = true
                    connectTimeout = 15_000
                    readTimeout    = 15_000
                }
                conn.outputStream.use { it.write(payload.toByteArray(Charsets.UTF_8)) }
                val code = conn.responseCode
                if (code in 200..299) {
                    Log.i(TAG, "Telemetria enviada: tripId=$tripId (${samples.size} amostras)")
                    onSuccess()
                } else {
                    Log.w(TAG, "Erro HTTP $code ao enviar telemetria")
                }
                conn.disconnect()
            } catch (e: Exception) {
                Log.e(TAG, "Falha ao enviar telemetria: ${e.message}")
            }
        }
    }

    /**
     * Busca tarefas de renomeação pendentes no bridge e entrega via callback na Main thread.
     * Fire-and-forget — falhas são apenas logadas.
     */
    fun fetchPendingRenames(
        bridgeUrl:   String,
        bridgeToken: String = "",
        onResult:    (List<RenameTask>) -> Unit,
    ) {
        if (bridgeUrl.isBlank()) return
        scope.launch {
            try {
                val url  = URL("$bridgeUrl/api/pending-renames")
                val conn = url.openConnection() as HttpURLConnection
                conn.apply {
                    requestMethod = "GET"
                    if (bridgeToken.isNotBlank()) setRequestProperty("Authorization", "Bearer $bridgeToken")
                    connectTimeout = 8_000
                    readTimeout    = 8_000
                }
                val code = conn.responseCode
                val body = conn.inputStream.use { it.readBytes().toString(Charsets.UTF_8) }
                conn.disconnect()
                if (code !in 200..299) {
                    Log.w(TAG, "fetchPendingRenames: HTTP $code")
                    return@launch
                }
                val arr   = JSONArray(body)
                val tasks = mutableListOf<RenameTask>()
                for (i in 0 until arr.length()) {
                    val obj = arr.getJSONObject(i)
                    tasks.add(RenameTask(
                        id     = obj.optString("id"),
                        tripId = obj.optString("tripId"),
                        type   = obj.optString("type"),
                        name   = obj.optString("name"),
                    ))
                }
                Log.i(TAG, "fetchPendingRenames: ${tasks.size} tarefa(s) recebida(s)")
                android.os.Handler(android.os.Looper.getMainLooper()).post { onResult(tasks) }
            } catch (e: Exception) {
                Log.w(TAG, "fetchPendingRenames falhou: ${e.message}")
            }
        }
    }

    /**
     * Confirma para o bridge que os renames foram aplicados localmente.
     * O bridge remove as entradas da fila para não reenviar.
     */
    fun ackRenames(
        bridgeUrl:   String,
        bridgeToken: String = "",
        ids:         List<String>,
    ) {
        if (bridgeUrl.isBlank() || ids.isEmpty()) return
        scope.launch {
            try {
                val payload = JSONObject().put("ids", JSONArray(ids)).toString()
                val url  = URL("$bridgeUrl/api/rename-ack")
                val conn = url.openConnection() as HttpURLConnection
                conn.apply {
                    requestMethod = "POST"
                    setRequestProperty("Content-Type", "application/json; charset=utf-8")
                    if (bridgeToken.isNotBlank()) setRequestProperty("Authorization", "Bearer $bridgeToken")
                    doOutput       = true
                    connectTimeout = 8_000
                    readTimeout    = 8_000
                }
                conn.outputStream.use { it.write(payload.toByteArray(Charsets.UTF_8)) }
                val code = conn.responseCode
                conn.disconnect()
                Log.i(TAG, "ackRenames: HTTP $code (${ids.size} ID(s))")
            } catch (e: Exception) {
                Log.w(TAG, "ackRenames falhou: ${e.message}")
            }
        }
    }
}
