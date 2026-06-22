package br.com.redesurftank.ecotrip.managers

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.location.Location
import android.os.PowerManager
import br.com.redesurftank.ecotrip.models.SharedPreferencesKeys
import java.util.Timer
import java.util.TimerTask
import kotlin.math.abs
import kotlin.math.sqrt

/**
 * Guarda-estacionamento (antifurto). Arma quando o carro desliga
 * (driving_ready 1→0) e o usuário habilitou; desarma quando o carro liga de
 * novo (0→1) ou por comando.
 *
 * Blindado contra falso positivo reusando a MESMA fonte de GPS do geofence das
 * automações (AutomationManager.checkGeofence): a posição filtrada do
 * TelemetryRecorder via TripManager.getLastGps(), que rejeita acc>500m, só
 * aceita NETWORK com GPS mudo e acc≤150m, prefere GPS e suaviza com EMA. O GPS
 * roda contínuo (MainActivity.startGps(), nunca parado), então o fix segue
 * fresco com o motor desligado.
 *
 * Dois sinais, mas o GPS é o ÁRBITRO — o acelerômetro sozinho NÃO dispara
 * (batida de porta, vento, alguém encostando geravam falso positivo):
 *
 *  - GPS (poll a cada 20s): só confia em fix de PROVIDER gps e fresco. Deriva >
 *    GEO_RADIUS_M do ponto de estacionamento com histerese de borda + N
 *    confirmações consecutivas (igual ao geofence). Com corroboração do
 *    acelerômetro, dispara já na 1ª confirmação; sem ela, exige sustentação.
 *  - Acelerômetro (corrobora): movimento sustentado abaixa a barra do GPS.
 *    Como fallback p/ HU sem lock de GPS (garagem), movimento contínuo forte
 *    por ACCEL_SUSTAIN_MS dispara sozinho — janela longa o bastante pra
 *    descartar batida de porta (<1s).
 *
 * Ao disparar publica security/alarm com lat/lng; o bridge faz push + auto-share.
 * Segura um partial wake lock enquanto armado pra sobreviver ao Doze com motor
 * off — ainda assim, se o HU cortar energia ao dormir, a detecção pode não
 * rodar (a validar no carro real).
 */
object ParkGuard : SensorEventListener {
    private const val TAG = "ParkGuard"

    // GPS (árbitro)
    private const val GEO_RADIUS_M = 75.0       // metros do ponto de estacionamento
    private const val GPS_POLL_MS = 20_000L
    private const val GPS_FRESH_MS = 120_000L   // fix mais velho que isso = não confia
    private const val GPS_CONFIRM_HITS = 3      // polls consecutivos fora (GPS-only)

    // Acelerômetro (corrobora / fallback)
    private const val MOTION_THRESHOLD = 2.5f   // m/s² de desvio da gravidade (subiu p/ filtrar ruído)
    private const val MOTION_HITS_CORROBORATE = 4   // leituras seguidas → marca "houve movimento"
    private const val MOTION_FLAG_TTL_MS = 30_000L  // janela em que o movimento corrobora o GPS
    private const val ACCEL_SUSTAIN_MS = 6_000L     // movimento contínuo → dispara sozinho (sem GPS)
    private const val ACCEL_QUIET_RESET = 6     // amostras quietas seguidas que quebram a continuidade

    private const val COOLDOWN_MS = 60_000L     // não re-dispara antes de 1 min

    @Volatile var enabled = false; private set
    @Volatile var armed = false; private set
    @Volatile var triggered = false; private set

    private var appContext: Context? = null
    @Volatile private var publisher: ((Double, Double, String) -> Unit)? = null
    private var sensorManager: SensorManager? = null
    private var accel: Sensor? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var gpsTimer: Timer? = null

    private var parkLat = 0.0
    private var parkLng = 0.0
    private var gpsOutHits = 0
    @Volatile private var motionRecentMs = 0L
    private var accelHits = 0
    private var accelContinuousStartMs = 0L
    private var quietRun = 0
    private var lastTriggerMs = 0L

    private fun prefs(ctx: Context) =
        ctx.getSharedPreferences(SharedPreferencesKeys.PREFS_NAME, Context.MODE_PRIVATE)

    /** Fiado pelo MqttManager: contexto + como publicar o alarme. */
    fun init(ctx: Context, publish: (lat: Double, lng: Double, reason: String) -> Unit) {
        appContext = ctx.applicationContext
        publisher = publish
        enabled = prefs(ctx).getBoolean(SharedPreferencesKeys.PARK_GUARD_ENABLED, false)
        AppLogger.i(TAG, "init (enabled=$enabled)")
    }

    fun setEnabled(ctx: Context, on: Boolean) {
        enabled = on
        prefs(ctx).edit().putBoolean(SharedPreferencesKeys.PARK_GUARD_ENABLED, on).apply()
        AppLogger.i(TAG, "setEnabled=$on")
        if (!on) disarm()
    }

    /** Chamado pelo TripManager.onDrivingReady: ready=true (0→1) liga o carro. */
    fun onIgnition(ready: Boolean) {
        if (ready) disarm() else if (enabled) arm()
    }

