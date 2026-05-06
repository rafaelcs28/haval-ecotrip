package br.com.redesurftank.ecotrip.managers

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import br.com.redesurftank.ecotrip.models.SharedPreferencesKeys
import org.eclipse.paho.client.mqttv3.*
import org.eclipse.paho.client.mqttv3.persist.MemoryPersistence
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

private const val TAG = "MqttManager"
private const val CLIENT_ID = "haval_ecotrip"
private const val DEFAULT_PUBLISH_INTERVAL_S = 20
private const val RECONNECT_DELAY_MS = 15_000L
private const val MAX_QUEUED_SNAPSHOTS = 50   // ~17 min at 20s interval

class MqttManager private constructor() {

    enum class Status { DISCONNECTED, CONNECTING, CONNECTED, ERROR }

    // Pending regular snapshot (only latest matters for HA state)
    private data class QueuedSnapshot(
        val timestampMs: Long,
        val snapA: TripSnapshot,
        val snapB: TripSnapshot,
        val rolling: RollingSnapshot,
    )

    // Trip completed events must never be dropped
    private data class QueuedTripCompleted(
        val tripId: String,
        val snap: TripSnapshot,
        val name: String,
        val timestampMs: Long,
    )

    companion object {
        @Volatile private var instance: MqttManager? = null
        fun getInstance() = instance ?: synchronized(this) {
            instance ?: MqttManager().also { instance = it }
        }
    }

    private lateinit var prefs: SharedPreferences
    private val executor       = Executors.newSingleThreadExecutor()
    private val isReconnecting = AtomicBoolean(false)
    private var client: MqttClient? = null
    private var lastPublishMs  = 0L

    // Queues — accessed from multiple threads, protected by their own locks
    private val snapshotQueue      = ArrayDeque<QueuedSnapshot>()
    private val tripCompletedQueue = ArrayDeque<QueuedTripCompleted>()
    private val snapshotLock       = Any()
    private val tripCompletedLock  = Any()

    var status: Status = Status.DISCONNECTED
        private set
    var onStatusChange: ((Status) -> Unit)? = null

    var lastSuccessfulPublishMs: Long = 0L
        private set

    var lastErrorMessage: String = ""
        private set

    private var consecutiveFailures = 0
    val hasRepeatedFailures: Boolean get() = consecutiveFailures >= 3

    // Config
    var enabled:          Boolean = false
    var host:             String  = ""
    var port:             Int     = 1883
    var username:         String  = ""
    var password:         String  = ""
    var prefix:           String  = "haval/ecotrip"
    var publishIntervalS: Int     = DEFAULT_PUBLISH_INTERVAL_S

    // Vehicle model (populated from car data keys before connect)
    var vehicleModel1: String = ""
    var vehicleModel2: String = ""

    // Real-time values — updated by ConsumptionScreen on every car data event
    var latestSpeedKmh: Float = 0f
    var latestGear: String = ""
    var latestInsideTemp: Float = 0f
        set(value) { field = value; if (::prefs.isInitialized) prefs.edit().putFloat(SharedPreferencesKeys.LATEST_INSIDE_TEMP, value).apply() }
    var latestOutsideTemp: Float = 0f
        set(value) { field = value; if (::prefs.isInitialized) prefs.edit().putFloat(SharedPreferencesKeys.LATEST_OUTSIDE_TEMP, value).apply() }

    // Electrical measurements — carregamento e bateria de tração
    var latestChargeCurrentA: Float = 0f   // A — corrente AC de carregamento
    var latestBatteryVoltageV: Float = 0f  // V — tensão do pack de bateria
    var latestBatteryCurrentA: Float = 0f  // A — corrente do pack (+ descarga, - carga/regen)

    // Último timestamp em que qualquer dado do carro foi recebido pelo app
    // Usado para saber se o barramento de dados do carro está ativo
    @Volatile var lastCarDataMs: Long = 0L

    // Último valor de limite de carga (em %) publicado no HA.
    // -1 = ainda não publicado nesta sessão.
    // Usado para evitar publicações redundantes e detectar divergência carro ↔ HA.
    @Volatile private var lastPublishedChargeLimitPct: Int = -1

