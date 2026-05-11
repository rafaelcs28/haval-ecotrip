package br.com.redesurftank.ecotrip.managers

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.util.Log
import androidx.core.content.ContextCompat
import kotlinx.coroutines.*
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

// ── Amostra de telemetria por segundo ─────────────────────────────────────────
data class TelemetrySample(
    val t:    Int,     // segundos desde o início do auto-trip
    val lat:  Double,  // latitude  (0.0 quando GPS indisponível)
    val lng:  Double,  // longitude
    val spd:  Float,   // velocidade do veículo em km/h
    val rpm:  Int,     // rotação do motor ICE (0 = modo 100% elétrico)
    val evKw: Float,   // potência elétrica em kW (+ consumindo, − regenerando)
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
    @Volatile var latestSpeedKmh:       Float = 0f
    @Volatile var latestEngineRpm:      Int   = 0
    @Volatile var latestBatteryCurrentA: Float = 0f  // A (positivo = descarregando, negativo = carregando)
    @Volatile var latestBatteryVoltageV: Float = 0f  // V

    // ── Gravação ──────────────────────────────────────────────────────────────
    private val samples  = mutableListOf<TelemetrySample>()
    private var startMs  = 0L
    @Volatile private var recording = false
    private var sampleJob: Job? = null
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    fun startRecording(startMs: Long) {
        if (recording) return
        recording    = true
        this.startMs = startMs
        synchronized(samples) { samples.clear() }
        Log.i(TAG, "Gravação de telemetria iniciada")

        sampleJob = scope.launch {
            while (isActive && recording) {
                val offsetSec = ((System.currentTimeMillis() - this@TelemetryRecorder.startMs) / 1_000L).toInt()
                val evKw = if (latestBatteryVoltageV > 0f)
                    latestBatteryCurrentA * latestBatteryVoltageV / 1_000f else 0f

                synchronized(samples) {
                    samples.add(TelemetrySample(
                        t    = offsetSec,
                        lat  = latestLat,
                        lng  = latestLng,
                        spd  = latestSpeedKmh,
                        rpm  = latestEngineRpm,
                        evKw = evKw,
                    ))
                }
                delay(1_000L)
            }
        }
    }

    /** Para a gravação e retorna as amostras coletadas. */
    fun stopRecording(): List<TelemetrySample> {
        recording = false
        sampleJob?.cancel()
        sampleJob = null
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
                    })
                }
                // Monta payload manualmente para evitar double-encoding do autoTripJson
                val payload = """{"tripId":"$tripId","autoTrip":$autoTripJson,"samples":$arr}"""

                val url  = URL("$bridgeUrl/api/autotrips")
                val conn = url.openConnection() as HttpURLConnection
                conn.apply {
                    requestMethod = "POST"
                    setRequestProperty("Content-Type", "application/json; charset=utf-8")
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
}
