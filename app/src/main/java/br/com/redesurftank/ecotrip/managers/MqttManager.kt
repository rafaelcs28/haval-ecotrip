package br.com.redesurftank.ecotrip.managers

import android.content.Context
import android.content.SharedPreferences
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.util.Log
import br.com.redesurftank.ecotrip.BuildConfig
import br.com.redesurftank.ecotrip.models.SharedPreferencesKeys
import com.google.gson.Gson
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
        val rolling: RollingSnapshot,
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
    private val snapshotQueue = ArrayDeque<QueuedSnapshot>()
    private val snapshotLock  = Any()

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
    var latestMotorPowerKw:       Float = 0f  // kW — potência do motor elétrico (V×A/1000)
    var latestBasicBattVoltageV:  Float = 0f  // V — car.basic.battery_voltage (para cálculo de potência)
    var latestOdometerKm:   Float = 0f     // km — odômetro total do veículo
    var latestBatt12vPct:   Float = 0f     // % — carga da bateria auxiliar 12V
    // 0=Desconectado, 1=Carregando, 2=Programado, 3=Finalizado, 5=Aguardando liberação, -1=desconhecido
    var latestChargingState: Int = -1
    var latestChargeRemainingMin: Int = 0   // minutos restantes de recarga (0 = indisponível)
    var latestBattPowerPct: Int = 0    // % da potência da bateria (-100=regen total, +100=consumo total)
    var latestEngineRpm:    Int = 0    // rpm — rotação do motor térmico (ICE)
    var latestDriverSeatVent:    Int = 0    // 0=off, 1–3 nível de ventilação banco motorista
    var latestPassengerSeatVent: Int = 0    // 0=off, 1–3 nível de ventilação banco passageiro
    var latestHvacDriverTemp:    Float = 0f // °C — temperatura definida do AC (zona motorista)
    var latestHvacPassengerTemp: Float = 0f // °C — temperatura definida do AC (zona passageiro)
    var latestHvacFanSpeed:      Int   = 0  // nível do ventilador do AC (1..7)
    var latestHvacSyncEnable:    Int   = 0  // 0=off, 1=on (sync das zonas do AC)
    var latestHvacAutoEnable:    Int   = 0  // 0=off, 1=on (modo AUTO do AC)
    var latestHvacAcEnable:      Int   = 0  // 0=off, 1=on (master AC)
    var latestHvacCycleMode:     Int   = 0  // 0=recirc interna, 1=ar externo

    // Body — estados normalizados pra binário "1=aberto/destrancado, 0=fechado/trancado"
    // Doors (de car.basic.door_status, CSV FL,FR,RL,RR,Trunk — cada índice 0=fechada, 1=aberta)
    var latestDoorFl: Int = 0
    var latestDoorFr: Int = 0
    var latestDoorRl: Int = 0
    var latestDoorRr: Int = 0
    var latestTrunk:  Int = 0
    // Windows (de car.basic.window_status, CSV FL,FR,RL,RR — 0=fechado, ≠0=aberto)
    var latestWindowFl: Int = 0
    var latestWindowFr: Int = 0
    var latestWindowRl: Int = 0
    var latestWindowRr: Int = 0
    // Sunroof (de car.basic.sunroof_status — 0=fechado, >0=aberto)
    var latestSunroof: Int = 0
    // Trava (de car.basic.door_lock_status — semântica do valor cru, a confirmar com o carro real)
    var latestLockStatus: Int = 0
    // Driving ready (ignição) — usado pra derivar engine_state (carro on/off) sem oscilação
    // do motor a combustão (HEV liga/desliga o ICE várias vezes por minuto).
    var latestDrivingReadyState: Int = 0
    // Valores crus pra debug — facilita inspeção via MQTT pra confirmar semântica do barramento
    var latestDoorStatusRaw:   String = ""
    var latestWindowStatusRaw: String = ""

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
            val queued = QueuedSnapshot(now, tm.currentRolling())
            lastPublishMs = now
            executor.submit { publishSnapshotInternal(c, queued) }
        }, CHANGE_DEBOUNCE_MS)
    }

    /**
     * Publica snapshot IMEDIATAMENTE — bypassa o debounce de 1s.
     * Usar só para chaves event-driven (mudanças discretas e raras) onde latência importa:
     * gear, charging_state, driving_ready, AC (sync/auto/fan/temp), ventilação dos bancos.
     * Também usado pelo startup scan pra forçar o snapshot completo logo após a varredura.
     */
    fun markChangedImmediate() {
        val c = client ?: return
        if (!c.isConnected) return
        // Cancela qualquer debounce pendente — full snapshot já cobre tudo
        changeHandler.removeCallbacksAndMessages(null)
        changePending = false
        // O snapshot full cobre os tópicos da via expressa, então libera o slot
        // pra próxima rajada de fast (senão fica preso em true e nada publica).
        // Tarefas já agendadas no fastExecutor continuam — mas com isInFlight=false,
        // novas markChangedFast podem agendar imediatamente sem esperar.
        fastInFlight.set(false)
        val now = System.currentTimeMillis()
        val tm = TripManager.getInstance()
        val queued = QueuedSnapshot(now, tm.currentRolling())
        lastPublishMs = now
        executor.submit { publishSnapshotInternal(c, queued) }
    }

    // ── Via expressa pra telemetria de alta frequência ─────────────────────────
    // Speed, RPM, % potência motor e potência do motor (kW) mudam continuamente
    // durante a condução. Publica esses tópicos a ~40Hz (25ms debounce) sem mexer
    // no snapshot full. 40Hz fica logo abaixo da refresh rate do iOS (60Hz) — bom
    // ponto sem desperdiçar publishes em frames coalescidos.
    //
    // Robustez:
    //  - Executor DEDICADO (não compete com snapshots/históricos no executor
    //    principal). Se um snapshot full bloquear a fila do `executor`, fast lane
    //    continua fluindo no `fastExecutor`.
    //  - Drop-if-in-flight: se um publish anterior ainda não terminou, descarta o
    //    novo. Perde uma amostra de 50ms mas não enfileira.
    //  - Self-heal de 5s: se in-flight ficou preso por mais de 5s (rede engasgou,
    //    Paho não detectou desconexão, etc.), força reset pra não congelar a via
    //    expressa permanentemente.
    private val fastExecutor = java.util.concurrent.Executors.newSingleThreadScheduledExecutor()
    private val fastInFlight = AtomicBoolean(false)
    @Volatile private var fastInFlightSinceMs: Long = 0L
    private val CHANGE_FAST_DEBOUNCE_MS = 25L
    private val FAST_INFLIGHT_TIMEOUT_MS = 5_000L

    fun markChangedFast() {
        val now = System.currentTimeMillis()
        // Self-heal: publish anterior travou? Solta o slot.
        if (fastInFlight.get() && (now - fastInFlightSinceMs) > FAST_INFLIGHT_TIMEOUT_MS) {
            Log.w(TAG, "Fast lane preso há ${now - fastInFlightSinceMs}ms — força reset")
            fastInFlight.set(false)
        }
        // CAS atômico: só prossegue se NÃO há publish anterior em andamento.
        if (!fastInFlight.compareAndSet(false, true)) return
        fastInFlightSinceMs = now
        val c = client
        if (c == null || !c.isConnected) { fastInFlight.set(false); return }
        fastExecutor.schedule({
            try { publishFastTelemetryInternal(c) }
            catch (e: Exception) { Log.w(TAG, "Fast publish failed: ${e.message}") }
            finally { fastInFlight.set(false) }
        }, CHANGE_FAST_DEBOUNCE_MS, java.util.concurrent.TimeUnit.MILLISECONDS)
    }

    private fun publishFastTelemetryInternal(c: MqttClient) {
        try {
            fun pub(topic: String, value: String) =
                c.publish("$prefix/$topic", value.toByteArray(), 0, false)
            fun fmt1(v: Float) = String.format(java.util.Locale.US, "%.1f", v)
            fun fmt2(v: Float) = String.format(java.util.Locale.US, "%.2f", v)
            pub("speed_kmh",         fmt1(latestSpeedKmh))
            pub("engine_rpm",        latestEngineRpm.toString())
            pub("battery_power_pct", latestBattPowerPct.toString())
            pub("motor_power_kw",    fmt2(latestMotorPowerKw))
            // Carregando? publica a potência de recarga também (mesma fonte)
            if (latestChargingState == 1 && latestBatteryVoltageV > 0f) {
                val chargePowerKw = kotlin.math.abs(latestChargeCurrentA) * latestBatteryVoltageV / 1000f
                pub("charge_power_kw", fmt2(chargePowerKw))
            }
        } catch (e: Exception) {
            Log.w(TAG, "publishFastTelemetry failed: ${e.message}")
        }
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

    fun publish(rolling: RollingSnapshot) {
        val now      = System.currentTimeMillis()
        val interval = if (isWifiConnected()) publishIntervalWifiMs else publishIntervalCellularMs
        if (now - lastPublishMs < interval.toLong()) return
        lastPublishMs = now

        val queued = QueuedSnapshot(now, rolling)
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
            // Snapshot atômico dos campos no início da função. O publishSnapshotInternal
            // roda no executor mas pode ceder CPU entre cada c.publish() (paho enfileira
            // pra send thread). Se o main thread atualizar latest* durante esse intervalo,
            // publishes subsequentes leem valores novos — gera publish inconsistente
            // (ex.: window_fl publica "1" com latestWindowFl=0, debug/window_parsed
            // publica "1,1,1,1" com latestWindowFl=1 já atualizado). Capturar em locais
            // garante que todos os publishes desta chamada usem o mesmo estado.
            val snDoorFl = latestDoorFl;     val snDoorFr = latestDoorFr
            val snDoorRl = latestDoorRl;     val snDoorRr = latestDoorRr;     val snTrunk = latestTrunk
            val snWinFl  = latestWindowFl;   val snWinFr  = latestWindowFr
            val snWinRl  = latestWindowRl;   val snWinRr  = latestWindowRr
            val snSunroof   = latestSunroof
            val snLockStat  = latestLockStatus
            val snAcEnable  = latestHvacAcEnable
            val snDrvReady  = latestDrivingReadyState
            val snDoorRaw   = latestDoorStatusRaw
            val snWinRaw    = latestWindowStatusRaw
            val snEngineRpm = latestEngineRpm

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

            // GPS — publica apenas quando há sinal válido (≠ 0.0)
            val (gpsLat, gpsLng) = TripManager.getInstance().getLastGps()
            if (gpsLat != 0.0 && gpsLng != 0.0) {
                pubR("gps_lat", String.format(java.util.Locale.US, "%.6f", gpsLat))
                pubR("gps_lng", String.format(java.util.Locale.US, "%.6f", gpsLng))
            }

            // Electrical: corrente de carga, tensão e corrente do pack + potência derivada
            // retain=true — persiste no broker; HA não fica em branco se a conexão cair brevemente
            pubR("charge_current_a",  fmt2(latestChargeCurrentA))
            pubR("battery_voltage_v", fmt2(latestBatteryVoltageV))   // car.ev_info.power_battery_voltage (apenas telemetria)
            pubR("battery_current_a", fmt2(latestBatteryCurrentA))
            // Tensão do pack (namespace basic) — fonte usada no cálculo da potência do motor
            if (latestBasicBattVoltageV > 0f) pubR("basic_battery_voltage_v", fmt2(latestBasicBattVoltageV))
            // Potência do motor elétrico: (car.basic.battery_voltage × car.ev_info.cur_charge_current) / 1000
            // Positivo = consumo; negativo = regeneração
            pubR("motor_power_kw",    fmt2(latestMotorPowerKw))
            // % potência motor elétrico — car.ev_info.cur_battery_power_percentage
            pubR("battery_power_pct", latestBattPowerPct.toString())
            pubR("engine_rpm",        latestEngineRpm.toString())
            pubR("seat_vent_drv",     latestDriverSeatVent.toString())
            pubR("seat_vent_pass",    latestPassengerSeatVent.toString())
            pubR("hvac_driver_temp",     fmt1(latestHvacDriverTemp))
            pubR("hvac_passenger_temp",  fmt1(latestHvacPassengerTemp))
            pubR("hvac_fan_speed",    latestHvacFanSpeed.toString())
            pubR("hvac_sync_enable",  latestHvacSyncEnable.toString())
            pubR("hvac_auto_enable",  latestHvacAutoEnable.toString())
            pubR("ac_state",          if (snAcEnable > 0) "1" else "0")
            pubR("hvac_cycle_mode",   latestHvacCycleMode.toString())

            // Body — normaliza tudo pra binário "1=aberto/destrancado, 0=fechado/trancado"
            pubR("door_fl",    if (snDoorFl > 0) "1" else "0")
            pubR("door_fr",    if (snDoorFr > 0) "1" else "0")
            pubR("door_rl",    if (snDoorRl > 0) "1" else "0")
            pubR("door_rr",    if (snDoorRr > 0) "1" else "0")
            pubR("door_trunk", if (snTrunk  > 0) "1" else "0")
            // Vidros: cru "1" = fechado, qualquer outro valor = aberto/entreaberto
            // (mesma convenção que o HA usava com closedVal:'1' — confirmado em uso).
            pubR("window_fl",  if (snWinFl == 1) "0" else "1")
            pubR("window_fr",  if (snWinFr == 1) "0" else "1")
            pubR("window_rl",  if (snWinRl == 1) "0" else "1")
            pubR("window_rr",  if (snWinRr == 1) "0" else "1")
            // Sunroof: 0=fechado, >0=aberto (confirmado em uso).
            pubR("sunroof",    if (snSunroof  > 0) "1" else "0")
            // Trava: cru "3"=destrancado, "1"=trancado (confirmado em uso real).
            pubR("lock_state", if (snLockStat == 3) "1" else "0")
            // Estado da ignição (carro on/off): derivado de driving_ready_state.
            pubR("engine_state", if (snDrvReady > 0) "1" else "0")
            // Debug — valores crus do barramento + resultado do parsing (sem afetar lógica)
            if (snDoorRaw.isNotEmpty()) {
                pubR("debug/door_status_raw", snDoorRaw)
                pubR("debug/door_parsed",     "$snDoorFl,$snDoorFr,$snDoorRl,$snDoorRr,$snTrunk")
            }
            if (snWinRaw.isNotEmpty()) {
                pubR("debug/window_status_raw", snWinRaw)
                pubR("debug/window_parsed",     "$snWinFl,$snWinFr,$snWinRl,$snWinRr")
            }
            pubR("debug/sunroof_raw",      snSunroof.toString())
            pubR("debug/lock_status_raw",  snLockStat.toString())
            if (latestOdometerKm > 0f) pubR("odometer_km", fmt1(latestOdometerKm))
            if (latestBatt12vPct > 0f) pubR("batt_12v_pct", fmt1(latestBatt12vPct))
            // Potência de recarga: apenas quando charging_state == 1 (Carregando)
            // Corrente AC (cur_charge_current) × tensão do pack (car.ev_info.power_battery_voltage) / 1000
            val chargePowerKw = if (latestChargingState == 1 && latestBatteryVoltageV > 0f)
                kotlin.math.abs(latestChargeCurrentA) * latestBatteryVoltageV / 1000f else 0f
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
                val ts          = fmt.format(Date(e.timestampMs))
                val avgTempPart = if (e.avgTempC != null) ""","avg_temp_c":${f1(e.avgTempC)}""" else ""
                """{"timestamp":"$ts","timestamp_ms":${e.timestampMs},"duration_sec":${e.durationSec},"energy_kwh":${f2(e.energyKwh)},"soc_start":${f1(e.startSocPct)},"soc_end":${f1(e.endSocPct)},"avg_power_kw":${f2(e.avgPowerKw)}$avgTempPart}"""
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
            S("charge_current",           "Corrente de Carregamento",  "$prefix/charge_current_a",           "A",   icon = "mdi:current-ac"),
            S("battery_voltage",          "Tensão Bateria (ev_info)",  "$prefix/battery_voltage_v",          "V",   icon = "mdi:lightning-bolt"),
            S("basic_battery_voltage",    "Tensão Bateria (basic)",    "$prefix/basic_battery_voltage_v",    "V",   icon = "mdi:lightning-bolt-outline"),
            S("battery_current",          "Corrente da Bateria",       "$prefix/battery_current_a",          "A",   icon = "mdi:current-dc"),
            S("charge_power",             "Potência de Recarga",       "$prefix/charge_power_kw",            "kW",  icon = "mdi:ev-station"),
            S("motor_power_kw",           "Potência Motor Elétrico",   "$prefix/motor_power_kw",             "kW",  icon = "mdi:lightning-bolt-circle"),
            S("battery_power_pct",        "Potência Motor %",          "$prefix/battery_power_pct",          "%",   icon = "mdi:gauge"),
            S("engine_rpm",        "Rotação Motor Térmico",    "$prefix/engine_rpm",         "rpm",       icon = "mdi:engine"),
            S("seat_vent_drv",  "Ventilação Banco Motorista",  "$prefix/seat_vent_drv",  "", icon = "mdi:seat-recline-normal", sc = null),
            S("seat_vent_pass", "Ventilação Banco Passageiro", "$prefix/seat_vent_pass", "", icon = "mdi:seat-recline-normal", sc = null),
            S("hvac_driver_temp",    "AC Temperatura Motorista",  "$prefix/hvac_driver_temp",    "°C", dc = "temperature"),
            S("hvac_passenger_temp", "AC Temperatura Passageiro", "$prefix/hvac_passenger_temp", "°C", dc = "temperature"),
            S("hvac_fan_speed",   "AC Velocidade Ventilador", "$prefix/hvac_fan_speed",   "",   icon = "mdi:fan",          sc = null),
            S("hvac_sync_enable", "AC Sincronizar Zonas",     "$prefix/hvac_sync_enable", "",   icon = "mdi:link-variant", sc = null),
            S("hvac_auto_enable", "AC Modo Automático",       "$prefix/hvac_auto_enable", "",   icon = "mdi:auto-mode",    sc = null),
            S("hvac_cycle_mode",  "AC Recirculação",          "$prefix/hvac_cycle_mode",  "",   icon = "mdi:air-filter",   sc = null),
            S("charging_state",     "Estado de Recarga",        "$prefix/charging_state",     "",          icon = "mdi:ev-plug-type2", sc = null),
            S("speed",              "Velocidade Atual",         "$prefix/speed_kmh",           "km/h",      "speed"),
            S("gear",               "Marcha",                "$prefix/gear",                  "",          icon = "mdi:car-shift-pattern", sc = null),
            S("inside_temp",        "Temperatura Interna",   "$prefix/inside_temp",           "°C",        "temperature"),
            S("outside_temp",       "Temperatura Externa",   "$prefix/outside_temp",          "°C",        "temperature"),
            S("rolling_kwh",        "Rolling kWh/100km",    "$prefix/rolling/kwh_per_100km", "kWh/100km", icon = "mdi:lightning-bolt"),
            S("rolling_kml",        "Rolling km/L",          "$prefix/rolling/km_per_l",      "km/L",      icon = "mdi:gas-station"),
            S("rolling_dist",       "Rolling Distância",     "$prefix/rolling/distance_km",   "km",        "distance"),
            S("rolling_fuel",       "Rolling Combustível",   "$prefix/rolling/fuel_l",        "L",         icon = "mdi:fuel"),
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

        // ── Binary sensors — payload "1" = on/aberto, "0" = off/fechado ────────────
        data class B(val id: String, val name: String, val topic: String, val dc: String? = null, val icon: String? = null)
        val binarySensors = listOf(
            B("door_fl",     "Porta Diant. Esq.", "$prefix/door_fl",     dc = "door"),
            B("door_fr",     "Porta Diant. Dir.", "$prefix/door_fr",     dc = "door"),
            B("door_rl",     "Porta Tras. Esq.",  "$prefix/door_rl",     dc = "door"),
            B("door_rr",     "Porta Tras. Dir.",  "$prefix/door_rr",     dc = "door"),
            B("door_trunk",  "Porta-malas",       "$prefix/door_trunk",  dc = "door"),
            B("window_fl",   "Vidro Diant. Esq.", "$prefix/window_fl",   dc = "window"),
            B("window_fr",   "Vidro Diant. Dir.", "$prefix/window_fr",   dc = "window"),
            B("window_rl",   "Vidro Tras. Esq.",  "$prefix/window_rl",   dc = "window"),
            B("window_rr",   "Vidro Tras. Dir.",  "$prefix/window_rr",   dc = "window"),
            B("sunroof",     "Teto Solar",        "$prefix/sunroof",     icon = "mdi:car-select"),
            B("lock_state",  "Trava",             "$prefix/lock_state",  dc = "lock"),
            B("ac_state",    "AC Ligado",         "$prefix/ac_state",    icon = "mdi:air-conditioner"),
            B("engine_state","Motor ICE",         "$prefix/engine_state",dc = "running"),
        )
        for (b in binarySensors) {
            val dcPart   = if (b.dc   != null) ""","device_class":"${b.dc}"""" else ""
            val iconPart = if (b.icon != null) ""","icon":"${b.icon}"""" else ""
            val payload  = """{"name":"${b.name}","state_topic":"${b.topic}","unique_id":"haval_ecotrip_${b.id}","payload_on":"1","payload_off":"0","device":$device$dcPart$iconPart}"""
            try { c.publish("homeassistant/binary_sensor/haval_ecotrip_${b.id}/config", payload.toByteArray(), 1, true) } catch (_: Exception) {}
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

        Log.i(TAG, "HA Discovery published (${sensors.size + binarySensors.size + 4} entities)")   // +4 = app_version + last_update + trips_history + charging_history
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