    fun init(context: Context) {
        // Prevent "Error locating the logging class" crash on Android: set a no-op logger
        // before any MqttClient is constructed so Paho never tries Class.forName().
        try {
            org.eclipse.paho.client.mqttv3.logging.LoggerFactory.setLogger(PahoNoOpLogger::class.java.name)
        } catch (_: Exception) {}

        val ctx = try { context.createDeviceProtectedStorageContext() } catch (_: Exception) { context }
        prefs = ctx.getSharedPreferences(SharedPreferencesKeys.PREFS_NAME, Context.MODE_PRIVATE)
        loadConfig()
        if (enabled && host.isNotEmpty()) connect()
    }

    fun saveAndApply() {
        prefs.edit()
            .putBoolean(SharedPreferencesKeys.MQTT_ENABLED,           enabled)
            .putString (SharedPreferencesKeys.MQTT_HOST,              host)
            .putInt    (SharedPreferencesKeys.MQTT_PORT,              port)
            .putString (SharedPreferencesKeys.MQTT_USERNAME,          username)
            .putString (SharedPreferencesKeys.MQTT_PASSWORD,          password)
            .putString (SharedPreferencesKeys.MQTT_PREFIX,            prefix)
            .putInt    (SharedPreferencesKeys.MQTT_PUBLISH_INTERVAL_S, publishIntervalS)
            .apply()

        executor.submit {
            client?.let { safeDisconnect(it) }
            client = null
            if (enabled && host.isNotEmpty()) connectInternal()
            else setStatus(Status.DISCONNECTED)
        }
    }

    fun connect() {
        executor.submit { connectInternal() }
    }

    fun destroy() {
        enabled = false
        executor.submit {
            client?.let { safeDisconnect(it) }
            client = null
            setStatus(Status.DISCONNECTED)
        }
    }

    // ── Public publish API ────────────────────────────────────────────────────

    fun publish(snapA: TripSnapshot, snapB: TripSnapshot, rolling: RollingSnapshot) {
        val now = System.currentTimeMillis()
        if (now - lastPublishMs < publishIntervalS * 1000L) return
        lastPublishMs = now

        val queued = QueuedSnapshot(now, snapA, snapB, rolling)
        val c = client
        if (c == null || !c.isConnected) {
            // Queue for later — keep only last MAX_QUEUED_SNAPSHOTS
            synchronized(snapshotLock) {
                snapshotQueue.addLast(queued)
                while (snapshotQueue.size > MAX_QUEUED_SNAPSHOTS) snapshotQueue.removeFirst()
            }
            Log.d(TAG, "Offline — snapshot queued (queue size=${snapshotQueue.size})")
            return
        }
        executor.submit { publishSnapshotInternal(c, queued) }
    }

    /**
     * Chamado pelo ConsumptionScreen sempre que o carro reporta car.ev_setting.charge_soc_limit_config.
     * Converte o valor do carro (0=100%, 1=50%, 2=60%, 3=70%, 4=80%, 5=90%) para %,
     * compara com o último valor publicado no HA e só atualiza se for diferente.
     * Isso garante que o HA reflita o estado real do carro sem tráfego redundante.
     */
    fun syncChargeLimitFromCar(carVal: Int) {
        val pct = carValToPct(carVal) ?: run {
            Log.w(TAG, "syncChargeLimitFromCar: valor inesperado carVal=$carVal, ignorado")
            return
        }
        if (pct == lastPublishedChargeLimitPct) {
            Log.d(TAG, "Charge limit sem mudança ($pct%) — HA já está atualizado")
            return
        }
        AppLogger.i(TAG, "Carro reportou charge limit: carVal=$carVal → ${pct}% (HA tinha ${lastPublishedChargeLimitPct}%) — atualizando HA")
        publishChargeLimitState(pct)
    }