    @Synchronized private fun arm() {
        val ctx = appContext ?: return
        if (armed) return
        triggered = false
        gpsOutHits = 0; accelHits = 0; accelContinuousStartMs = 0L; quietRun = 0; motionRecentMs = 0L
        // Garante GPS rodando (idempotente) e captura o ponto a partir de fix gps fresco.
        TripManager.getInstance().startGps()
        parkLat = 0.0; parkLng = 0.0
        captureBaseline()
        // Acelerômetro (se existir)
        val sm = ctx.getSystemService(Context.SENSOR_SERVICE) as? SensorManager
        sensorManager = sm
        accel = sm?.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
        if (accel != null) sm?.registerListener(this, accel, SensorManager.SENSOR_DELAY_NORMAL)
        // GPS poll
        gpsTimer?.cancel()
        gpsTimer = Timer("parkguard-gps", true).also {
            it.scheduleAtFixedRate(object : TimerTask() {
                override fun run() { checkGpsDrift() }
            }, GPS_POLL_MS, GPS_POLL_MS)
        }
        // Wake lock parcial pra resistir ao Doze
        try {
            val pm = ctx.getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "ecotrip:parkguard").apply {
                setReferenceCounted(false); acquire(12 * 60 * 60 * 1000L)
            }
        } catch (e: Exception) { AppLogger.w(TAG, "wakeLock falhou: ${e.message}") }
        armed = true
        AppLogger.i(TAG, "ARMADO em ($parkLat,$parkLng) accel=${accel != null}")
    }

    @Synchronized private fun disarm() {
        if (!armed && !triggered) return
        try { sensorManager?.unregisterListener(this) } catch (_: Exception) {}
        sensorManager = null; accel = null
        gpsTimer?.cancel(); gpsTimer = null
        try { wakeLock?.let { if (it.isHeld) it.release() } } catch (_: Exception) {}
        wakeLock = null
        armed = false; triggered = false
        gpsOutHits = 0; accelHits = 0; accelContinuousStartMs = 0L; quietRun = 0; motionRecentMs = 0L
        AppLogger.i(TAG, "DESARMADO")
    }

    /** Baseline só de fix gps fresco; senão fica 0,0 e o 1º poll bom resolve. */
    private fun captureBaseline() {
        val tm = TripManager.getInstance()
        if (tm.getLastGpsProvider() != "gps" || tm.getLastGpsAgeMs() > GPS_FRESH_MS) return
        val (la, lo) = tm.getLastGps()
        if (la != 0.0 || lo != 0.0) { parkLat = la; parkLng = lo }
    }

    private fun checkGpsDrift() {
        if (!armed) return
        try {
            val tm = TripManager.getInstance()
            // Só confia em fix de GPS fresco — NETWORK (erro ~km parado) e fix velho
            // são exatamente o que gerava falso positivo. Não mexe nos hits: sem dado
            // bom, mantém o estado atual.
            if (tm.getLastGpsProvider() != "gps" || tm.getLastGpsAgeMs() > GPS_FRESH_MS) return
            val (la, lo) = tm.getLastGps()
            if (la == 0.0 && lo == 0.0) return
            if (parkLat == 0.0 && parkLng == 0.0) { parkLat = la; parkLng = lo; return }
            val d = distMeters(parkLat, parkLng, la, lo)
            if (d <= GEO_RADIUS_M) { gpsOutHits = 0; return }
            gpsOutHits++
            val corroborated = System.currentTimeMillis() - motionRecentMs < MOTION_FLAG_TTL_MS
            if (corroborated) trigger(la, lo, "gps+accel_${d.toInt()}m")
            else if (gpsOutHits >= GPS_CONFIRM_HITS) trigger(la, lo, "gps_drift_${d.toInt()}m")
        } catch (e: Exception) { AppLogger.w(TAG, "checkGps falhou: ${e.message}") }
    }

    override fun onSensorChanged(e: SensorEvent) {
        if (!armed || e.sensor.type != Sensor.TYPE_ACCELEROMETER) return
        val mag = sqrt(e.values[0] * e.values[0] + e.values[1] * e.values[1] + e.values[2] * e.values[2])
        val moving = abs(mag - SensorManager.GRAVITY_EARTH) > MOTION_THRESHOLD
        if (moving) {
            quietRun = 0
            val now = System.currentTimeMillis()
            if (accelContinuousStartMs == 0L) accelContinuousStartMs = now
            if (++accelHits >= MOTION_HITS_CORROBORATE) motionRecentMs = now
            // Fallback sem GPS: movimento contínuo longo demais p/ ser batida de porta.
            if (now - accelContinuousStartMs >= ACCEL_SUSTAIN_MS) {
                val (la, lo) = TripManager.getInstance().getLastGps()
                trigger(la, lo, "accel_sustained")
            }
        } else {
            if (accelHits > 0) accelHits--
            // Tolera dips curtos; só quebra a continuidade após uma sequência quieta.
            if (++quietRun >= ACCEL_QUIET_RESET) accelContinuousStartMs = 0L
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}

    @Synchronized private fun trigger(lat: Double, lng: Double, reason: String) {
        val now = System.currentTimeMillis()
        if (now - lastTriggerMs < COOLDOWN_MS) return
        lastTriggerMs = now
        triggered = true
        gpsOutHits = 0; accelHits = 0; accelContinuousStartMs = 0L
        AppLogger.w(TAG, "ALARME ($reason) em ($lat,$lng)")
        try { publisher?.invoke(lat, lng, reason) } catch (e: Exception) { AppLogger.w(TAG, "publish alarme falhou: ${e.message}") }
    }

    private fun distMeters(la1: Double, lo1: Double, la2: Double, lo2: Double): Double {
        val out = FloatArray(1)
        Location.distanceBetween(la1, lo1, la2, lo2, out)
        return out[0].toDouble()
    }
}
