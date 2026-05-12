package br.com.redesurftank.ecotrip.managers

import android.content.Context
import android.content.SharedPreferences
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.util.Log
import br.com.redesurftank.ecotrip.BuildConfig
import br.com.redesurftank.ecotrip.models.SharedPreferencesKeys
import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import org.eclipse.paho.client.mqttv3.*
import org.eclipse.paho.client.mqttv3.persist.MemoryPersistence
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

private const val TAG = "MqttManager"
private const val CLIENT_ID = "haval_ecotrip"
private const val DEFAULT_PUBLISH_INTERVAL_MS           = 20_000
private const val DEFAULT_PUBLISH_INTERVAL_WIFI_MS      =  5_000
private const val DEFAULT_PUBLISH_INTERVAL_CELLULAR_MS  = 30_000
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

    // Trip completed — payloads pré-computados para fácil serialização em disco.
    // Sobrevive ao reinício do app: persistido em SharedPreferences enquanto não enviado.
    private data class QueuedTripCompleted(
        val lastCompletedTopic:   String,   // e.g. haval/ecotrip/trip_a/last_completed
        val lastCompletedPayload: String,   // JSON retido (last trip sensor no HA)
        val newTripPayload:       String,   // JSON não-retido (acumulado pelo HA)
    )

    companion object {
        @Volatile private var instance: MqttManager? = null
        fun getInstance() = instance ?: synchronized(this) {
            instance ?: MqttManager().also { instance = it }
        }
    }

    private lateinit var prefs: SharedPreferences
    private var appContext: Context? = null
    private val executor       = Executors.newSingleThreadExecutor()
    private val isReconnecting = AtomicBoolean(false)
    @Volatile private var client: MqttClient? = null
    private var lastPublishMs  = 0L
    private val gson = Gson()

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
    var enabled:                    Boolean = false
    var host:                       String  = ""
    var port:                       Int     = 1883
    var username:                   String  = ""
    var password:                   String  = ""
    var prefix:                     String  = "haval/ecotrip"
    var bridgeUrl:                  String  = ""
    var bridgeToken:                String  = ""
    var publishIntervalMs:          Int     = DEFAULT_PUBLISH_INTERVAL_MS      // legado — mantido para não quebrar código existente
    var publishIntervalWifiMs:      Int     = DEFAULT_PUBLISH_INTERVAL_WIFI_MS
    var publishIntervalCellularMs:  Int     = DEFAULT_PUBLISH_INTERVAL_CELLULAR_MS

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
    var latestBatteryCurrentA: Float = 0f  // A — corrente DC do pack (power_battery_current)
    var latestMotorPowerKw: Float = 0f     // kW — potência do motor elétrico (motor_power, HCU direto)
    var latestOdometerKm:   Float = 0f     // km — odômetro total do veículo
    var latestBatt12vPct:   Float = 0f     // % — carga da bateria auxiliar 12V
    // 0=Desconectado, 1=Carregando, 2=Programado, 3=Finalizado, 5=Aguardando liberação, -1=desconhecido
    var latestChargingState: Int = -1
    var latestChargeRemainingMin: Int = 0   // minutos restantes de recarga (0 = indisponível)
    var latestBattPowerPct: Int = 0    // % da potência da bateria (-100=regen total, +100=consumo total)
    var latestEngineRpm:    Int = 0    // rpm — rotação do motor térmico (ICE)

    // Último timestamp em que qualquer dado do carro foi recebido pelo app
    // Usado para saber se o barramento de dados do carro está ativo
    @Volatile var lastCarDataMs: Long = 0L

    // ── Publish por mudança de sinal (debounced) ──────────────────────────────
    private val changeHandler   = android.os.Handler(android.os.Looper.getMainLooper())
    @Volatile private var changePending = false
    private val CHANGE_DEBOUNCE_MS = 1_000L   // máx. 1 publish/s via mudança de sinal

    /**
     * Chamado pelo carListener a cada sinal novo do carro.
     * Se nenhum publish foi agendado, agenda um em 1s — assim rajadas de sinais
     * distintos resultam em apenas um publish consolidado.
     * Respeita o lastPublishMs para não duplicar com o publish timer-based.
     */
    fun markChanged() {
        if (changePending) return             // já há um agendado
        val c = client ?: return
        if (!c.isConnected) return
        changePending = true
        changeHandler.postDelayed({
            changePending = false
            val now = System.currentTimeMillis()
            if (now - lastPublishMs < 400L) return@postDelayed   // publicou há pouco pelo timer
            val tm = TripManager.getInstance()
            val queued = QueuedSnapshot(now, tm.currentSnapshotA(), tm.currentSnapshotB(), tm.currentRolling())
            lastPublishMs = now
            executor.submit { publishSnapshotInternal(c, queued) }
        }, CHANGE_DEBOUNCE_MS)
    }

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

        appContext = context.applicationContext
        val ctx = try { context.createDeviceProtectedStorageContext() } catch (_: Exception) { context }
        prefs = ctx.getSharedPreferences(SharedPreferencesKeys.PREFS_NAME, Context.MODE_PRIVATE)
        loadConfig()
        loadPendingTrips()   // restaura trips salvos antes do app ter sido reiniciado
        if (enabled && host.isNotEmpty()) connect()
    }

    /** Retorna true se a conexão ativa for WiFi. */
    private fun isWifiConnected(): Boolean {
        val ctx = appContext ?: return false
        val cm  = ctx.getSystemService(ConnectivityManager::class.java) ?: return false
        val caps = cm.getNetworkCapabilities(cm.activeNetwork) ?: return false
        return caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
    }

    fun saveAndApply() {
        prefs.edit()
            .putBoolean(SharedPreferencesKeys.MQTT_ENABLED,                     enabled)
            .putString (SharedPreferencesKeys.MQTT_HOST,                        host)
            .putInt    (SharedPreferencesKeys.MQTT_PORT,                        port)
            .putString (SharedPreferencesKeys.MQTT_USERNAME,                    username)
            .putString (SharedPreferencesKeys.MQTT_PASSWORD,                    password)
            .putString (SharedPreferencesKeys.MQTT_PREFIX,                      prefix)
            .putString (SharedPreferencesKeys.BRIDGE_URL,                       bridgeUrl)
            .putString (SharedPreferencesKeys.BRIDGE_TOKEN,                     bridgeToken)
            .putInt    (SharedPreferencesKeys.MQTT_PUBLISH_INTERVAL_WIFI_MS,     publishIntervalWifiMs)
            .putInt    (SharedPreferencesKeys.MQTT_PUBLISH_INTERVAL_CELLULAR_MS, publishIntervalCellularMs)
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
        val now      = System.currentTimeMillis()
        val interval = if (isWifiConnected()) publishIntervalWifiMs else publishIntervalCellularMs
        if (now - lastPublishMs < interval.toLong()) return
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
        if (snap.distKm < 0.5f) {
            AppLogger.i(TAG, "publishTripCompleted: $tripId ignorado (dist=${snap.distKm}km < 0.5km mínimo)")
            return
        }
        val connected = client?.isConnected == true
        AppLogger.i(TAG, "publishTripCompleted: $tripId dist=${String.format(java.util.Locale.US, "%.2f", snap.distKm)}km fuel=${String.format(java.util.Locale.US, "%.3f", snap.fuelL)}L connected=$connected")
        val queued = buildTripPayload(tripId, snap, name)
        // Persiste no disco ANTES de tentar enviar — garante que o trip sobrevive a crash/kill.
        // Só é removido do disco após confirmação de entrega (PUBACK) pelo broker.
        synchronized(tripCompletedLock) { tripCompletedQueue.addLast(queued) }
        savePendingTrips()
        val queueSize = synchronized(tripCompletedLock) { tripCompletedQueue.size }
        AppLogger.i(TAG, "Trip gravado no disco (fila=$queueSize): $tripId")
        val c = client
        if (c == null || !c.isConnected) {
            AppLogger.w(TAG, "Offline — trip aguardando reconexão: $tripId (fila=$queueSize)")
            return
        }
        AppLogger.i(TAG, "Enviando ao broker MQTT: $tripId")
        executor.submit { publishTripCompletedInternal(c, queued) }
    }

    /** Pré-computa os dois payloads MQTT a partir do snapshot e dados do trip. */
    private fun buildTripPayload(tripId: String, snap: TripSnapshot, name: String): QueuedTripCompleted {
        val fmt = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.getDefault())
        val ts = fmt.format(Date(System.currentTimeMillis()))
        val safeName  = gson.toJson(name.trim())   // JSON-quoted & escaped string (inclui as aspas)
        val tripLabel = if (tripId == "trip_a") "Trip A" else "Trip B"
        fun f1(v: Float) = String.format(java.util.Locale.US, "%.1f", v)
        fun f2(v: Float) = String.format(java.util.Locale.US, "%.2f", v)
        fun f3(v: Float) = String.format(java.util.Locale.US, "%.3f", v)

        val snapNetKwh      = (snap.energyKwh - snap.regenKwh).coerceAtLeast(0f)
        val fuelCostBrl     = snap.fuelL * snap.priceGasolinePerL
        val energyCostBrl   = snapNetKwh * snap.priceEnergyPerKwh
        val totalCostBrl    = fuelCostBrl + energyCostBrl
        val costPerKm       = if (snap.distKm > 0.1f) totalCostBrl / snap.distKm else 0f

        val completedPayload = """{"name":$safeName,"timestamp":"$ts","distance_km":${f2(snap.distKm)},"time_sec":"${fmtDur(snap.timeSec)}","fuel_l":${f3(snap.fuelL)},"energy_kwh":${f3(snap.energyKwh)},"regen_kwh":${f3(snap.regenKwh)},"net_kwh":${f3(snap.netKwh)},"kwh_per_100km":${f2(snap.kwhPer100km)},"km_per_l":${f2(snap.kmPerL)},"avg_speed_kmh":${f1(snap.avgSpeedKmh)},"soc_start":${f1(snap.startSocPct)},"soc_end":${f1(snap.currentSocPct)},"tank_start_l":${f1(snap.startTankL)},"tank_end_l":${f1(snap.currentTankL)},"fuel_cost_brl":${f2(fuelCostBrl)},"energy_cost_brl":${f2(energyCostBrl)},"total_cost_brl":${f2(totalCostBrl)},"cost_per_km":${f3(costPerKm)}}"""
        val newTripPayload   = """{"name":$safeName,"label":"$tripLabel","timestamp":"$ts","distance_km":${f2(snap.distKm)},"time_sec":"${fmtDur(snap.timeSec)}","fuel_l":${f2(snap.fuelL)},"energy_kwh":${f2(snap.energyKwh)},"regen_kwh":${f2(snap.regenKwh)},"net_kwh":${f2(snap.netKwh)},"kwh_per_100km":${f2(snap.kwhPer100km)},"km_per_l":${f2(snap.kmPerL)},"combined_km_l":${f2(snap.combinedKmL)},"soc_start":${f1(snap.startSocPct)},"soc_end":${f1(snap.currentSocPct)},"tank_start_l":${f1(snap.startTankL)},"tank_end_l":${f1(snap.currentTankL)},"fuel_cost_brl":${f2(fuelCostBrl)},"energy_cost_brl":${f2(energyCostBrl)},"total_cost_brl":${f2(totalCostBrl)},"cost_per_km":${f3(costPerKm)}}"""

        return QueuedTripCompleted(
            lastCompletedTopic   = "$prefix/$tripId/last_completed",
            lastCompletedPayload = completedPayload,
            newTripPayload       = newTripPayload,
        )
    }

    // ── Persistência da fila de trips pendentes ───────────────────────────────

    private fun savePendingTrips() {
        if (!::prefs.isInitialized) return
        synchronized(tripCompletedLock) {
            val json = gson.toJson(tripCompletedQueue.toList())
            prefs.edit().putString(SharedPreferencesKeys.PENDING_TRIP_PAYLOADS_JSON, json).commit()
        }
    }

    private fun loadPendingTrips() {
        if (!::prefs.isInitialized) return
        val json = prefs.getString(SharedPreferencesKeys.PENDING_TRIP_PAYLOADS_JSON, null)
            ?: return
        try {
            val type = object : TypeToken<List<QueuedTripCompleted>>() {}.type
            val loaded: List<QueuedTripCompleted> = gson.fromJson(json, type)
            synchronized(tripCompletedLock) {
                tripCompletedQueue.clear()
                tripCompletedQueue.addAll(loaded)
            }
            AppLogger.i(TAG, "Trips pendentes restaurados do disco: ${loaded.size}")
        } catch (e: Exception) {
            AppLogger.w(TAG, "Falha ao carregar trips pendentes do disco: ${e.message}")
        }
    }

    private fun clearPendingTrips() {
        if (!::prefs.isInitialized) return
        prefs.edit().remove(SharedPreferencesKeys.PENDING_TRIP_PAYLOADS_JSON).commit()
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
            // Publica versão do app com retain=true — sempre visível no HA mesmo offline
            try {
                c.publish("$prefix/app_version", BuildConfig.VERSION_NAME.toByteArray(), 1, true)
                AppLogger.i(TAG, "Versão publicada: ${BuildConfig.VERSION_NAME}")
            } catch (e: Exception) {
                AppLogger.w(TAG, "Falha ao publicar versão: ${e.message}")
            }
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
        // Trip completed first — most critical.
        // Tira cópia da fila mas NÃO limpa — cada item é removido individualmente
        // por publishTripCompletedInternal somente após confirmação PUBACK.
        val completed = synchronized(tripCompletedLock) { tripCompletedQueue.toList() }
        if (completed.isNotEmpty()) {
            AppLogger.i(TAG, "Enviando ${completed.size} trip(s) pendente(s) ao HA")
            for (q in completed) publishTripCompletedInternal(c, q)
        }

        // Publica histórico completo como retained após reconexão
        try {
            val history = TripManager.getInstance().getHistory()
            if (history.isNotEmpty()) {
                AppLogger.i(TAG, "Republicando histórico após reconexão: ${history.size} entrada(s)")
                publishTripHistoryInternal(c, history)
            }
        } catch (e: Exception) {
            AppLogger.w(TAG, "drainQueues: falha ao publicar histórico: ${e.message}")
        }

        // Publica histórico de recargas como retained após reconexão
        try {
            val charges = TripManager.getInstance().getChargeHistory()
            if (charges.isNotEmpty()) {
                AppLogger.i(TAG, "Republicando histórico de recargas após reconexão: ${charges.size} sessão(ões)")
                publishChargeHistoryInternal(c, charges)
            }
        } catch (e: Exception) {
            AppLogger.w(TAG, "drainQueues: falha ao publicar recargas: ${e.message}")
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
            fun pubR(topic: String, value: String) =   // retained — para sensores que devem sobreviver a reinício do HA
                c.publish("$prefix/$topic", value.toByteArray(), 0, true)
            fun fmt2(v: Float) = String.format(java.util.Locale.US, "%.2f", v)
            fun fmt3(v: Float) = String.format(java.util.Locale.US, "%.3f", v)
            fun fmt1(v: Float) = String.format(java.util.Locale.US, "%.1f", v)

            pub("speed_kmh",             fmt1(latestSpeedKmh))
            pub("inside_temp",           fmt1(latestInsideTemp))
            pub("outside_temp",          fmt1(latestOutsideTemp))
            if (latestGear.isNotEmpty()) pub("gear",  latestGear)

            // Electrical: corrente de carga, tensão e corrente do pack + potência derivada
            // retain=true — persiste no broker; HA não fica em branco se a conexão cair brevemente
            pubR("charge_current_a",  fmt2(latestChargeCurrentA))
            pubR("battery_voltage_v", fmt2(latestBatteryVoltageV))
            pubR("battery_current_a", fmt2(latestBatteryCurrentA))
            // Potência do motor elétrico — lida diretamente do HCU (car.ev_info.motor_power)
            // Valor positivo = consumo; negativo = regeneração; 0 = sem sinal do HCU
            pubR("motor_power_kw",    fmt2(latestMotorPowerKw))
            pubR("battery_power_pct", latestBattPowerPct.toString())
            pubR("engine_rpm",        latestEngineRpm.toString())
            if (latestOdometerKm > 0f) pubR("odometer_km", fmt1(latestOdometerKm))
            if (latestBatt12vPct > 0f) pubR("batt_12v_pct", fmt1(latestBatt12vPct))
            // Potência de recarga: apenas quando charging_state == 1 (Carregando)
            // Corrente AC (cur_charge_current) × tensão do pack / 1000
            val chargePowerKw = if (latestChargingState == 1 && latestBatteryVoltageV > 0f)
                latestChargeCurrentA * latestBatteryVoltageV / 1000f else 0f
            pubR("charge_power_kw",   fmt2(chargePowerKw))
            // Estado de recarga em texto legível
            val chargingStateText = when (latestChargingState) {
                0 -> "Desconectado"
                1 -> "Carregando"
                2 -> "Programado"
                3 -> "Finalizado"
                5 -> "Aguardando liberação"
                else -> "Desconhecido"
            }
            pubR("charging_state",       chargingStateText)
            pubR("charge_session_kwh",   fmt2(TripManager.getInstance().getChargeSessionEnergyKwh()))
            pubR("charge_remaining_min", latestChargeRemainingMin.toString())
            pub("rolling/kwh_per_100km", fmt2(q.rolling.netKwhPer100km))
            pub("rolling/km_per_l",      fmt2(q.rolling.kmPerL))
            pub("rolling/distance_km",   fmt2(q.rolling.windowKm))
            pub("rolling/fuel_l",        fmt3(q.rolling.fuelL))
            if (q.rolling.costBrl > 0.01f) pub("rolling/cost_brl", fmt2(q.rolling.costBrl))

            for ((label, snap) in listOf("trip_a" to q.snapA, "trip_b" to q.snapB)) {
                pub("$label/distance_km",    fmt2(snap.distKm))
                pub("$label/time_sec",        fmtDur(snap.timeSec))
                pub("$label/kwh_per_100km",  fmt2(snap.kwhPer100km))
                pub("$label/km_per_l",       fmt2(snap.kmPerL))
                pub("$label/avg_speed_kmh",  fmt1(snap.avgSpeedKmh))
                pub("$label/fuel_l",         fmt3(snap.fuelL))
                pub("$label/energy_kwh",     fmt3(snap.energyKwh))
                pub("$label/regen_kwh",      fmt3(snap.regenKwh))
                pub("$label/soc_start",   fmt1(snap.startSocPct))
                pubR("$label/soc_current", fmt1(snap.currentSocPct))   // retain — SOC não blanks no reconect
                pubR("$label/tank_start_l",fmt1(snap.startTankL))   // retain — nível do tanque sobrevive a reconect
                pubR("$label/tank_now_l",  fmt1(snap.currentTankL)) // retain — bridge/PWA usa sem carro ligado
                // Custo — calculado a partir dos preços embutidos no snapshot
                val liveFuelCost   = snap.fuelL * snap.priceGasolinePerL
                val liveNetKwh     = (snap.energyKwh - snap.regenKwh).coerceAtLeast(0f)
                val liveEnergyCost = liveNetKwh * snap.priceEnergyPerKwh
                val liveTotalCost  = liveFuelCost + liveEnergyCost
                val liveCostPerKm  = if (snap.distKm > 0.1f) liveTotalCost / snap.distKm else 0f
                pub("$label/cost_brl",    fmt2(liveTotalCost))
                pub("$label/cost_per_km", fmt3(liveCostPerKm))
            }
            // Lifetime — totais absolutos com retain=true (total_increasing no HA)
            val lt = TripManager.getInstance().getLifetimeSnapshot()
            pubR("lifetime/energy_kwh",  fmt3(lt.energyKwh))
            pubR("lifetime/regen_kwh",   fmt3(lt.regenKwh))
            pubR("lifetime/net_kwh",     fmt3(lt.netKwh))
            pubR("lifetime/distance_km", fmt2(lt.distKm))
            pubR("lifetime/time_sec",    fmtDur(lt.timeSec))
            pubR("lifetime/fuel_l",      fmt3(lt.fuelL))
            pubR("lifetime/charge_kwh",  fmt3(lt.chargeKwh))
            pubR("lifetime/charge_sec",  fmtDur(lt.chargeSec))
            // Custo lifetime — usa preços atuais (configuráveis pelo usuário)
            val ltPriceGas    = prefs.getFloat(SharedPreferencesKeys.PRICE_GASOLINE_PER_L, 6.0f)
            val ltPriceEnergy = prefs.getFloat(SharedPreferencesKeys.PRICE_ENERGY_PER_KWH, 0.9f)
            val ltCostBrl     = lt.fuelL * ltPriceGas + lt.netKwh.coerceAtLeast(0f) * ltPriceEnergy
            pubR("lifetime/cost_brl", fmt2(ltCostBrl))

            // Preços configurados pelo usuário — retain para bridge/PWA sempre ter o valor
            pubR("price_gas_per_l", fmt2(ltPriceGas))
            pubR("price_kwh",       fmt2(ltPriceEnergy))

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
            // QoS 1 — Paho bloqueia até receber PUBACK do broker (confirmação de entrega)
            AppLogger.i(TAG, "→ [1/2] Publicando last_completed (QoS 1, retained): ${q.lastCompletedTopic}")
            c.publish(q.lastCompletedTopic, q.lastCompletedPayload.toByteArray(), 1, true)
            AppLogger.i(TAG, "→ [1/2] PUBACK recebido ✓")

            AppLogger.i(TAG, "→ [2/2] Publicando new_trip (QoS 1): $prefix/trips/new_trip")
            c.publish("$prefix/trips/new_trip", q.newTripPayload.toByteArray(), 1, false)
            AppLogger.i(TAG, "→ [2/2] PUBACK recebido ✓")

            // Ambos confirmados — remove da fila e atualiza disco
            synchronized(tripCompletedLock) { tripCompletedQueue.remove(q) }
            val remaining = synchronized(tripCompletedLock) { tripCompletedQueue.size }
            if (remaining == 0) clearPendingTrips() else savePendingTrips()

            lastSuccessfulPublishMs = System.currentTimeMillis()
            onStatusChange?.invoke(status)
            AppLogger.i(TAG, "✓ Trip entregue e confirmado: ${q.lastCompletedTopic} (fila restante=$remaining)")
        } catch (e: Exception) {
            // Entrega falhou — item permanece na fila (já persistido no disco)
            AppLogger.e(TAG, "✗ Trip FALHOU — permanece na fila: ${e::class.simpleName}: ${e.message}")
        }
    }

    /**
     * Publica o histórico completo de trips diretamente no tópico retido.
     * O app é a fonte de verdade — não depende de automação HA para acumulação.
     */
    fun publishTripHistory(entries: List<TripHistoryEntry>) {
        if (entries.isEmpty()) return  // nunca sobrescreve HA com lista vazia (clearing in-app não zera HA)
        val c = client
        if (c == null || !c.isConnected) {
            AppLogger.w(TAG, "publishTripHistory: offline, histórico não publicado agora")
            return
        }
        AppLogger.i(TAG, "Enviando histórico ao broker: ${entries.size} entrada(s)")
        executor.submit { publishTripHistoryInternal(c, entries) }
    }

    private fun publishTripHistoryInternal(c: MqttClient, entries: List<TripHistoryEntry>) {
        try {
            val fmt = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.getDefault())
            fun f1(v: Float) = String.format(java.util.Locale.US, "%.1f", v)
            fun f2(v: Float) = String.format(java.util.Locale.US, "%.2f", v)

            val tripsJson = entries.joinToString(",") { e ->
                val ts = fmt.format(Date(e.timestampMs))
                val safeName  = gson.toJson(e.name)   // JSON-quoted & escaped
                val costPerKm = if (e.distKm > 0.1f && e.costBrl > 0f) e.costBrl / e.distKm else 0f
                """{"name":$safeName,"label":"${e.label}","timestamp":"$ts","distance_km":${f2(e.distKm)},"time_sec":"${fmtDur(e.timeSec)}","fuel_l":${f2(e.fuelL)},"energy_kwh":${f2(e.energyKwh)},"regen_kwh":${f2(e.regenKwh)},"net_kwh":${f2(e.netKwh)},"kwh_per_100km":${f2(e.kwhPer100km)},"km_per_l":${f2(e.kmPerL)},"combined_km_l":${f2(e.combinedKmL)},"avg_speed_kmh":${f1(e.avgSpeedKmh)},"soc_start":${f1(e.startSocPct)},"soc_end":${f1(e.endSocPct)},"tank_start_l":${f1(e.startTankL)},"tank_end_l":${f1(e.endTankL)},"total_cost_brl":${f2(e.costBrl)},"cost_per_km":${f2(costPerKm)}}"""
            }
            val payload = """{"count":${entries.size},"trips":[$tripsJson]}"""
            AppLogger.i(TAG, "→ Publicando histórico (QoS 1, retained): $prefix/trips/history")
            c.publish("$prefix/trips/history", payload.toByteArray(), 1, true)
            AppLogger.i(TAG, "✓ Histórico publicado: ${entries.size} entrada(s)")
        } catch (e: Exception) {
            AppLogger.e(TAG, "✗ Histórico FALHOU: ${e::class.simpleName}: ${e.message}")
        }
    }

    // ── Charge history ────────────────────────────────────────────────────────

    fun publishChargeHistory(entries: List<ChargeHistoryEntry>) {
        if (entries.isEmpty()) return
        val c = client
        if (c == null || !c.isConnected) {
            AppLogger.w(TAG, "publishChargeHistory: offline, não publicado agora")
            return
        }
        executor.submit { publishChargeHistoryInternal(c, entries) }
    }

    private fun publishChargeHistoryInternal(c: MqttClient, entries: List<ChargeHistoryEntry>) {
        try {
            val fmt = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.getDefault())
            fun f1(v: Float) = String.format(java.util.Locale.US, "%.1f", v)
            fun f2(v: Float) = String.format(java.util.Locale.US, "%.2f", v)
            val chargesJson = entries.joinToString(",") { e ->
                val ts = fmt.format(Date(e.timestampMs))
                """{"timestamp":"$ts","timestamp_ms":${e.timestampMs},"duration_sec":${e.durationSec},"energy_kwh":${f2(e.energyKwh)},"soc_start":${f1(e.startSocPct)},"soc_end":${f1(e.endSocPct)},"avg_power_kw":${f2(e.avgPowerKw)}}"""
            }
            val payload = """{"count":${entries.size},"charges":[$chargesJson]}"""
            AppLogger.i(TAG, "→ Publicando histórico de recargas (QoS 1, retained): $prefix/charging/history")
            c.publish("$prefix/charging/history", payload.toByteArray(), 1, true)
            AppLogger.i(TAG, "✓ Histórico de recargas publicado: ${entries.size} sessão(ões)")
        } catch (e: Exception) {
            AppLogger.e(TAG, "✗ Recargas FALHOU: ${e::class.simpleName}: ${e.message}")
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

    /**
     * Formata uma duração em segundos para string legível:
     *   < 60s            → "30s"
     *   < 60 min         → "58 min e 30s"
     *   < 24h            → "2h, 38 min e 20s"
     *   < 30 dias        → "3d, 2h, 38 min e 20s"
     *   < 12 meses       → "2 meses, 3d, 2h, 38 min e 20s"
     *   ≥ 12 meses       → "1 ano, 2 meses, 3d, 2h, 38 min e 20s"
     */
    private fun fmtDur(totalSec: Long): String {
        val s  = (totalSec % 60).toInt()
        val m  = (totalSec / 60 % 60).toInt()
        val h  = (totalSec / 3600 % 24).toInt()
        val d  = (totalSec / 86400 % 30).toInt()
        val mo = (totalSec / (86400L * 30) % 12).toInt()
        val yr = (totalSec / (86400L * 365)).toInt()
        return when {
            totalSec < 60L          -> "${s}s"
            totalSec < 3600L        -> "${m} min e ${s}s"
            totalSec < 86400L       -> "${h}h, ${m} min e ${s}s"
            totalSec < 86400L * 30  -> "${d}d, ${h}h, ${m} min e ${s}s"
            totalSec < 86400L * 365 -> "${mo} ${if (mo == 1) "mês" else "meses"}, ${d}d, ${h}h, ${m} min e ${s}s"
            else                    -> "${yr} ${if (yr == 1) "ano" else "anos"}, ${mo} ${if (mo == 1) "mês" else "meses"}, ${d}d, ${h}h, ${m} min e ${s}s"
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
            S("charging_state",     "Estado de Recarga",        "$prefix/charging_state",     "",          icon = "mdi:ev-plug-type2", sc = null),
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
            S("trip_a_time",        "Trip A Tempo",          "$prefix/trip_a/time_sec",        "",          icon = "mdi:timer", sc = null),
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
            S("trip_b_time",        "Trip B Tempo",          "$prefix/trip_b/time_sec",        "",          icon = "mdi:timer", sc = null),
            S("trip_b_fuel",        "Trip B Combustível",    "$prefix/trip_b/fuel_l",         "L",         icon = "mdi:fuel"),
            S("trip_b_energy",      "Trip B Energia",        "$prefix/trip_b/energy_kwh",     "kWh",       "energy"),
            S("trip_b_regen",       "Trip B Regenerada",     "$prefix/trip_b/regen_kwh",      "kWh",       "energy"),
            S("trip_b_soc_start",   "Trip B SOC Início",     "$prefix/trip_b/soc_start",      "%",         icon = "mdi:battery-charging"),
            S("trip_b_soc_now",     "Trip B SOC Atual",      "$prefix/trip_b/soc_current",    "%",         icon = "mdi:battery"),
            S("trip_b_tank_start",  "Trip B Tanque Início",  "$prefix/trip_b/tank_start_l",   "L",         icon = "mdi:fuel"),
            S("trip_b_tank_now",    "Trip B Tanque Atual",   "$prefix/trip_b/tank_now_l",     "L",         icon = "mdi:fuel"),
            // Custo por trip
            S("trip_a_cost",        "Trip A Custo",          "$prefix/trip_a/cost_brl",       "R\$",       icon = "mdi:cash"),
            S("trip_a_cost_per_km", "Trip A R\$/km",         "$prefix/trip_a/cost_per_km",    "R\$/km",    icon = "mdi:cash-multiple"),
            S("trip_b_cost",        "Trip B Custo",          "$prefix/trip_b/cost_brl",       "R\$",       icon = "mdi:cash"),
            S("trip_b_cost_per_km", "Trip B R\$/km",         "$prefix/trip_b/cost_per_km",    "R\$/km",    icon = "mdi:cash-multiple"),
            // Lifetime — state_class: total_increasing → HA registra estatísticas de longo prazo
            S("lifetime_energy",      "Lifetime Energia",           "$prefix/lifetime/energy_kwh",  "kWh", dc = "energy",    sc = "total_increasing"),
            S("lifetime_regen",       "Lifetime Regenerada",        "$prefix/lifetime/regen_kwh",   "kWh", dc = "energy",    sc = "total_increasing"),
            S("lifetime_net",         "Lifetime Líquido",           "$prefix/lifetime/net_kwh",     "kWh", dc = "energy",    sc = "total_increasing"),
            S("lifetime_distance",    "Lifetime Distância",         "$prefix/lifetime/distance_km", "km",  dc = "distance",  sc = "total_increasing"),
            S("lifetime_time",        "Lifetime Tempo",             "$prefix/lifetime/time_sec",    "",    icon = "mdi:timer",      sc = null),
            S("lifetime_fuel",        "Lifetime Combustível",       "$prefix/lifetime/fuel_l",      "L",   icon = "mdi:fuel",       sc = "total_increasing"),
            S("lifetime_charge",      "Lifetime Carregado",         "$prefix/lifetime/charge_kwh",  "kWh", dc = "energy",           sc = "total_increasing"),
            S("lifetime_charge_time", "Lifetime Tempo Recarga",     "$prefix/lifetime/charge_sec",  "",    icon = "mdi:timer-sand", sc = null),
            S("lifetime_cost",        "Lifetime Custo Total",       "$prefix/lifetime/cost_brl",    "R\$", icon = "mdi:cash-register"),
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

        // Sensor: versão do app instalada no carro
        val appVersionPayload = """{"name":"Versão do App","state_topic":"$prefix/app_version","unique_id":"haval_ecotrip_app_version","icon":"mdi:cellphone-arrow-down","device":$device}"""
        try { c.publish("homeassistant/sensor/haval_ecotrip_app_version/config", appVersionPayload.toByteArray(), 1, true) } catch (_: Exception) {}

        // Sensor: última atualização de dados (timestamp ISO)
        val lastUpdatePayload = """{"name":"Última Atualização","state_topic":"$prefix/last_update","device_class":"timestamp","unique_id":"haval_ecotrip_last_update","icon":"mdi:clock-check-outline","device":$device}"""
        try { c.publish("homeassistant/sensor/haval_ecotrip_last_update/config", lastUpdatePayload.toByteArray(), 1, true) } catch (_: Exception) {}

        // Sensor: histórico completo de trips (JSON array como atributo)
        val historyPayload = """{"name":"Histórico de Trips","state_topic":"$prefix/trips/history","value_template":"{{ value_json.count }}","json_attributes_topic":"$prefix/trips/history","unit_of_measurement":"viagens","state_class":"measurement","unique_id":"haval_ecotrip_trips_history","icon":"mdi:history","device":$device}"""
        try { c.publish("homeassistant/sensor/haval_ecotrip_trips_history/config", historyPayload.toByteArray(), 1, true) } catch (_: Exception) {}

        // Sensor: histórico de sessões de recarga (acumulado pelo HA via automation)
        val chargingHistoryPayload = """{"name":"Histórico de Recargas","state_topic":"$prefix/charging/history","value_template":"{{ value_json.count }}","json_attributes_topic":"$prefix/charging/history","unit_of_measurement":"recargas","state_class":"measurement","unique_id":"haval_ecotrip_historico_de_recargas","icon":"mdi:ev-station","device":$device}"""
        try { c.publish("homeassistant/sensor/haval_ecotrip_historico_de_recargas/config", chargingHistoryPayload.toByteArray(), 1, true) } catch (_: Exception) {}

        // NOTA: o select "Limite de Carga SOC" (haval_ecotrip_charge_limit) é publicado
        // exclusivamente pelo haval-ecotrip-commander, que também gerencia o wake-up do carro
        // via GWM API. O EcotripImpulse apenas escuta cmd/charge_limit e publica o estado.
        // Publicar o discovery aqui sobrescreveria o command_topic do Commander e quebraria o fluxo.

        Log.i(TAG, "HA Discovery published (${sensors.size + 4} entities)")   // +4 = 2×last_completed + app_version + last_update
    }

    private fun loadConfig() {
        enabled          = prefs.getBoolean(SharedPreferencesKeys.MQTT_ENABLED,           false)
        host             = prefs.getString (SharedPreferencesKeys.MQTT_HOST,              "") ?: ""
        port             = prefs.getInt    (SharedPreferencesKeys.MQTT_PORT,              1883)
        username         = prefs.getString (SharedPreferencesKeys.MQTT_USERNAME,          "") ?: ""
        password         = prefs.getString (SharedPreferencesKeys.MQTT_PASSWORD,          "") ?: ""
        prefix           = prefs.getString (SharedPreferencesKeys.MQTT_PREFIX,            "haval/ecotrip") ?: "haval/ecotrip"
        bridgeUrl        = prefs.getString (SharedPreferencesKeys.BRIDGE_URL,              "") ?: ""
        bridgeToken      = prefs.getString (SharedPreferencesKeys.BRIDGE_TOKEN,            "") ?: ""
        // Migração: lê legado (ms único ou segundos) para usar como base dos defaults WiFi
        val legacyMs = if (prefs.contains(SharedPreferencesKeys.MQTT_PUBLISH_INTERVAL_MS))
            prefs.getInt(SharedPreferencesKeys.MQTT_PUBLISH_INTERVAL_MS, DEFAULT_PUBLISH_INTERVAL_MS)
        else
            prefs.getInt(SharedPreferencesKeys.MQTT_PUBLISH_INTERVAL_S, 20) * 1000
        publishIntervalMs = legacyMs  // mantém campo legado atualizado

        // WiFi: usa novo valor salvo; se nunca configurado, herda legado (máx 5s) como padrão razoável
        publishIntervalWifiMs = if (prefs.contains(SharedPreferencesKeys.MQTT_PUBLISH_INTERVAL_WIFI_MS))
            prefs.getInt(SharedPreferencesKeys.MQTT_PUBLISH_INTERVAL_WIFI_MS, DEFAULT_PUBLISH_INTERVAL_WIFI_MS)
        else
            legacyMs.coerceAtMost(DEFAULT_PUBLISH_INTERVAL_WIFI_MS)

        // Celular: usa novo valor salvo; se nunca configurado, usa padrão 30s
        publishIntervalCellularMs = prefs.getInt(
            SharedPreferencesKeys.MQTT_PUBLISH_INTERVAL_CELLULAR_MS,
            DEFAULT_PUBLISH_INTERVAL_CELLULAR_MS,
        )
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
                "delete_trip" -> {
                    val isoTs = payload.trim()
                    if (isoTs.isEmpty()) {
                        publishResult("delete_trip", "error: timestamp vazio")
                        return@submit
                    }
                    val deleted = TripManager.getInstance().deleteHistoryEntry(isoTs)
                    if (deleted) {
                        val updated = TripManager.getInstance().getHistory()
                        publishTripHistory(updated)
                        publishResult("delete_trip", "ok:deleted $isoTs")
                        AppLogger.i(TAG, "✓ Trip deletado do histórico: $isoTs")
                    } else {
                        publishResult("delete_trip", "error:not_found $isoTs")
                        AppLogger.w(TAG, "Trip não encontrado para deletar: $isoTs")
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