    /**
     * Publica o valor de limite de carga (em %) no state topic do select do HA.
     * Usado tanto pelo fluxo carro→HA (syncChargeLimitFromCar) quanto pelo fluxo
     * HA→carro após validação (handleIncomingCommand).
     */
    fun publishChargeLimitState(pct: Int) {
        if (pct !in setOf(50, 60, 70, 80, 90, 100)) {
            Log.w(TAG, "publishChargeLimitState: pct=$pct inválido, ignorado")
            return
        }
        try {
            client?.publish("$prefix/ha/charge_limit/state", pct.toString().toByteArray(), 1, true)
            lastPublishedChargeLimitPct = pct
            AppLogger.i(TAG, "Charge limit publicado no HA: ${pct}%")
        } catch (e: Exception) {
            Log.w(TAG, "publishChargeLimitState falhou: ${e.message}")
        }
    }

    /** Converte valor do carro (0–5) para percentual. null se fora do range. */
    private fun carValToPct(carVal: Int): Int? {
        return when (carVal) {
            0 -> 100
            1 -> 50
            2 -> 60
            3 -> 70
            4 -> 80
            5 -> 90
            else -> null
        }
    }

    /** Converte percentual para valor do carro (0–5). null se não mapeado. */
    private fun pctToCarVal(pct: Int): Int? {
        return when (pct) {
            100 -> 0
            50  -> 1
            60  -> 2
            70  -> 3
            80  -> 4
            90  -> 5
            else -> null
        }
    }

    fun publishTripCompleted(tripId: String, snap: TripSnapshot, name: String = "") {
        val queued = QueuedTripCompleted(tripId, snap, name, System.currentTimeMillis())
        val c = client
        if (c == null || !c.isConnected) {
            // Trip completed events are never dropped
            synchronized(tripCompletedLock) { tripCompletedQueue.addLast(queued) }
            Log.i(TAG, "Offline — trip completed queued: $tripId (queue size=${tripCompletedQueue.size})")
            return
        }
        executor.submit { publishTripCompletedInternal(c, queued) }
    }

    // ── Internal ─────────────────────────────────────────────────────────────

    private fun cleanHost(raw: String): String =
        raw.trim()
            .removePrefix("mqtt://")
            .removePrefix("tcp://")
            .removePrefix("ssl://")
            .removePrefix("http://")
            .removePrefix("https://")
            .trimEnd('/')

    private fun connectInternal() {
        try {
            setStatus(Status.CONNECTING)
            val cleanedHost = cleanHost(host)
            val serverUri = "tcp://$cleanedHost:$port"
            Log.i(TAG, "Connecting to $serverUri")
            val c = MqttClient(serverUri, CLIENT_ID + "_${System.currentTimeMillis() % 10000}", MemoryPersistence())

            c.setCallback(object : MqttCallback {
                override fun connectionLost(cause: Throwable?) {
                    Log.w(TAG, "Connection lost: ${cause?.message}")
                    setStatus(Status.DISCONNECTED)
                    scheduleReconnect()
                }
                override fun messageArrived(topic: String, message: MqttMessage) {
                    handleIncomingCommand(topic, message.toString())
                }
                override fun deliveryComplete(token: IMqttDeliveryToken) {}
            })

            val opts = MqttConnectOptions().apply {
                connectionTimeout    = 20   // longer timeout for mobile networks
                keepAliveInterval    = 30
                isCleanSession       = true
                isAutomaticReconnect = false
                if (username.isNotEmpty()) {
                    userName = username
                    password = this@MqttManager.password.toCharArray()
                }
                setWill("$prefix/status", "offline".toByteArray(), 1, true)
            }

            c.connect(opts)
            c.publish("$prefix/status", MqttMessage("online".toByteArray()).apply { qos = 1; isRetained = true })
            c.subscribe("$prefix/cmd/#", 1)
            client = c
            consecutiveFailures = 0
            lastPublishedChargeLimitPct = -1  // força re-sync com o carro após reconexão
            setStatus(Status.CONNECTED)
            publishDiscovery(c)
            drainQueues(c)
            AppLogger.i(TAG, "MQTT conectado: $serverUri")
        } catch (e: Exception) {
            consecutiveFailures++
            lastErrorMessage = e.message?.take(120) ?: "Erro desconhecido"
            AppLogger.e(TAG, "Falha #$consecutiveFailures: $lastErrorMessage")
            setStatus(Status.ERROR)
            scheduleReconnect()
        }
    }

    private fun drainQueues(c: MqttClient) {
        // Trip completed first — most critical
        val completed = synchronized(tripCompletedLock) {
            tripCompletedQueue.toList().also { tripCompletedQueue.clear() }
        }
        if (completed.isNotEmpty()) {
            Log.i(TAG, "Draining ${completed.size} queued trip completed events")
            for (q in completed) publishTripCompletedInternal(c, q)
        }

        // Then regular snapshots
        val snapshots = synchronized(snapshotLock) {
            snapshotQueue.toList().also { snapshotQueue.clear() }
        }
        if (snapshots.isNotEmpty()) {
            Log.i(TAG, "Draining ${snapshots.size} queued snapshots")
            for (q in snapshots) publishSnapshotInternal(c, q)
        }
    }

    private fun publishSnapshotInternal(c: MqttClient, q: QueuedSnapshot) {
        try {
            fun pub(topic: String, value: String) =
                c.publish("$prefix/$topic", value.toByteArray(), 0, false)
            fun fmt2(v: Float) = String.format(java.util.Locale.US, "%.2f", v)
            fun fmt3(v: Float) = String.format(java.util.Locale.US, "%.3f", v)
            fun fmt1(v: Float) = String.format(java.util.Locale.US, "%.1f", v)

            pub("speed_kmh",             fmt1(latestSpeedKmh))
            pub("inside_temp",           fmt1(latestInsideTemp))
            pub("outside_temp",          fmt1(latestOutsideTemp))
            if (latestGear.isNotEmpty()) pub("gear",  latestGear)

            // Electrical: corrente de carga, tensão e corrente do pack + potência derivada
            pub("charge_current_a",  fmt2(latestChargeCurrentA))
            pub("battery_voltage_v", fmt2(latestBatteryVoltageV))
            pub("battery_current_a", fmt2(latestBatteryCurrentA))
            val chargePowerKw = if (latestBatteryVoltageV > 0f)
                latestChargeCurrentA * latestBatteryVoltageV / 1000f else 0f
            pub("charge_power_kw",   fmt2(chargePowerKw))
            pub("rolling/kwh_per_100km", fmt2(q.rolling.netKwhPer100km))
            pub("rolling/km_per_l",      fmt2(q.rolling.kmPerL))
            pub("rolling/distance_km",   fmt2(q.rolling.windowKm))
            pub("rolling/fuel_l",        fmt3(q.rolling.fuelL))

            for ((label, snap) in listOf("trip_a" to q.snapA, "trip_b" to q.snapB)) {
                pub("$label/distance_km",    fmt2(snap.distKm))
                pub("$label/time_sec",        snap.timeSec.toString())
                pub("$label/kwh_per_100km",  fmt2(snap.kwhPer100km))
                pub("$label/km_per_l",       fmt2(snap.kmPerL))
                pub("$label/avg_speed_kmh",  fmt1(snap.avgSpeedKmh))
                pub("$label/fuel_l",         fmt3(snap.fuelL))
                pub("$label/energy_kwh",     fmt3(snap.energyKwh))
                pub("$label/regen_kwh",      fmt3(snap.regenKwh))
                pub("$label/soc_start",   fmt1(snap.startSocPct))
                pub("$label/soc_current", fmt1(snap.currentSocPct))
                pub("$label/tank_start_l",fmt1(snap.startTankL))
                pub("$label/tank_now_l",  fmt1(snap.currentTankL))
            }
            lastSuccessfulPublishMs = System.currentTimeMillis()
            // Publica timestamp ISO para a entidade "Última Atualização" no HA
            val isoNow = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ssZ", Locale.getDefault())
                .format(Date(lastSuccessfulPublishMs))
            c.publish("$prefix/last_update", isoNow.toByteArray(), 1, true)
            onStatusChange?.invoke(status) // trigger UI refresh for last-sent time
        } catch (e: Exception) {
            Log.w(TAG, "publishSnapshot failed: ${e.message}")
        }
    }

    private fun publishTripCompletedInternal(c: MqttClient, q: QueuedTripCompleted) {
        try {
            val fmt = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.getDefault())
            val safeName = q.name.trim().replace("\"", "'")
            fun f2(v: Float) = String.format(java.util.Locale.US, "%.2f", v)
            fun f3(v: Float) = String.format(java.util.Locale.US, "%.3f", v)
            fun f1(v: Float) = String.format(java.util.Locale.US, "%.1f", v)
            val payload = """{"name":"$safeName","timestamp":"${fmt.format(Date(q.timestampMs))}","distance_km":${f2(q.snap.distKm)},"time_sec":${q.snap.timeSec},"fuel_l":${f3(q.snap.fuelL)},"energy_kwh":${f3(q.snap.energyKwh)},"regen_kwh":${f3(q.snap.regenKwh)},"net_kwh":${f3(q.snap.netKwh)},"kwh_per_100km":${f2(q.snap.kwhPer100km)},"km_per_l":${f2(q.snap.kmPerL)},"avg_speed_kmh":${f1(q.snap.avgSpeedKmh)},"soc_start":${f1(q.snap.startSocPct)},"soc_end":${f1(q.snap.currentSocPct)},"tank_start_l":${f1(q.snap.startTankL)},"tank_end_l":${f1(q.snap.currentTankL)}}"""
            c.publish("$prefix/${q.tripId}/last_completed", payload.toByteArray(), 1, true)
            lastSuccessfulPublishMs = System.currentTimeMillis()
            onStatusChange?.invoke(status)
            Log.i(TAG, "Trip completed published: ${q.tripId} name='${q.name}' dist=${q.snap.distKm}km")
        } catch (e: Exception) {
            // Re-queue on failure — trip events must not be lost
            synchronized(tripCompletedLock) { tripCompletedQueue.addFirst(q) }
            Log.w(TAG, "publishTripCompleted failed — re-queued: ${e.message}")
        }
    }

    private fun scheduleReconnect() {
        if (!enabled || isReconnecting.getAndSet(true)) return
        executor.submit {
            Thread.sleep(RECONNECT_DELAY_MS)
            isReconnecting.set(false)
            if (enabled && host.isNotEmpty()) connectInternal()
        }
    }

    private fun safeDisconnect(c: MqttClient) {
        try {
            if (c.isConnected) {
                c.publish("$prefix/status", MqttMessage("offline".toByteArray()).apply { qos = 1; isRetained = true })
                c.disconnect(1000)
            }
            c.close()
        } catch (_: Exception) {}
    }

    private fun publishDiscovery(c: MqttClient) {
        val modelStr = listOf(vehicleModel1, vehicleModel2)
            .filter { it.isNotBlank() }
            .joinToString(" / ")
            .ifEmpty { "Haval HEV" }
        val device = """{"identifiers":["haval_ecotrip"],"name":"Haval Ecotrip","model":"$modelStr","manufacturer":"Haval"}"""

        // sc = state_class: "measurement" para sensores contínuos, "total_increasing" para acumulados que nunca regridem; null = sem state_class (sensores de texto)
        data class S(val id: String, val name: String, val topic: String, val unit: String, val dc: String? = null, val icon: String? = null, val sc: String? = "measurement")

        val sensors = listOf(
            S("charge_current",     "Corrente de Carregamento", "$prefix/charge_current_a",   "A",         icon = "mdi:current-ac"),
            S("battery_voltage",    "Tensão da Bateria",        "$prefix/battery_voltage_v",  "V",         icon = "mdi:lightning-bolt"),
            S("battery_current",    "Corrente da Bateria",      "$prefix/battery_current_a",  "A",         icon = "mdi:current-dc"),
            S("charge_power",       "Potência de Recarga",      "$prefix/charge_power_kw",    "kW",        icon = "mdi:ev-station"),
            S("speed",              "Velocidade Atual",         "$prefix/speed_kmh",           "km/h",      "speed"),
            S("gear",               "Marcha",                "$prefix/gear",                  "",          icon = "mdi:car-shift-pattern", sc = null),
            S("inside_temp",        "Temperatura Interna",   "$prefix/inside_temp",           "°C",        "temperature"),
            S("outside_temp",       "Temperatura Externa",   "$prefix/outside_temp",          "°C",        "temperature"),
            S("rolling_kwh",        "Rolling kWh/100km",    "$prefix/rolling/kwh_per_100km", "kWh/100km", icon = "mdi:lightning-bolt"),
            S("rolling_kml",        "Rolling km/L",          "$prefix/rolling/km_per_l",      "km/L",      icon = "mdi:gas-station"),
            S("rolling_dist",       "Rolling Distância",     "$prefix/rolling/distance_km",   "km",        "distance"),
            S("rolling_fuel",       "Rolling Combustível",   "$prefix/rolling/fuel_l",        "L",         icon = "mdi:fuel"),
            S("trip_a_dist",        "Trip A Distância",      "$prefix/trip_a/distance_km",    "km",        "distance"),
            S("trip_a_kwh",         "Trip A kWh/100km",      "$prefix/trip_a/kwh_per_100km",  "kWh/100km", icon = "mdi:lightning-bolt"),
            S("trip_a_kml",         "Trip A km/L",           "$prefix/trip_a/km_per_l",       "km/L",      icon = "mdi:gas-station"),
            S("trip_a_speed",       "Trip A Vel. Média",     "$prefix/trip_a/avg_speed_kmh",  "km/h",      "speed"),
            S("trip_a_time",        "Trip A Tempo",          "$prefix/trip_a/time_sec",        "s",         icon = "mdi:timer"),
            S("trip_a_fuel",        "Trip A Combustível",    "$prefix/trip_a/fuel_l",         "L",         icon = "mdi:fuel"),
            S("trip_a_energy",      "Trip A Energia",        "$prefix/trip_a/energy_kwh",     "kWh",       "energy"),
            S("trip_a_regen",       "Trip A Regenerada",     "$prefix/trip_a/regen_kwh",      "kWh",       "energy"),
            S("trip_a_soc_start",   "Trip A SOC Início",     "$prefix/trip_a/soc_start",      "%",         icon = "mdi:battery-charging"),
            S("trip_a_soc_now",     "Trip A SOC Atual",      "$prefix/trip_a/soc_current",    "%",         icon = "mdi:battery"),
            S("trip_a_tank_start",  "Trip A Tanque Início",  "$prefix/trip_a/tank_start_l",   "L",         icon = "mdi:fuel"),
            S("trip_a_tank_now",    "Trip A Tanque Atual",   "$prefix/trip_a/tank_now_l",     "L",         icon = "mdi:fuel"),
            S("trip_b_dist",        "Trip B Distância",      "$prefix/trip_b/distance_km",    "km",        "distance"),
            S("trip_b_kwh",         "Trip B kWh/100km",      "$prefix/trip_b/kwh_per_100km",  "kWh/100km", icon = "mdi:lightning-bolt"),
            S("trip_b_kml",         "Trip B km/L",           "$prefix/trip_b/km_per_l",       "km/L",      icon = "mdi:gas-station"),
            S("trip_b_speed",       "Trip B Vel. Média",     "$prefix/trip_b/avg_speed_kmh",  "km/h",      "speed"),
            S("trip_b_time",        "Trip B Tempo",          "$prefix/trip_b/time_sec",        "s",         icon = "mdi:timer"),
            S("trip_b_fuel",        "Trip B Combustível",    "$prefix/trip_b/fuel_l",         "L",         icon = "mdi:fuel"),
            S("trip_b_energy",      "Trip B Energia",        "$prefix/trip_b/energy_kwh",     "kWh",       "energy"),
            S("trip_b_regen",       "Trip B Regenerada",     "$prefix/trip_b/regen_kwh",      "kWh",       "energy"),
            S("trip_b_soc_start",   "Trip B SOC Início",     "$prefix/trip_b/soc_start",      "%",         icon = "mdi:battery-charging"),
            S("trip_b_soc_now",     "Trip B SOC Atual",      "$prefix/trip_b/soc_current",    "%",         icon = "mdi:battery"),
            S("trip_b_tank_start",  "Trip B Tanque Início",  "$prefix/trip_b/tank_start_l",   "L",         icon = "mdi:fuel"),
            S("trip_b_tank_now",    "Trip B Tanque Atual",   "$prefix/trip_b/tank_now_l",     "L",         icon = "mdi:fuel"),
        )

        for (s in sensors) {
            val dcPart   = if (s.dc   != null) ""","device_class":"${s.dc}"""" else ""
            val iconPart = if (s.icon != null) ""","icon":"${s.icon}"""" else ""
            val unitPart = if (s.unit.isNotEmpty()) ""","unit_of_measurement":"${s.unit}"""" else ""
            val scPart   = if (s.sc   != null) ""","state_class":"${s.sc}"""" else ""
            val payload  = """{"name":"${s.name}","state_topic":"${s.topic}","unique_id":"haval_ecotrip_${s.id}","device":$device$unitPart$scPart$dcPart$iconPart}"""
            try { c.publish("homeassistant/sensor/haval_ecotrip_${s.id}/config", payload.toByteArray(), 1, true) } catch (_: Exception) {}
        }

        for ((id, name) in listOf("trip_a" to "Trip A Concluída", "trip_b" to "Trip B Concluída")) {
            val payload = """{"name":"$name","state_topic":"$prefix/$id/last_completed","value_template":"{{ value_json.distance_km }}","json_attributes_topic":"$prefix/$id/last_completed","unit_of_measurement":"km","state_class":"measurement","device_class":"distance","unique_id":"haval_ecotrip_${id}_completed","icon":"mdi:flag-checkered","device":$device}"""
            try { c.publish("homeassistant/sensor/haval_ecotrip_${id}_completed/config", payload.toByteArray(), 1, true) } catch (_: Exception) {}
        }

        // Sensor: última atualização de dados (timestamp ISO)
        val lastUpdatePayload = """{"name":"Última Atualização","state_topic":"$prefix/last_update","device_class":"timestamp","unique_id":"haval_ecotrip_last_update","icon":"mdi:clock-check-outline","device":$device}"""
        try { c.publish("homeassistant/sensor/haval_ecotrip_last_update/config", lastUpdatePayload.toByteArray(), 1, true) } catch (_: Exception) {}

        // NOTA: o select "Limite de Carga SOC" (haval_ecotrip_charge_limit) é publicado
        // exclusivamente pelo haval-ecotrip-commander, que também gerencia o wake-up do carro
        // via GWM API. O EcotripImpulse apenas escuta cmd/charge_limit e publica o estado.
        // Publicar o discovery aqui sobrescreveria o command_topic do Commander e quebraria o fluxo.

        Log.i(TAG, "HA Discovery published (${sensors.size + 2} entities)")
    }

    private fun loadConfig() {
        enabled          = prefs.getBoolean(SharedPreferencesKeys.MQTT_ENABLED,           false)
        host             = prefs.getString (SharedPreferencesKeys.MQTT_HOST,              "") ?: ""
        port             = prefs.getInt    (SharedPreferencesKeys.MQTT_PORT,              1883)
        username         = prefs.getString (SharedPreferencesKeys.MQTT_USERNAME,          "") ?: ""
        password         = prefs.getString (SharedPreferencesKeys.MQTT_PASSWORD,          "") ?: ""
        prefix           = prefs.getString (SharedPreferencesKeys.MQTT_PREFIX,            "haval/ecotrip") ?: "haval/ecotrip"
        publishIntervalS = prefs.getInt    (SharedPreferencesKeys.MQTT_PUBLISH_INTERVAL_S, DEFAULT_PUBLISH_INTERVAL_S)
        // Restore last-known sensor values so HA never shows stale zeros after app restart
        latestOutsideTemp = prefs.getFloat(SharedPreferencesKeys.LATEST_OUTSIDE_TEMP, 0f)
        latestInsideTemp  = prefs.getFloat(SharedPreferencesKeys.LATEST_INSIDE_TEMP,  0f)
    }

    private fun handleIncomingCommand(topic: String, payload: String) {
        val cmdPrefix = "$prefix/cmd/"
        if (!topic.startsWith(cmdPrefix)) return
        val cmd = topic.removePrefix(cmdPrefix).trimEnd('/')
        AppLogger.i(TAG, "Comando recebido: $cmd = '$payload'")

        executor.submit {
            val car = CarDataManager.getInstance()
            when (cmd) {
                "charge_limit" -> {
                    val pct = payload.trim().toIntOrNull()
                    val carVal = if (pct != null) pctToCarVal(pct) else null
                    if (pct == null || carVal == null) {
                        val msg = "error: valor inválido ('$payload'). Use 50, 60, 70, 80, 90 ou 100."
                        AppLogger.w(TAG, msg)
                        publishResult("charge_limit", msg)
                        return@submit
                    }

                    // ── Etapa 1: verificar se o carro está com barramento ativo ─────────
                    val now = System.currentTimeMillis()
                    val carActiveMs = now - lastCarDataMs
                    val carRecentlyActive = lastCarDataMs > 0L && carActiveMs <= 60_000L
                    if (carRecentlyActive)
                        AppLogger.i(TAG, "Carro ativo há ${carActiveMs / 1000}s — enviando diretamente.")
                    else
                        AppLogger.w(TAG, "Carro sem dados há ${carActiveMs / 1000}s — tentando mesmo assim.")

                    // ── Etapa 2: enviar configuração ao carro ─────────────────────────
                    AppLogger.i(TAG, "Enviando ao carro: charge_soc_limit_config = $carVal (${pct}%)")
                    val ok = car.requestSetting(
                        key   = "car.ev_setting.charge_soc_limit_config",
                        value = carVal.toString(),
                    )
                    if (!ok) {
                        val msg = if (carRecentlyActive)
                            "error: carro ativo mas recusou o comando"
                        else
                            "error: carro não respondeu — pode estar dormindo"
                        AppLogger.w(TAG, msg)
                        publishResult("charge_limit", msg)
                        return@submit
                    }
                    AppLogger.i(TAG, "requestSetting aceito. Aguardando 10s para o ECU processar...")

                    // ── Etapa 3: aguardar o ECU gravar a configuração ─────────────────
                    Thread.sleep(10_000)

                    // ── Etapa 4: ler de volta o valor real aplicado pelo carro ──────────
                    // limit_config reporta o estado real (0-5); target_config é só a solicitação
                    AppLogger.i(TAG, "Lendo charge_soc_limit_config para confirmar valor aplicado...")
                    val readBack = try {
                        car.fetchCurrent("car.ev_setting.charge_soc_limit_config")?.trim()
                    } catch (e: Exception) {
                        AppLogger.w(TAG, "fetchCurrent falhou: ${e.message}")
                        null
                    }

                    val confirmedCarVal = readBack?.toIntOrNull()
                    val confirmedPct    = if (confirmedCarVal != null) carValToPct(confirmedCarVal) else null

                    if (confirmedPct != null) {
                        // ── Etapa 5: publicar valor confirmado no HA (sempre, pois é pós-comando) ─
                        AppLogger.i(TAG, "Confirmado no carro: carVal=$confirmedCarVal → ${confirmedPct}%")
                        publishChargeLimitState(confirmedPct)
                        val resultMsg = if (confirmedPct == pct) "ok:$confirmedPct"
                                        else "ok:$confirmedPct (solicitado ${pct}% — carro aplicou ${confirmedPct}%)"
                        publishResult("charge_limit", resultMsg)
                    } else {
                        // Leitura falhou — publica o valor pretendido como fallback
                        AppLogger.w(TAG, "Leitura de confirmação falhou. Publicando valor pretendido como fallback.")
                        publishChargeLimitState(pct)
                        publishResult("charge_limit", "ok:$pct (fallback — leitura de confirmação falhou)")
                    }
                }
                else -> AppLogger.w(TAG, "Comando desconhecido: $cmd")
            }
        }
    }

    private fun publishResult(cmd: String, result: String) {
        try {
            client?.publish("$prefix/cmd/$cmd/result", result.toByteArray(), 1, false)
        } catch (e: Exception) {
            AppLogger.w(TAG, "Falha ao publicar resultado: ${e.message}")
        }
    }

    private fun setStatus(s: Status) {
        status = s
        onStatusChange?.invoke(s)
    }
}
