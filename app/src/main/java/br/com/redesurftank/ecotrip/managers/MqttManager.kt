package br.com.redesurftank.ecotrip.managers

import android.content.Context
import android.content.SharedPreferences
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.util.Log
import br.com.redesurftank.ecotrip.BuildConfig
import br.com.redesurftank.ecotrip.models.CarConstants
import br.com.redesurftank.ecotrip.models.SharedPreferencesKeys
import com.google.gson.Gson
import org.eclipse.paho.client.mqttv3.*
import org.eclipse.paho.client.mqttv3.persist.MemoryPersistence
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.Timer
import java.util.TimerTask
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

private const val TAG = "MqttManager"
private const val CLIENT_ID = "haval_ecotrip"
private const val DEFAULT_PUBLISH_INTERVAL_MS           = 20_000
private const val DEFAULT_PUBLISH_INTERVAL_WIFI_MS      =  5_000
private const val DEFAULT_PUBLISH_INTERVAL_CELLULAR_MS  = 30_000
// Backoff de reconexão escalonado: 5×1s → 10×2s → depois 5 em 5s (ver reconnectDelayMs).
private const val MAX_QUEUED_SNAPSHOTS = 50   // ~17 min at 20s interval

// Chaves de telemetria contínua que mudam o tempo todo durante a condução.
// Vão pra via expressa: publish só desses tópicos a até 20 Hz (debounce 50ms),
// pra PWA atualizar speed/RPM/power em quase tempo real.
private val FAST_LANE_KEYS: Set<String> = setOf(
    CarConstants.CAR_BASIC_VEHICLE_SPEED.value,
    CarConstants.CAR_BASIC_STEERING_WHEEL_ANGLE.value,       // ângulo do volante (gira o volante no PWA)
    CarConstants.CAR_BASIC_ENGINE_SPEED.value,
    CarConstants.CAR_EV_INFO_ENERGY_OUTPUT_PERCENTAGE.value,  // % potência motor
    CarConstants.CAR_EV_INFO_CUR_CHARGE_CURRENT.value,        // recalcula motor_power_kw
    CarConstants.CAR_EV_INFO_POWER_BATTERY_VOLTAGE.value,     // recalcula motor_power_kw
)

// Chaves event-driven: mudanças discretas e raras (toggle/seleção) onde latência importa.
// Publicam IMEDIATAMENTE no MQTT (full snapshot), ignorando o debounce de 1s do markChanged.
// Demais chaves (telemetria contínua não-rápida) seguem pelo fluxo debounced de 1s.
private val IMMEDIATE_PUBLISH_KEYS: Set<String> = setOf(
    CarConstants.CAR_BASIC_GEAR_STATUS.value,
    CarConstants.CAR_BASIC_DRIVING_READY_STATE.value,
    CarConstants.CAR_BASIC_POWER_MODE.value,
    CarConstants.CAR_EV_INFO_CHARGING_STATE.value,
    CarConstants.CAR_COMFORT_DRIVER_SEAT_VENT.value,
    CarConstants.CAR_COMFORT_PASSENGER_SEAT_VENT.value,
    CarConstants.CAR_HVAC_FAN_SPEED.value,
    CarConstants.CAR_HVAC_SYNC_ENABLE.value,
    CarConstants.CAR_HVAC_AUTO_ENABLE.value,
    CarConstants.CAR_HVAC_AC_ENABLE.value,
    CarConstants.CAR_HVAC_CYCLE_MODE.value,
    CarConstants.CAR_HVAC_DRIVER_TEMPERATURE.value,
    CarConstants.CAR_HVAC_PASSENGER_TEMPERATURE.value,
    CarConstants.CAR_HVAC_ACMAX_ENABLE.value,
    CarConstants.CAR_HVAC_ANION_ENABLE.value,
    CarConstants.CAR_HVAC_AQS_ENABLE.value,
    CarConstants.CAR_HVAC_HEATING_ENABLE.value,
    CarConstants.CAR_HVAC_FRONT_DEFROST_ENABLE.value,
    CarConstants.CAR_HVAC_REAR_DEFROST_ENABLE.value,
    CarConstants.CAR_HVAC_AUTO_DEFROST_ENABLE.value,
    CarConstants.CAR_HVAC_PM25_VALUE.value,
    CarConstants.CAR_HVAC_BLOWER_MODE.value,
    CarConstants.CAR_HVAC_POWER_MODE.value,
    CarConstants.CAR_BASIC_DOOR_LOCK_STATUS.value,
    CarConstants.CAR_BASIC_DOOR_STATUS.value,
    CarConstants.CAR_BASIC_WINDOW_STATUS.value,
    CarConstants.CAR_BASIC_SUNROOF_STATUS.value,
    CarConstants.CAR_BASIC_SEAT_BELT_WARNING.value,
    CarConstants.CAR_BASIC_SEATED_STATE.value,
    CarConstants.CAR_BASIC_FRONT_LIGHT_STATUS.value,
)

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
    // Executor SEPARADO pros comandos do usuário. Antes os comandos iam no mesmo
    // `executor` single-thread da telemetria e cada um faz Thread.sleep(3–10s) pra
    // reler a confirmação do carro — o 2º comando ficava na fila esperando o 1º, e
    // a publicação de telemetria travava durante o sleep. Pool dedicado: comandos
    // back-to-back rodam em paralelo e não bloqueiam a telemetria.
    private val cmdExecutor    = Executors.newFixedThreadPool(3)
    // Comandos HVAC escrevem no MESMO barramento; concorrência faz o carro descartar
    // escritas (ex.: ao ligar o pré-clima só o passageiro aplicava). Executor de thread
    // ÚNICA serializa hvac/* — um comando por vez, todos aplicam.
    private val hvacExecutor   = Executors.newSingleThreadExecutor()
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
    private var reconnectAttempts = 0   // p/ backoff escalonado da reconexão

    // Config
    var enabled:                    Boolean = false
    var host:                       String  = ""
    var port:                       Int     = 1883
    var username:                   String  = ""
    var password:                   String  = ""
    var tls:                        Boolean = false   // ssl:// — broker público com TLS
    var paired:                     Boolean = false   // config veio por pareamento (esconde credenciais na UI)
    var prefix:                     String  = "haval/ecotrip"
    var bridgeUrl:                  String  = ""
    var bridgeToken:                String  = ""
    var publishIntervalMs:          Int     = DEFAULT_PUBLISH_INTERVAL_MS      // legado — mantido para não quebrar código existente
    var publishIntervalWifiMs:      Int     = DEFAULT_PUBLISH_INTERVAL_WIFI_MS
    var publishIntervalCellularMs:  Int     = DEFAULT_PUBLISH_INTERVAL_CELLULAR_MS
    // High-frequency mode — ativado pelo bridge via cmd/hf_mode (PWA na aba
    // cluster/conforto). Sobrescreve o intervalo em runtime SEM persistir.
    // Auto-revert: o bridge envia '0' se não houver heartbeat do PWA.
    @Volatile private var hfModeActive: Boolean = false
    private val HF_MODE_INTERVAL_MS = 250

    // Vehicle model (populated from car data keys before connect)
    var vehicleModel1: String = ""
    var vehicleModel2: String = ""

    // Real-time values — updated by ConsumptionScreen on every car data event
    var latestSpeedKmh: Float = 0f
    var latestSteeringAngle: Float = 0f   // ângulo do volante (graus, ±) — via expressa
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
    var latestSocPct:       Float = 0f // % — SOC consolidado (pro LocalApiServer LAN)
    var latestDriverSeatVent:    Int = 0    // 0=off, 1–3 nível de ventilação banco motorista
    var latestPassengerSeatVent: Int = 0    // 0=off, 1–3 nível de ventilação banco passageiro
    var latestHvacDriverTemp:    Float = 0f // °C — temperatura definida do AC (zona motorista)
    var latestHvacPassengerTemp: Float = 0f // °C — temperatura definida do AC (zona passageiro)
    var latestHvacFanSpeed:      Int   = 0  // nível do ventilador do AC (1..7)
    var latestHvacSyncEnable:    Int   = 0  // 0=off, 1=on (sync das zonas do AC)
    var latestHvacAutoEnable:    Int   = 0  // 0=off, 1=on (modo AUTO do AC)
    var latestHvacAcEnable:      Int   = 0  // 0=off, 1=on (master AC)
    var latestHvacCycleMode:     Int   = 0  // 0=recirc interna, 1=ar externo
    var latestHvacAcMax:         Int   = 0  // 0=off, 1=on (resfriamento máximo)
    var latestHvacAnion:         Int   = 0  // 0=off, 1=on (ionizador)
    var latestHvacAqs:           Int   = 0  // 0=off, 1=on (recirc. autom. qualidade do ar)
    var latestHvacHeating:       Int   = 0  // 0=off, 1=on (aquecimento)
    var latestHvacFrontDefrost:  Int   = 0  // 0=off, 1=on
    var latestHvacRearDefrost:   Int   = 0  // 0=off, 1=on
    var latestHvacAutoDefrost:   Int   = 0  // 0=off, 1=on
    var latestHvacPm25:          Int   = 0  // µg/m³ (leitura)
    var latestHvacBlowerMode:    Int   = 0  // 0=frente,1=frente+pés,2=pés,3=pés+parabrisa,4=parabrisa
    var latestHvacPowerMode:     Int   = 0  // 0=AC desligado (mestre) | 1=ligado
    // Fan que estava ANTES do último OFF do AC (pra restaurar ao ligar). Como o
    // APK monitora o fan a todo momento, ele sabe o valor sem depender do app.
    @Volatile private var hvacFanBeforeOff: Int = 4   // default razoável se nunca desligou

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
    // Aviso de cinto (de car.basic.seat_belt_warning — 0=ok, >0=ocupante sem cinto)
    var latestSeatBeltWarning: Int = 0
    // Ocupação dos bancos (de car.basic.seated_state — formato cru a confirmar)
    var latestSeatedState: String = ""
    // Trava (de car.basic.door_lock_status — semântica do valor cru, a confirmar com o carro real)
    var latestLockStatus: Int = 0
    // Farol (de car.basic.front_light_status — 0=desligado, 1=ligado)
    var latestFrontLight: Int = 0
    // Setas: o carro envia ESTADO ESTÁVEL (1=seta ligada, 0=desligada). Guardamos o
    // último valor (lâmpada e alavanca); "ativa" = qualquer um != 0. O piscar é feito
    // na UI enquanto estiver ativa.
    @Volatile var latestLeftSwitch: Int = 0
    @Volatile var latestRightSwitch: Int = 0
    @Volatile var latestLeftTurnLamp: Int = 0
    @Volatile var latestRightTurnLamp: Int = 0
    fun isTurnLeftActive(): Boolean  = latestLeftTurnLamp != 0 || latestLeftSwitch != 0
    fun isTurnRightActive(): Boolean = latestRightTurnLamp != 0 || latestRightSwitch != 0

    // ── Voting filter pra car.basic.window_status ─────────────────────────────
    // O car bus emite valores ruidosos em rajadas (até 6 leituras consecutivas
    // reportando o valor errado). Voting: só atualiza latestWindow* quando
    // WINDOW_VOTE_REQUIRED leituras consecutivas do mesmo valor são vistas.
    //
    // Timestamp da mudança: quando o pending muda (primeira leitura do valor
    // novo), gravamos o ms. Quando o voting confirma, esse ms vira o "real
    // changed at" do estado. Publicamos ele junto no MQTT pra que o evento no
    // log do PWA mostre a hora REAL da mudança, não a hora da confirmação
    // (~40s atrasada).
    private var pendingFl: Int = 0; private var pendingFlCount: Int = 0; private var pendingFlSinceMs: Long = 0L
    private var pendingFr: Int = 0; private var pendingFrCount: Int = 0; private var pendingFrSinceMs: Long = 0L
    private var pendingRl: Int = 0; private var pendingRlCount: Int = 0; private var pendingRlSinceMs: Long = 0L
    private var pendingRr: Int = 0; private var pendingRrCount: Int = 0; private var pendingRrSinceMs: Long = 0L
    @Volatile var latestWindowFlConfirmedMs: Long = 0L
    @Volatile var latestWindowFrConfirmedMs: Long = 0L
    @Volatile var latestWindowRlConfirmedMs: Long = 0L
    @Volatile var latestWindowRrConfirmedMs: Long = 0L
    @Volatile private var windowVoteInitialized: Boolean = false
    private val WINDOW_VOTE_REQUIRED = 15

    // ── Voting filter pra car.basic.door_lock_status ──────────────────────────
    // Mesma motivação dos vidros: car bus emite bursts ruidosos. Usuário relatou
    // PWA marcando "trancado" sem o carro estar trancado.
    private var pendingLock: Int = 0; private var pendingLockCount: Int = 0; private var pendingLockSinceMs: Long = 0L
    @Volatile var latestLockConfirmedMs: Long = 0L
    @Volatile private var lockVoteInitialized: Boolean = false
    private val LOCK_VOTE_REQUIRED = 8

    /** Aplica voting filter em uma nova leitura de car.basic.door_lock_status. */
    fun applyLockStatus(raw: Int) {
        val now = System.currentTimeMillis()
        if (!lockVoteInitialized) {
            latestLockStatus = raw
            pendingLock = raw; pendingLockCount = 1; pendingLockSinceMs = now
            latestLockConfirmedMs = now
            lockVoteInitialized = true
            return
        }
        if (raw == pendingLock) {
            if (++pendingLockCount >= LOCK_VOTE_REQUIRED && latestLockStatus != raw) {
                latestLockStatus = raw
                latestLockConfirmedMs = pendingLockSinceMs
            }
        } else {
            pendingLock = raw; pendingLockCount = 1; pendingLockSinceMs = now
        }
    }

    /** Aplica voting filter em uma nova leitura de car.basic.window_status. */
    fun applyWindowStatus(fl: Int, fr: Int, rl: Int, rr: Int) {
        val now = System.currentTimeMillis()
        if (!windowVoteInitialized) {
            // Confia na primeira leitura — sem dados pra votar
            latestWindowFl = fl; pendingFl = fl; pendingFlCount = 1; pendingFlSinceMs = now; latestWindowFlConfirmedMs = now
            latestWindowFr = fr; pendingFr = fr; pendingFrCount = 1; pendingFrSinceMs = now; latestWindowFrConfirmedMs = now
            latestWindowRl = rl; pendingRl = rl; pendingRlCount = 1; pendingRlSinceMs = now; latestWindowRlConfirmedMs = now
            latestWindowRr = rr; pendingRr = rr; pendingRrCount = 1; pendingRrSinceMs = now; latestWindowRrConfirmedMs = now
            windowVoteInitialized = true
            return
        }
        // Cada vidro vota independente. Quando o pending atinge o threshold e o valor
        // confirmado é DIFERENTE do atual, registra o instante em que o pending começou
        // (não o instante da confirmação) — esse vira o timestamp real da mudança.
        if (fl == pendingFl) {
            if (++pendingFlCount >= WINDOW_VOTE_REQUIRED && latestWindowFl != fl) {
                latestWindowFl = fl; latestWindowFlConfirmedMs = pendingFlSinceMs
            }
        } else { pendingFl = fl; pendingFlCount = 1; pendingFlSinceMs = now }
        if (fr == pendingFr) {
            if (++pendingFrCount >= WINDOW_VOTE_REQUIRED && latestWindowFr != fr) {
                latestWindowFr = fr; latestWindowFrConfirmedMs = pendingFrSinceMs
            }
        } else { pendingFr = fr; pendingFrCount = 1; pendingFrSinceMs = now }
        if (rl == pendingRl) {
            if (++pendingRlCount >= WINDOW_VOTE_REQUIRED && latestWindowRl != rl) {
                latestWindowRl = rl; latestWindowRlConfirmedMs = pendingRlSinceMs
            }
        } else { pendingRl = rl; pendingRlCount = 1; pendingRlSinceMs = now }
        if (rr == pendingRr) {
            if (++pendingRrCount >= WINDOW_VOTE_REQUIRED && latestWindowRr != rr) {
                latestWindowRr = rr; latestWindowRrConfirmedMs = pendingRrSinceMs
            }
        } else { pendingRr = rr; pendingRrCount = 1; pendingRrSinceMs = now }
    }
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
            pub("steering_angle",    fmt1(latestSteeringAngle))
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
    // Estados dos controles drive — internal (não private) pra LocalApiServer
    // expor via LAN. Atualizados pelas funções syncXxxFromCar / publishXxxState.
    @Volatile var lastPublishedDriveMode: Int = -1   // 0=HEV, 1=Prior. EV, 3=EV
    @Volatile var lastPublishedPowerReserve: Int = -1 // 1=inteligente, 2=prioritário
    @Volatile var lastPublishedSocTarget: Int = -1    // 20..80 %
    @Volatile var lastPublishedTerrainMode: Int = -1  // 0=Normal,1=Sport,2=Eco,3=Neve,4=Areia,5=Lama,11=AWD
    @Volatile var lastPublishedRegenLevel: Int = -1   // 0=Normal, 1=Alto, 2=Baixo
    @Volatile var lastPublishedOnePedal: Int = -1     // 0=off, 1=on
    @Volatile var lastPublishedEsp: Int = -1          // 0=off, 1=on
    @Volatile var lastPublishedSteerMode: Int = -1    // 0=Normal, 1=Sport, 2=Conforto

    // Cache de dedupe por-tópico do snapshot periódico: só publica se o valor mudou.
    // Reseta no reconnect (clear no connect bem-sucedido) → ao reconectar tudo é
    // republicado. Tocado apenas dentro do executor single-thread (publishSnapshotInternal
    // e connectInternal), por isso HashMap simples é seguro.
    private val lastPubSnapshot = HashMap<String, String>()

    // Heartbeat de 5s no tópico haval/ecotrip/heartbeat — bypassa o dedupe e
    // garante TRÁFEGO MQTT real a cada 5s, mesmo com o carro parado/com dedupe
    // total. Função: (1) "ping de aplicação" — se a publish falha, o Paho dispara
    // connectionLost na hora (detecção em ~5-6s, mais rápido que o keepalive
    // do broker); (2) faz a métrica per-second do bridge refletir UPTIME REAL,
    // não o intervalo natural entre snapshots.
    @Volatile private var heartbeatFuture: java.util.concurrent.ScheduledFuture<*>? = null

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
        restoreDiagState(prefs)
        // Listener GLOBAL pro car bus — antes vivia em ConsumptionScreen.kt (dentro
        // de um DisposableEffect que descadastrava ao sair da tela). Agora roda
        // SEMPRE — RPM/SOC/speed continuam sendo capturados independente da UI.
        attachGlobalCarDataListener(context)
        if (enabled && host.isNotEmpty()) connect()
    }

    /**
     * Cadastra o listener completo do car bus + o connectedListener (startup scan).
     * Chamado uma vez por init(), processa TODAS as chaves do CAN bus e nutre os
     * latest* + TripManager + sync*FromCar(). Sem este listener, dados de viagem
     * ficam congelados quando o usuário sai da ConsumptionScreen.
     */
    private fun attachGlobalCarDataListener(context: Context) {
        val tripManager = TripManager.getInstance()
        val carManager  = CarDataManager.getInstance()

        // Recalcula potência de recarga e notifica TripManager quando qualquer
        // dado elétrico relevante muda (estado, corrente ou tensão).
        fun syncCharging() {
            val state   = latestChargingState
            val powerKw = if (state == 1 && latestBatteryVoltageV > 0f)
                kotlin.math.abs(latestChargeCurrentA) * latestBatteryVoltageV / 1000f
            else 0f
            tripManager.onChargingUpdate(state == 1, powerKw)
        }

        lateinit var carListener: (String, String) -> Unit
        carListener = { key, value ->
            lastCarDataMs = System.currentTimeMillis()
            when (key) {
                CarConstants.CAR_BASIC_POWER_MODE.value -> {
                    val mode = value.trim().toIntOrNull() ?: 0
                    when (mode) {
                        1, 2, 3 -> tripManager.onSessionStart()
                        0       -> tripManager.onSessionEnd()
                    }
                }
                CarConstants.CAR_BASIC_VEHICLE_SPEED.value -> {
                    latestSpeedKmh = value.trim().toFloatOrNull() ?: 0f
                    tripManager.onDataChanged(key, value)
                }
                CarConstants.CAR_BASIC_STEERING_WHEEL_ANGLE.value -> {
                    latestSteeringAngle = value.trim().toFloatOrNull() ?: 0f
                }
                CarConstants.CAR_BASIC_INSIDE_TEMP.value -> {
                    latestInsideTemp = value.trim().toFloatOrNull() ?: 0f
                    tripManager.onDataChanged(key, value)
                }
                CarConstants.CAR_BASIC_OUTSIDE_TEMP.value -> {
                    latestOutsideTemp = value.trim().toFloatOrNull() ?: 0f
                    tripManager.onDataChanged(key, value)
                }
                CarConstants.CAR_EV_SETTING_CHARGE_SOC_LIMIT.value -> {
                    val carVal = value.trim().toIntOrNull()
                    if (carVal != null) syncChargeLimitFromCar(carVal)
                    tripManager.onDataChanged(key, value)
                }
                CarConstants.CAR_BASIC_GEAR_STATUS.value -> {
                    val raw = value.trim().toIntOrNull()
                    val gearStr = when (raw) {
                        0    -> "N"
                        2    -> "D"
                        3    -> "P"
                        4    -> "R"
                        else -> raw?.toString() ?: value.trim()
                    }
                    latestGear = gearStr
                    tripManager.onGear(gearStr)
                }
                CarConstants.CAR_BASIC_DRIVING_READY_STATE.value -> {
                    val state = value.trim().toIntOrNull()
                    if (state != null) {
                        latestDrivingReadyState = state
                        tripManager.onDrivingReady(state)
                    }
                }
                CarConstants.CAR_EV_INFO_CUR_CHARGE_CURRENT.value -> {
                    val raw = value.trim().toFloatOrNull() ?: 0f
                    // O bus retorna sentinelas tipo -1001 quando o carro está
                    // parado/sem dado. Range físico real: ~ -400..+400 A.
                    val current = if (kotlin.math.abs(raw) > 500f) 0f else raw
                    latestChargeCurrentA = current
                    // Potência do motor: V (car.ev_info.power_battery_voltage) × A / 1000 = kW
                    val motorKw = latestBatteryVoltageV * current / 1000f
                    latestMotorPowerKw = motorKw
                    tripManager.updateMotorPowerKw(motorKw)
                    syncCharging()
                }
                CarConstants.CAR_BASIC_BATTERY_VOLTAGE.value -> {
                    // Apenas armazena — não entra no cálculo de potência
                    latestBasicBattVoltageV = value.trim().toFloatOrNull() ?: 0f
                }
                CarConstants.CAR_EV_INFO_POWER_BATTERY_VOLTAGE.value -> {
                    val rawV = value.trim().toFloatOrNull() ?: 0f
                    // Filtra sentinelas (range físico real: ~250..450 V)
                    val voltage = if (rawV < 100f || rawV > 600f) 0f else rawV
                    latestBatteryVoltageV = voltage
                    val motorKw = voltage * latestChargeCurrentA / 1000f
                    latestMotorPowerKw = motorKw
                    tripManager.updateMotorPowerKw(motorKw)
                    tripManager.onDataChanged(key, value)
                    syncCharging()
                }
                CarConstants.CAR_EV_INFO_POWER_BATTERY_CURRENT.value -> {
                    latestBatteryCurrentA = value.trim().toFloatOrNull() ?: 0f
                    tripManager.onDataChanged(key, value)
                }
                CarConstants.CAR_BASIC_TOTAL_ODOMETER.value -> {
                    val km = value.trim().toFloatOrNull() ?: 0f
                    latestOdometerKm = km
                    // não passa para TripManager (não é usado em cálculos de trip)
                }
                CarConstants.CAR_EV_INFO_CHARGING_STATE.value -> {
                    latestChargingState = value.trim().toIntOrNull() ?: -1
                    syncCharging()
                }
                CarConstants.CAR_EV_INFO_CHARGE_REMAINING_TIME.value -> {
                    latestChargeRemainingMin = value.trim().toIntOrNull() ?: 0
                }
                CarConstants.CAR_EV_INFO_ENERGY_OUTPUT_PERCENTAGE.value -> {
                    // % potência motor elétrico em tempo real → barra no iPhone + telemetria
                    latestBattPowerPct = value.trim().toIntOrNull() ?: 0
                    tripManager.onDataChanged(key, value)  // rastreia pico no auto-trip + telemetria
                    // Listener parcial antigo também publicava o sinal de regen aqui;
                    // mantém o comportamento pra HA continuar recebendo.
                    val carValF = value.trim().toFloatOrNull()
                    if (carValF != null) publishRegenPower(carValF)
                }
                CarConstants.CAR_EV_INFO_CUR_BATTERY_POWER_PERCENTAGE.value -> {
                    // SOC da bateria → alimenta latestSocPct para SOC inicial/final dos trips
                    tripManager.onDataChanged(key, value)
                }
                CarConstants.CAR_BASIC_ENGINE_SPEED.value -> {
                    latestEngineRpm = value.trim().toIntOrNull() ?: 0
                    tripManager.onDataChanged(key, value)  // alimenta telemetryRecorder.latestEngineRpm
                }
                CarConstants.CAR_COMFORT_DRIVER_SEAT_VENT.value -> {
                    latestDriverSeatVent = value.trim().toIntOrNull() ?: 0
                }
                CarConstants.CAR_COMFORT_PASSENGER_SEAT_VENT.value -> {
                    latestPassengerSeatVent = value.trim().toIntOrNull() ?: 0
                }
                CarConstants.CAR_HVAC_DRIVER_TEMPERATURE.value -> {
                    latestHvacDriverTemp = value.trim().toFloatOrNull() ?: 0f
                }
                CarConstants.CAR_HVAC_PASSENGER_TEMPERATURE.value -> {
                    latestHvacPassengerTemp = value.trim().toFloatOrNull() ?: 0f
                }
                CarConstants.CAR_HVAC_FAN_SPEED.value -> {
                    latestHvacFanSpeed = value.trim().toIntOrNull() ?: 0
                }
                CarConstants.CAR_HVAC_SYNC_ENABLE.value -> {
                    latestHvacSyncEnable = value.trim().toIntOrNull() ?: 0
                }
                CarConstants.CAR_HVAC_AUTO_ENABLE.value -> {
                    latestHvacAutoEnable = value.trim().toIntOrNull() ?: 0
                }
                CarConstants.CAR_HVAC_AC_ENABLE.value -> {
                    latestHvacAcEnable = value.trim().toIntOrNull() ?: 0
                }
                CarConstants.CAR_HVAC_CYCLE_MODE.value -> {
                    latestHvacCycleMode = value.trim().toIntOrNull() ?: 0
                }
                CarConstants.CAR_HVAC_ACMAX_ENABLE.value -> {
                    latestHvacAcMax = value.trim().toIntOrNull() ?: 0
                }
                CarConstants.CAR_HVAC_ANION_ENABLE.value -> {
                    latestHvacAnion = value.trim().toIntOrNull() ?: 0
                }
                CarConstants.CAR_HVAC_AQS_ENABLE.value -> {
                    latestHvacAqs = value.trim().toIntOrNull() ?: 0
                }
                CarConstants.CAR_HVAC_HEATING_ENABLE.value -> {
                    latestHvacHeating = value.trim().toIntOrNull() ?: 0
                }
                CarConstants.CAR_HVAC_FRONT_DEFROST_ENABLE.value -> {
                    latestHvacFrontDefrost = value.trim().toIntOrNull() ?: 0
                }
                CarConstants.CAR_HVAC_REAR_DEFROST_ENABLE.value -> {
                    latestHvacRearDefrost = value.trim().toIntOrNull() ?: 0
                }
                CarConstants.CAR_HVAC_AUTO_DEFROST_ENABLE.value -> {
                    latestHvacAutoDefrost = value.trim().toIntOrNull() ?: 0
                }
                CarConstants.CAR_HVAC_PM25_VALUE.value -> {
                    latestHvacPm25 = value.trim().toFloatOrNull()?.toInt() ?: 0
                }
                CarConstants.CAR_HVAC_BLOWER_MODE.value -> {
                    latestHvacBlowerMode = value.trim().toIntOrNull() ?: 0
                }
                CarConstants.CAR_HVAC_POWER_MODE.value -> {
                    latestHvacPowerMode = value.trim().toIntOrNull() ?: 0
                }
                CarConstants.CAR_BASIC_DOOR_LOCK_STATUS.value -> {
                    val raw = value.trim().toIntOrNull() ?: 0
                    applyLockStatus(raw)  // voting filter K=8
                }
                CarConstants.CAR_BASIC_FRONT_LIGHT_STATUS.value -> {
                    latestFrontLight = value.trim().toFloatOrNull()?.toInt() ?: 0
                }
                CarConstants.CAR_BASIC_LEFT_TURN_LIGHT_STATUS.value -> {
                    latestLeftTurnLamp = value.trim().toFloatOrNull()?.toInt() ?: 0
                }
                CarConstants.CAR_BASIC_RIGHT_TURN_LIGHT_STATUS.value -> {
                    latestRightTurnLamp = value.trim().toFloatOrNull()?.toInt() ?: 0
                }
                CarConstants.CAR_BASIC_LEFT_TURN_SWITCH_STATUS.value -> {
                    latestLeftSwitch = value.trim().toFloatOrNull()?.toInt() ?: 0
                }
                CarConstants.CAR_BASIC_RIGHT_TURN_SWITCH_STATUS.value -> {
                    latestRightSwitch = value.trim().toFloatOrNull()?.toInt() ?: 0
                }
                CarConstants.CAR_BASIC_DOOR_STATUS.value -> {
                    // Formato esperado: CSV "FL,FR,RL,RR,Trunk" — 0=fechada, 1=aberta.
                    // O carro emite o CSV envolvido em chaves: "{0,0,0,0,0}". Limpa
                    // qualquer não-dígito (exceto vírgula e sinal) antes de parsear,
                    // se não o primeiro/último elemento ficam grudados com `{`/`}` e
                    // viram 0 (toIntOrNull falha).
                    latestDoorStatusRaw = value
                    val cleaned = value.replace(Regex("[^0-9,\\-]"), "")
                    val parts = cleaned.split(",").mapNotNull { it.trim().toIntOrNull() }
                    if (parts.size >= 4) {
                        latestDoorFl = parts.getOrElse(0) { 0 }
                        latestDoorFr = parts.getOrElse(1) { 0 }
                        latestDoorRl = parts.getOrElse(2) { 0 }
                        latestDoorRr = parts.getOrElse(3) { 0 }
                        latestTrunk  = parts.getOrElse(4) { 0 }
                    }
                }
                CarConstants.CAR_BASIC_WINDOW_STATUS.value -> {
                    // CSV "FL,FR,RL,RR" — cru "1"=fechado, demais valores=aberto.
                    // O carro emite envolvido em chaves: "{1,1,1,1}". Limpa qualquer
                    // não-dígito (exceto vírgula e sinal) antes de parsear — senão o
                    // primeiro/último elemento ficam grudados com `{`/`}` e viram 0.
                    // applyWindowStatus aplica voting filter (K=8 leituras consecutivas)
                    // pra filtrar rajadas de ruído do barramento.
                    latestWindowStatusRaw = value
                    val cleaned = value.replace(Regex("[^0-9,\\-]"), "")
                    val parts = cleaned.split(",").mapNotNull { it.trim().toIntOrNull() }
                    if (parts.size >= 4) {
                        applyWindowStatus(parts[0], parts[1], parts[2], parts[3])
                    }
                }
                CarConstants.CAR_BASIC_SUNROOF_STATUS.value -> {
                    // 0=fechado, >0=aberto (vários estágios)
                    latestSunroof = value.trim().toIntOrNull() ?: 0
                }
                CarConstants.CAR_BASIC_SEAT_BELT_WARNING.value -> {
                    // 0=ok, >0=ocupante sentado sem cinto afivelado
                    latestSeatBeltWarning = value.trim().toIntOrNull() ?: 0
                }
                CarConstants.CAR_BASIC_SEATED_STATE.value -> {
                    // ocupação dos bancos — valor cru (formato a confirmar no teste)
                    latestSeatedState = value.trim()
                }
                // ── Chaves de configuração espelhadas no HA (eram o "listener parcial") ──
                // Não existem branches na CS pra elas; vinham do listener global antigo.
                CarConstants.CAR_EV_SETTING_POWER_MODEL_CONFIG.value -> {
                    val carVal = value.trim().toIntOrNull()
                    if (carVal != null) syncDriveModeFromCar(carVal)
                }
                CarConstants.CAR_EV_SETTING_POWER_RESERVE_CONFIG.value -> {
                    val carVal = value.trim().toIntOrNull()
                    if (carVal != null) syncPowerReserveFromCar(carVal)
                }
                CarConstants.CAR_EV_SETTING_CHARGE_SOC_TARGET_CONFIG.value -> {
                    val carVal = value.trim().toIntOrNull()
                    if (carVal != null) syncSocTargetFromCar(carVal)
                }
                CarConstants.CAR_DRIVE_SETTING_DRIVE_MODE.value -> {
                    val carVal = value.trim().toIntOrNull()
                    if (carVal != null) syncTerrainModeFromCar(carVal)
                }
                CarConstants.CAR_EV_SETTING_ENERGY_RECOVERY_LEVEL.value -> {
                    val carVal = value.trim().toIntOrNull()
                    if (carVal != null) syncRegenLevelFromCar(carVal)
                }
                CarConstants.CAR_EV_SETTING_PEDAL_CONTROL_ENABLE.value -> {
                    val carVal = value.trim().toIntOrNull()
                    if (carVal != null) syncOnePedalFromCar(carVal)
                }
                CarConstants.CAR_DRIVE_SETTING_ESP_ENABLE.value -> {
                    val carVal = value.trim().toIntOrNull()
                    if (carVal != null) syncEspFromCar(carVal)
                }
                CarConstants.CAR_DRIVE_SETTING_STEER_MODE.value -> {
                    val carVal = value.trim().toIntOrNull()
                    if (carVal != null) syncSteerModeFromCar(carVal)
                }
                else -> tripManager.onDataChanged(key, value)
            }
            // Roteamento por tipo de chave:
            //   - IMMEDIATE_PUBLISH_KEYS  → full snapshot na hora
            //   - FAST_LANE_KEYS          → só speed/RPM/power, ~20 Hz (50ms debounce)
            //   - resto                   → full snapshot debounced a 1s
            when (key) {
                in IMMEDIATE_PUBLISH_KEYS -> markChangedImmediate()
                in FAST_LANE_KEYS         -> markChangedFast()
                else                      -> markChanged()
            }
        }

        val connectedListener: () -> Unit = {
            try {
                // Vehicle model — precisa ser lido ANTES do publishDiscovery do MQTT para popular
                // o device JSON. carListener não tem branch pra essas chaves.
                vehicleModel1 = carManager.fetchCurrent(CarConstants.CAR_BASIC_VEHICLE_MODEL1.value)?.trim() ?: ""
                vehicleModel2 = carManager.fetchCurrent(CarConstants.CAR_BASIC_VEHICLE_MODEL2.value)?.trim() ?: ""

                // Startup scan: lê TODAS as chaves do barramento e propaga via carListener.
                // Garante que latest* e tripManager fiquem populados desde o primeiro
                // segundo, sem depender do listener passivo do car bus (que pode demorar
                // para certas chaves chegarem). Toda a lógica per-key (parsing,
                // syncCharging, syncChargeLimitFromCar, onSessionStart, etc.) é reusada
                // via carListener.
                for (key in CarConstants.entries) {
                    if (key == CarConstants.CAR_BASIC_VEHICLE_MODEL1 ||
                        key == CarConstants.CAR_BASIC_VEHICLE_MODEL2) continue  // já lidos acima
                    val v = try { carManager.fetchCurrent(key.value)?.trim() } catch (_: Exception) { null }
                    if (!v.isNullOrEmpty()) carListener(key.value, v)
                }
                // Snapshot completo logo após o scan.
                markChangedImmediate()
            } catch (_: Exception) {}
        }

        carManager.addListener(carListener)
        carManager.addConnectedListener(connectedListener)
        if (carManager.isConnected) connectedListener()
    }

    /** Retorna true se a conexão ativa for WiFi. */
    private fun isWifiConnected(): Boolean {
        val ctx = appContext ?: return false
        val cm  = ctx.getSystemService(ConnectivityManager::class.java) ?: return false
        val caps = cm.getNetworkCapabilities(cm.activeNetwork) ?: return false
        return caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
    }

    /** Coleta IP local v4 do head unit + tipo de conexão pra publicar no bridge. */
    private fun collectNetworkInfo(): JSONObject {
        val info = JSONObject()
        try {
            val ctx = appContext ?: return info
            val cm  = ctx.getSystemService(ConnectivityManager::class.java) ?: return info
            val net = cm.activeNetwork ?: return info
            val caps = cm.getNetworkCapabilities(net)
            val lp   = cm.getLinkProperties(net)
            // Tipo
            val type = when {
                caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true     -> "wifi"
                caps?.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) == true -> "cellular"
                caps?.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) == true -> "ethernet"
                else                                                                -> "other"
            }
            info.put("type", type)
            // IPv4 (prefere)
            val ipv4 = lp?.linkAddresses?.firstOrNull {
                it.address.hostAddress?.contains('.') == true && !it.address.isLoopbackAddress
            }?.address?.hostAddress
            if (ipv4 != null) info.put("ip", ipv4)
            // Velocidade
            if (caps != null) {
                val down = caps.linkDownstreamBandwidthKbps
                if (down > 0) info.put("downlink_kbps", down)
            }
            info.put("ts", System.currentTimeMillis())
        } catch (e: Exception) {
            AppLogger.w(TAG, "collectNetworkInfo: ${e.message}")
        }
        return info
    }

    /** Publica info de rede do carro em `network/info` (retained) — o PWA lê via bridge. */
    private fun publishNetworkInfo() {
        val c = client ?: return
        if (!c.isConnected) return
        try {
            val info = collectNetworkInfo()
            if (info.length() > 0) {
                c.publish("$prefix/network/info", info.toString().toByteArray(), 1, true)
            }
        } catch (e: Exception) {
            AppLogger.w(TAG, "publishNetworkInfo falhou: ${e.message}")
        }
    }

    fun saveAndApply() {
        prefs.edit()
            .putBoolean(SharedPreferencesKeys.MQTT_ENABLED,                     enabled)
            .putString (SharedPreferencesKeys.MQTT_HOST,                        host)
            .putInt    (SharedPreferencesKeys.MQTT_PORT,                        port)
            .putString (SharedPreferencesKeys.MQTT_USERNAME,                    username)
            // senha NÃO vai aqui — vai pro storage criptografado (_saveSecurePassword)
            .putBoolean(SharedPreferencesKeys.MQTT_TLS,                         tls)
            .putBoolean(SharedPreferencesKeys.MQTT_PAIRED,                      paired)
            .putString (SharedPreferencesKeys.MQTT_PREFIX,                      prefix)
            .putString (SharedPreferencesKeys.BRIDGE_URL,                       bridgeUrl)
            .putString (SharedPreferencesKeys.BRIDGE_TOKEN,                     bridgeToken)
            .putInt    (SharedPreferencesKeys.MQTT_PUBLISH_INTERVAL_WIFI_MS,     publishIntervalWifiMs)
            .putInt    (SharedPreferencesKeys.MQTT_PUBLISH_INTERVAL_CELLULAR_MS, publishIntervalCellularMs)
            .apply()
        _saveSecurePassword(password)

        executor.submit {
            client?.let { safeDisconnect(it) }
            client = null
            if (enabled && host.isNotEmpty()) connectInternal()
            else setStatus(Status.DISCONNECTED)
        }
    }

    // ── Storage seguro da senha (EncryptedSharedPreferences / Keystore) ───────────
    private val securePrefs: android.content.SharedPreferences? by lazy {
        try {
            val ctx = appContext ?: return@lazy null
            val mk = androidx.security.crypto.MasterKey.Builder(ctx)
                .setKeyScheme(androidx.security.crypto.MasterKey.KeyScheme.AES256_GCM).build()
            androidx.security.crypto.EncryptedSharedPreferences.create(
                ctx, "mqtt_secure", mk,
                androidx.security.crypto.EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                androidx.security.crypto.EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM)
        } catch (e: Exception) { AppLogger.w(TAG, "EncryptedSharedPreferences indisponível: ${e.message}"); null }
    }
    private fun _saveSecurePassword(p: String) {
        val sp = securePrefs
        if (sp != null) {
            sp.edit().putString("mqtt_password", p).apply()
            prefs.edit().remove(SharedPreferencesKeys.MQTT_PASSWORD).apply()   // limpa qualquer resíduo plaintext
        } else {
            prefs.edit().putString(SharedPreferencesKeys.MQTT_PASSWORD, p).apply()   // fallback
        }
    }
    private fun _loadSecurePassword(): String {
        val sp = securePrefs
        sp?.getString("mqtt_password", null)?.let { return it }
        // migração: senha antiga no prefs plano → move pro seguro e limpa
        val old = prefs.getString(SharedPreferencesKeys.MQTT_PASSWORD, "") ?: ""
        if (old.isNotEmpty() && sp != null) {
            sp.edit().putString("mqtt_password", old).apply()
            prefs.edit().remove(SharedPreferencesKeys.MQTT_PASSWORD).apply()
        }
        return old
    }

    // ── Pareamento: aplica a config vinda do bridge (sem digitar/ver credenciais) ──
    // bridgeUrl/bridgeToken (opcionais — quando vazios, mantém o que ja estava
    // nas prefs). São usados pelo TripManager pra fazer POST /api/autotrips
    // no fim da viagem (rota HTTP, separada do MQTT).
    // BUG corrigido v5.60: precisa atualizar MEMBROS DA CLASSE this.bridgeUrl/
    // this.bridgeToken ANTES de chamar saveAndApply(), senão saveAndApply
    // sobrescreve as prefs com o valor antigo (vazio).
    fun applyPairedConfig(carHost: String, port: Int, username: String, password: String,
                          prefix: String, tls: Boolean,
                          bridgeUrlNew: String = "", bridgeTokenNew: String = "") {
        this.host = carHost; this.port = port; this.username = username
        this.password = password; this.prefix = prefix.ifEmpty { "haval/ecotrip" }; this.tls = tls
        this.enabled = true; this.paired = true
        if (bridgeUrlNew.isNotBlank())   this.bridgeUrl   = bridgeUrlNew.trimEnd('/')
        if (bridgeTokenNew.isNotBlank()) this.bridgeToken = bridgeTokenNew
        saveAndApply()   // agora vai persistir os novos bridgeUrl/bridgeToken corretamente
    }

    // Desparear: apaga as credenciais (inclusive a criptografada) e volta ao estado
    // não-pareado (a tela mostra o campo de código de novo).
    fun unpair() {
        paired = false; host = ""; username = ""; password = ""
        securePrefs?.edit()?.remove("mqtt_password")?.apply()
        prefs.edit()
            .putBoolean(SharedPreferencesKeys.MQTT_PAIRED, false)
            .remove(SharedPreferencesKeys.MQTT_PASSWORD)
            .putString(SharedPreferencesKeys.MQTT_HOST, "")
            .putString(SharedPreferencesKeys.MQTT_USERNAME, "")
            .apply()
        executor.submit { client?.let { safeDisconnect(it) }; client = null; setStatus(Status.DISCONNECTED) }
    }

    // POST <base>/api/pair/redeem {code} → aplica. onResult chamado no main thread.
    fun pairWithCode(base: String, code: String, onResult: (Boolean, String) -> Unit) {
        executor.submit {
            val res: Pair<Boolean, String> = try {
                val b = base.trim().trimEnd('/')
                val conn = (java.net.URL("$b/api/pair/redeem").openConnection() as java.net.HttpURLConnection).apply {
                    requestMethod = "POST"; doOutput = true
                    setRequestProperty("Content-Type", "application/json")
                    connectTimeout = 15000; readTimeout = 15000
                }
                conn.outputStream.use { it.write("{\"code\":\"${code.trim().uppercase()}\"}".toByteArray()) }
                val rc = conn.responseCode
                if (rc !in 200..299) {
                    Pair(false, if (rc == 404) "Código inválido ou expirado" else "Erro $rc")
                } else {
                    val body = conn.inputStream.bufferedReader().use { it.readText() }
                    val cfg = org.json.JSONObject(body).getJSONObject("config")
                    applyPairedConfig(
                        cfg.optString("mqtt_host"), cfg.optInt("mqtt_port", 1883),
                        cfg.optString("mqtt_user"), cfg.optString("mqtt_pass"),
                        cfg.optString("mqtt_prefix", "haval/ecotrip"), cfg.optBoolean("mqtt_tls", false),
                        cfg.optString("bridge_url", ""),
                        cfg.optString("bridge_token", ""))
                    Pair(true, "Pareado com sucesso ✓")
                }
            } catch (e: Exception) { Pair(false, "Falha: ${e.message}") }
            android.os.Handler(android.os.Looper.getMainLooper()).post { onResult(res.first, res.second) }
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
        val interval = if (hfModeActive) HF_MODE_INTERVAL_MS
                       else if (isWifiConnected()) publishIntervalWifiMs
                       else publishIntervalCellularMs
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

    /**
     * Sync drive_mode carro → HA. Valores: 0=HEV, 1=Prior. EV, 3=EV puro.
     * Idempotente (não republica se valor não mudou).
     */
    fun syncDriveModeFromCar(carVal: Int) {
        if (carVal !in setOf(0, 1, 3)) {
            Log.w(TAG, "syncDriveModeFromCar: valor inesperado carVal=$carVal, ignorado")
            return
        }
        if (carVal == lastPublishedDriveMode) {
            Log.d(TAG, "Drive mode sem mudança ($carVal) — HA já atualizado")
            return
        }
        AppLogger.i(TAG, "Carro reportou drive_mode=$carVal (HA tinha $lastPublishedDriveMode) — atualizando HA")
        publishDriveModeState(carVal)
    }

    fun publishDriveModeState(mode: Int) {
        if (mode !in setOf(0, 1, 3)) {
            Log.w(TAG, "publishDriveModeState: mode=$mode inválido, ignorado")
            return
        }
        try {
            client?.publish("$prefix/ha/drive_mode/state", mode.toString().toByteArray(), 1, true)
            lastPublishedDriveMode = mode
            AppLogger.i(TAG, "Drive mode publicado no HA: $mode")
        } catch (e: Exception) {
            Log.w(TAG, "publishDriveModeState falhou: ${e.message}")
        }
    }

    /** Sub-modo HEV: 1=Inteligente, 2=Prioritário. */
    fun syncPowerReserveFromCar(carVal: Int) {
        if (carVal !in setOf(1, 2)) {
            Log.w(TAG, "syncPowerReserveFromCar: valor inesperado carVal=$carVal, ignorado")
            return
        }
        if (carVal == lastPublishedPowerReserve) return
        AppLogger.i(TAG, "Carro reportou power_reserve=$carVal — atualizando HA")
        publishPowerReserveState(carVal)
    }

    fun publishPowerReserveState(mode: Int) {
        if (mode !in setOf(1, 2)) return
        try {
            client?.publish("$prefix/ha/power_reserve/state", mode.toString().toByteArray(), 1, true)
            lastPublishedPowerReserve = mode
            AppLogger.i(TAG, "Power reserve publicado no HA: $mode")
        } catch (e: Exception) {
            Log.w(TAG, "publishPowerReserveState falhou: ${e.message}")
        }
    }

    /** Alvo de SOC no modo Prioritário HEV: 20..80 (%). */
    fun syncSocTargetFromCar(carVal: Int) {
        if (carVal !in 20..80) {
            Log.w(TAG, "syncSocTargetFromCar: valor fora da faixa carVal=$carVal, ignorado")
            return
        }
        if (carVal == lastPublishedSocTarget) return
        AppLogger.i(TAG, "Carro reportou soc_target=${carVal}% — atualizando HA")
        publishSocTargetState(carVal)
    }

    fun publishSocTargetState(pct: Int) {
        if (pct !in 20..80) return
        try {
            client?.publish("$prefix/ha/charge_soc_target/state", pct.toString().toByteArray(), 1, true)
            lastPublishedSocTarget = pct
            AppLogger.i(TAG, "Soc target publicado no HA: $pct%")
        } catch (e: Exception) {
            Log.w(TAG, "publishSocTargetState falhou: ${e.message}")
        }
    }

    // ── Terrain mode (car.drive_setting.drive_mode) ──────────────────────────
    fun syncTerrainModeFromCar(carVal: Int) {
        if (carVal !in setOf(0, 1, 2, 3, 4, 5, 11)) return
        if (carVal == lastPublishedTerrainMode) return
        AppLogger.i(TAG, "Carro reportou terrain_mode=$carVal — atualizando HA")
        publishTerrainModeState(carVal)
    }

    fun publishTerrainModeState(mode: Int) {
        if (mode !in setOf(0, 1, 2, 3, 4, 5, 11)) return
        try {
            client?.publish("$prefix/ha/terrain_mode/state", mode.toString().toByteArray(), 1, true)
            lastPublishedTerrainMode = mode
            AppLogger.i(TAG, "Terrain mode publicado: $mode")
        } catch (e: Exception) { Log.w(TAG, "publishTerrainModeState falhou: ${e.message}") }
    }

    // ── Regen level (car.ev_setting.energy_recovery_level) ───────────────────
    fun syncRegenLevelFromCar(carVal: Int) {
        if (carVal !in setOf(0, 1, 2)) return
        if (carVal == lastPublishedRegenLevel) return
        AppLogger.i(TAG, "Carro reportou regen_level=$carVal — atualizando HA")
        publishRegenLevelState(carVal)
    }

    fun publishRegenLevelState(level: Int) {
        if (level !in setOf(0, 1, 2)) return
        try {
            client?.publish("$prefix/ha/regen_level/state", level.toString().toByteArray(), 1, true)
            lastPublishedRegenLevel = level
            AppLogger.i(TAG, "Regen level publicado: $level")
        } catch (e: Exception) { Log.w(TAG, "publishRegenLevelState falhou: ${e.message}") }
    }

    // ── One-pedal (car.ev.setting.pedal_control_enable) ───────────────────────
    fun syncOnePedalFromCar(carVal: Int) {
        if (carVal !in setOf(0, 1)) return
        if (carVal == lastPublishedOnePedal) return
        AppLogger.i(TAG, "Carro reportou one_pedal=$carVal — atualizando HA")
        publishOnePedalState(carVal)
    }

    fun publishOnePedalState(enable: Int) {
        if (enable !in setOf(0, 1)) return
        try {
            client?.publish("$prefix/ha/one_pedal/state", enable.toString().toByteArray(), 1, true)
            lastPublishedOnePedal = enable
            AppLogger.i(TAG, "One-pedal publicado: $enable")
        } catch (e: Exception) { Log.w(TAG, "publishOnePedalState falhou: ${e.message}") }
    }

    // ── Regen power real-time (car.ev_info.energy_output_percentage) ─────────
    // Sem retain — dado em tempo real, não faz sentido armazenar no broker.
    // Valor negativo = regenerando; positivo = consumindo. Publicamos o valor bruto.
    private fun publishRegenPower(value: Float) {
        try {
            client?.publish("$prefix/ha/regen_power/state", value.toString().toByteArray(), 0, false)
        } catch (_: Exception) {}
    }

    // ── ESP (car.drive_setting.esp_enable) ────────────────────────────────────
    fun syncEspFromCar(carVal: Int) {
        if (carVal !in setOf(0, 1)) return
        if (carVal == lastPublishedEsp) return
        AppLogger.i(TAG, "Carro reportou esp=$carVal — atualizando HA")
        publishEspState(carVal)
    }

    fun publishEspState(enable: Int) {
        if (enable !in setOf(0, 1)) return
        try {
            client?.publish("$prefix/ha/esp/state", enable.toString().toByteArray(), 1, true)
            lastPublishedEsp = enable
            AppLogger.i(TAG, "ESP publicado: $enable")
        } catch (e: Exception) { Log.w(TAG, "publishEspState falhou: ${e.message}") }
    }

    // ── Steer mode (car.drive_setting.steering_wheel_assist_mode) ────────────
    fun syncSteerModeFromCar(carVal: Int) {
        if (carVal !in setOf(0, 1, 2)) return
        if (carVal == lastPublishedSteerMode) return
        AppLogger.i(TAG, "Carro reportou steer_mode=$carVal — atualizando HA")
        publishSteerModeState(carVal)
    }

    fun publishSteerModeState(mode: Int) {
        if (mode !in setOf(0, 1, 2)) return
        try {
            client?.publish("$prefix/ha/steer_mode/state", mode.toString().toByteArray(), 1, true)
            lastPublishedSteerMode = mode
            AppLogger.i(TAG, "Steer mode publicado: $mode")
        } catch (e: Exception) { Log.w(TAG, "publishSteerModeState falhou: ${e.message}") }
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
            val serverUri = if (tls) "ssl://$cleanedHost:$port" else "tcp://$cleanedHost:$port"
            Log.i(TAG, "Connecting to $serverUri")
            val c = MqttClient(serverUri, CLIENT_ID + "_${System.currentTimeMillis() % 10000}", MemoryPersistence())

            c.setCallback(object : MqttCallback {
                override fun connectionLost(cause: Throwable?) {
                    Log.w(TAG, "Connection lost: ${cause?.message}")
                    heartbeatFuture?.cancel(false)
                    heartbeatFuture = null
                    setStatus(Status.DISCONNECTED)
                    scheduleReconnect()
                }
                override fun messageArrived(topic: String, message: MqttMessage) {
                    handleIncomingCommand(topic, message.toString())
                }
                override fun deliveryComplete(token: IMqttDeliveryToken) {}
            })

            val opts = MqttConnectOptions().apply {
                connectionTimeout    = 10   // Starlink: latência baixa; falha logo se cair
                keepAliveInterval    = 10   // 4G+TLS+cellular pode ter jitter; 1.5×=15s timeout. Heartbeat 5s do app faz a detecção rápida real
                isCleanSession       = true
                isAutomaticReconnect = false
                if (username.isNotEmpty()) {
                    userName = username
                    password = this@MqttManager.password.toCharArray()
                }
                if (tls) {
                    // Broker público com TLS: confia nas CAs do sistema (ex. Let's Encrypt).
                    socketFactory = javax.net.ssl.SSLSocketFactory.getDefault()
                }
                setWill("$prefix/status", "offline".toByteArray(), 1, true)
            }

            c.connect(opts)
            c.publish("$prefix/status", MqttMessage("online".toByteArray()).apply { qos = 1; isRetained = true })
            c.subscribe("$prefix/cmd/#", 1)
            client = c
            consecutiveFailures = 0
            reconnectAttempts = 0   // conectou → zera o backoff de reconexão
            lastPubSnapshot.clear()           // dedupe do snapshot: força re-publish completo na primeira rodada
            lastPublishedChargeLimitPct = -1  // força re-sync com o carro após reconexão
            lastPublishedDriveMode = -1       // idem pro modo de condução
            lastPublishedPowerReserve = -1    // sub-modo HEV
            lastPublishedSocTarget = -1       // alvo SOC prioritário
            lastPublishedTerrainMode = -1
            lastPublishedRegenLevel = -1
            lastPublishedOnePedal = -1
            lastPublishedEsp = -1
            lastPublishedSteerMode = -1
            setStatus(Status.CONNECTED)
            // Heartbeat 5s — pequena publicação fire-and-forget pra manter TCP
            // ativo + a métrica de uptime do bridge enxergar tráfego constante.
            // Se a publish falhar, Paho dispara connectionLost imediatamente.
            heartbeatFuture?.cancel(false)
            heartbeatFuture = fastExecutor.scheduleAtFixedRate({
                try {
                    val cur = client
                    if (cur != null && cur.isConnected) {
                        cur.publish("$prefix/heartbeat", System.currentTimeMillis().toString().toByteArray(), 0, false)
                    }
                } catch (e: Exception) {
                    AppLogger.w(TAG, "heartbeat falhou: ${e.message}")
                }
            }, 5, 5, java.util.concurrent.TimeUnit.SECONDS)
            publishDiscovery(c)
            // Publica disparos do motor de automações pro bridge/app verem (log).
            AutomationManager.onFired = { id, name, ok ->
                try {
                    val p = JSONObject().put("id", id).put("name", name).put("ok", ok)
                        .put("ts", System.currentTimeMillis())
                    client?.publish("$prefix/rules/fired", p.toString().toByteArray(), 1, false)
                } catch (_: Exception) {}
            }
            // Publica versão do app com retain=true — sempre visível no HA mesmo offline
            try {
                c.publish("$prefix/app_version", BuildConfig.VERSION_NAME.toByteArray(), 1, true)
                AppLogger.i(TAG, "Versão publicada: ${BuildConfig.VERSION_NAME}")
            } catch (e: Exception) {
                AppLogger.w(TAG, "Falha ao publicar versão: ${e.message}")
            }
            drainQueues(c)
            AppLogger.i(TAG, "MQTT conectado: $serverUri")
            // Publica info de rede do head unit (IP local v4 + tipo) pra PWA
            // mostrar no modal de rede. Retained — fica disponível mesmo se
            // carro estiver dormindo.
            try { publishNetworkInfo() } catch (_: Exception) {}
            // Leitura inicial de charge_soc_limit ~7s após conectar — garante
            // sincronia inicial mesmo se o user mudou o valor direto no carro
            // enquanto o app estava parado (evento perdido).
            executor.submit {
                Thread.sleep(7_000)
                try {
                    val readBack = CarDataManager.getInstance().fetchCurrent("car.ev_setting.charge_soc_limit_config")?.trim()
                    val carVal = readBack?.toIntOrNull()
                    if (carVal != null) {
                        AppLogger.i(TAG, "Leitura inicial charge_limit: carVal=$carVal — sincronizando")
                        syncChargeLimitFromCar(carVal)
                    }
                } catch (e: Exception) {
                    AppLogger.w(TAG, "Leitura inicial charge_limit falhou: ${e.message}")
                }
                // Leitura inicial do drive_mode também
                try {
                    val readBack = CarDataManager.getInstance().fetchCurrent("car.ev_setting.power_model_config")?.trim()
                    val carVal = readBack?.toIntOrNull()
                    if (carVal != null) {
                        AppLogger.i(TAG, "Leitura inicial drive_mode: carVal=$carVal — sincronizando")
                        syncDriveModeFromCar(carVal)
                    }
                } catch (e: Exception) {
                    AppLogger.w(TAG, "Leitura inicial drive_mode falhou: ${e.message}")
                }
                // Sub-modos HEV
                try {
                    val readBack = CarDataManager.getInstance().fetchCurrent("car.ev_setting.power_reserve_config")?.trim()
                    val carVal = readBack?.toIntOrNull()
                    if (carVal != null) syncPowerReserveFromCar(carVal)
                } catch (e: Exception) { AppLogger.w(TAG, "Leitura inicial power_reserve falhou: ${e.message}") }
                try {
                    val readBack = CarDataManager.getInstance().fetchCurrent("car.ev_setting.charge_soc_target_config")?.trim()
                    val carVal = readBack?.toIntOrNull()
                    if (carVal != null) syncSocTargetFromCar(carVal)
                } catch (e: Exception) { AppLogger.w(TAG, "Leitura inicial soc_target falhou: ${e.message}") }
                // Leitura inicial de terrain_mode, regen_level, one_pedal, esp, steer_mode
                try {
                    val v = CarDataManager.getInstance().fetchCurrent("car.drive_setting.drive_mode")?.trim()?.toIntOrNull()
                    if (v != null) syncTerrainModeFromCar(v)
                } catch (e: Exception) { AppLogger.w(TAG, "Leitura inicial terrain_mode falhou: ${e.message}") }
                try {
                    val v = CarDataManager.getInstance().fetchCurrent("car.ev_setting.energy_recovery_level")?.trim()?.toIntOrNull()
                    if (v != null) syncRegenLevelFromCar(v)
                } catch (e: Exception) { AppLogger.w(TAG, "Leitura inicial regen_level falhou: ${e.message}") }
                try {
                    val v = CarDataManager.getInstance().fetchCurrent("car.ev.setting.pedal_control_enable")?.trim()?.toIntOrNull()
                    if (v != null) syncOnePedalFromCar(v)
                } catch (e: Exception) { AppLogger.w(TAG, "Leitura inicial one_pedal falhou: ${e.message}") }
                try {
                    val v = CarDataManager.getInstance().fetchCurrent("car.drive_setting.esp_enable")?.trim()?.toIntOrNull()
                    if (v != null) syncEspFromCar(v)
                } catch (e: Exception) { AppLogger.w(TAG, "Leitura inicial esp falhou: ${e.message}") }
                try {
                    val v = CarDataManager.getInstance().fetchCurrent("car.drive_setting.steering_wheel_assist_mode")?.trim()?.toIntOrNull()
                    if (v != null) syncSteerModeFromCar(v)
                } catch (e: Exception) { AppLogger.w(TAG, "Leitura inicial steer_mode falhou: ${e.message}") }
            }
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

        // Publica histórico de abastecimentos como retained após reconexão
        try {
            val refuels = TripManager.getInstance().getRefuelHistory()
            if (refuels.isNotEmpty()) {
                AppLogger.i(TAG, "Republicando histórico de abastecimentos após reconexão: ${refuels.size} registro(s)")
                publishRefuelHistoryInternal(c, refuels)
            }
        } catch (e: Exception) {
            AppLogger.w(TAG, "drainQueues: falha ao publicar abastecimentos: ${e.message}")
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
            val snWinFlMs = latestWindowFlConfirmedMs;   val snWinFrMs = latestWindowFrConfirmedMs
            val snWinRlMs = latestWindowRlConfirmedMs;   val snWinRrMs = latestWindowRrConfirmedMs
            val snSunroof   = latestSunroof
            val snLockStat  = latestLockStatus
            val snLockMs    = latestLockConfirmedMs
            val snAcEnable  = latestHvacAcEnable
            val snDrvReady  = latestDrivingReadyState
            val snDoorRaw   = latestDoorStatusRaw
            val snWinRaw    = latestWindowStatusRaw
            val snEngineRpm = latestEngineRpm

            fun pub(topic: String, value: String) =
                c.publish("$prefix/$topic", value.toByteArray(), 0, false)
            fun pubR(topic: String, value: String) =   // retained — para sensores que devem sobreviver a reinício do HA
                c.publish("$prefix/$topic", value.toByteArray(), 0, true)
            // Dedupe: só publica se o valor mudou. Reseta no reconnect (re-publica tudo).
            // Qualquer mudança real (porta fecha→abre, vidro, sunroof, trava, RPM, temp) sai
            // imediatamente. Reduz tráfego de portas/vidros/etc. em ordem de magnitude.
            fun pubD(topic: String, value: String, retained: Boolean = true) {
                if (lastPubSnapshot[topic] == value) return
                lastPubSnapshot[topic] = value
                c.publish("$prefix/$topic", value.toByteArray(), 0, retained)
            }
            fun fmt2(v: Float) = String.format(java.util.Locale.US, "%.2f", v)
            fun fmt3(v: Float) = String.format(java.util.Locale.US, "%.3f", v)
            fun fmt1(v: Float) = String.format(java.util.Locale.US, "%.1f", v)

            pub("speed_kmh",             fmt1(latestSpeedKmh))
            pubD("inside_temp",  fmt1(latestInsideTemp),  retained = false)
            pubD("outside_temp", fmt1(latestOutsideTemp), retained = false)
            if (latestGear.isNotEmpty()) pubD("gear", latestGear, retained = false)

            // GPS — publica apenas quando há sinal válido (≠ 0.0)
            val (gpsLat, gpsLng) = TripManager.getInstance().getLastGps()
            if (gpsLat != 0.0 && gpsLng != 0.0) {
                pubR("gps_lat", String.format(java.util.Locale.US, "%.6f", gpsLat))
                pubR("gps_lng", String.format(java.util.Locale.US, "%.6f", gpsLng))
            }

            // SOC do carro (CAN: CAR_EV_INFO_SOC_OF_BATTERY) — fonte primária pro bridge.
            // Mesmo tópico que a automação HA usa; APK publica mais frequente, então
            // o valor MAIS FRESCO sempre vence. Quando carro está parado, HA atualiza
            // (5s) e cobre o gap. Guard >0 evita publicar 0 antes do CAN inicializar.
            val socNow = q.rolling.currentSocPct
            if (socNow > 0f) { pubD("soc_pct", socNow.toInt().toString()); latestSocPct = socNow }

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
            pubD("engine_rpm",        latestEngineRpm.toString())
            pubD("seat_vent_drv",     latestDriverSeatVent.toString())
            pubD("seat_vent_pass",    latestPassengerSeatVent.toString())
            pubD("hvac_driver_temp",     fmt1(latestHvacDriverTemp))
            pubD("hvac_passenger_temp",  fmt1(latestHvacPassengerTemp))
            pubD("hvac_fan_speed",    latestHvacFanSpeed.toString())
            pubD("hvac_sync_enable",  latestHvacSyncEnable.toString())
            pubD("hvac_auto_enable",  latestHvacAutoEnable.toString())
            pubD("hvac_ac_enable",    latestHvacAcEnable.toString())  // master ON/OFF do AC
            pubD("hvac_cycle_mode",   latestHvacCycleMode.toString())
            pubD("hvac_acmax",         latestHvacAcMax.toString())
            pubD("hvac_anion",         latestHvacAnion.toString())
            pubD("hvac_aqs",           latestHvacAqs.toString())
            pubD("hvac_heating",       latestHvacHeating.toString())
            pubD("hvac_front_defrost", latestHvacFrontDefrost.toString())
            pubD("hvac_rear_defrost",  latestHvacRearDefrost.toString())
            pubD("hvac_auto_defrost",  latestHvacAutoDefrost.toString())
            pubD("hvac_pm25",          latestHvacPm25.toString())
            pubD("hvac_blower_mode",   latestHvacBlowerMode.toString())
            pubD("hvac_power_mode",    latestHvacPowerMode.toString())
            pubD("seat_belt_warning",  latestSeatBeltWarning.toString())
            pubD("seated_state",       latestSeatedState)

            // ── MIGRATED_TO_HA ────────────────────────────────────────────────
            // O bridge IGNORA publishes do carro para: door_*, window_*, sunroof,
            // lock_state, ac_state, engine_state (usa integração GWM Brasil em vez).
            // Stopamos de publicar — economiza banda + simplifica. Os valores
            // latestDoorFl/etc. continuam rastreados internamente pra UI do carro.
            // Mantemos os debug/* (diagnóstico — valores CRUS do CAN antes do parse).
            // Debug — valores crus do barramento + resultado do parsing (sem afetar lógica)
            if (snDoorRaw.isNotEmpty()) {
                pubD("debug/door_status_raw", snDoorRaw)
                pubD("debug/door_parsed",     "$snDoorFl,$snDoorFr,$snDoorRl,$snDoorRr,$snTrunk")
            }
            if (snWinRaw.isNotEmpty()) {
                pubD("debug/window_status_raw", snWinRaw)
                pubD("debug/window_parsed",     "$snWinFl,$snWinFr,$snWinRl,$snWinRr")
            }
            pubD("debug/sunroof_raw",      snSunroof.toString())
            pubD("debug/lock_status_raw",  snLockStat.toString())
            pubD("debug/front_light_raw",  latestFrontLight.toString())
            pubD("debug/turn_left",  "lamp=$latestLeftTurnLamp sw=$latestLeftSwitch", retained = false)
            pubD("debug/turn_right", "lamp=$latestRightTurnLamp sw=$latestRightSwitch", retained = false)
            // odometer_km e batt_12v_pct movidos pra GWM Brasil (MIGRATED_TO_HA) — bridge ignora.
            // Potência de recarga: apenas quando charging_state == 1 (Carregando)
            // Corrente AC (cur_charge_current) × tensão do pack (car.ev_info.power_battery_voltage) / 1000
            val chargePowerKw = if (latestChargingState == 1 && latestBatteryVoltageV > 0f)
                kotlin.math.abs(latestChargeCurrentA) * latestBatteryVoltageV / 1000f else 0f
            pubR("charge_power_kw",   fmt2(chargePowerKw))
            // charging_state e charge_remaining_min movidos pra GWM Brasil (MIGRATED_TO_HA).
            pubD("charge_session_kwh",   fmt2(TripManager.getInstance().getChargeSessionEnergyKwh()))
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
            // Custo lifetime — usa defaults internos. Cálculo definitivo é feito
            // no bridge a partir do mix ponderado de abastecimentos/recargas.
            val ltPriceGas    = prefs.getFloat(SharedPreferencesKeys.PRICE_GASOLINE_PER_L, 6.5f)
            val ltPriceEnergy = prefs.getFloat(SharedPreferencesKeys.PRICE_ENERGY_PER_KWH, 0.55f)
            val ltCostBrl     = lt.fuelL * ltPriceGas + lt.netKwh.coerceAtLeast(0f) * ltPriceEnergy
            pubR("lifetime/cost_brl", fmt2(ltCostBrl))
            // price_gas_per_l e price_kwh NÃO são mais publicados — bridge ignora e
            // mantém o cálculo via mix de abastecimentos/recargas registrados no PWA.

            // ── Viagem em andamento ──────────────────────────────────────────────
            // Publica como retained pra sobreviver a desconexão: se o carro atingiu
            // 140 km/h offline, ao reconectar o broker entrega o último valor ao bridge.
            // Quando a viagem termina, publica payload vazio (limpa o retain).
            val inProgress = TripManager.getInstance().getInProgressAutoTrip()
            if (inProgress != null) {
                val avgKmh = if (inProgress.timeSec > 0)
                    inProgress.distKm / (inProgress.timeSec / 3600f) else 0f
                val avgPwrKw = if (inProgress.timeSec > 0)
                    inProgress.netKwh / (inProgress.timeSec / 3600f) else 0f
                val payload = """{"startMs":${inProgress.startMs},"distKm":${fmt3(inProgress.distKm)},"timeSec":${inProgress.timeSec},"parkedInPSec":${inProgress.parkedInPSec},"engineOffSec":${inProgress.engineOffSec},"maxSpeedKmh":${fmt1(inProgress.maxSpeedKmh)},"avgSpeedKmh":${fmt1(avgKmh)},"netKwh":${fmt3(inProgress.netKwh)},"fuelL":${fmt3(inProgress.fuelL)},"avgPowerKw":${fmt2(avgPwrKw)},"startSocPct":${fmt1(inProgress.startSocPct)},"currentSocPct":${fmt1(inProgress.endSocPct)}}"""
                c.publish("$prefix/current_trip", payload.toByteArray(), 1, true)
            } else {
                // Sem viagem ativa — limpa o retain (payload vazio + retain=true).
                c.publish("$prefix/current_trip", ByteArray(0), 1, true)
            }

            // Drive settings — o carro não faz push via listener para essas chaves;
            // poll ativo a cada ciclo garante que mudanças feitas no carro reflitam no app.
            val cdm = CarDataManager.getInstance()
            try { cdm.fetchCurrent("car.drive_setting.drive_mode")?.trim()?.toIntOrNull()?.let { syncTerrainModeFromCar(it) } } catch (_: Exception) {}
            try { cdm.fetchCurrent("car.ev_setting.energy_recovery_level")?.trim()?.toIntOrNull()?.let { syncRegenLevelFromCar(it) } } catch (_: Exception) {}
            try { cdm.fetchCurrent("car.ev.setting.pedal_control_enable")?.trim()?.toIntOrNull()?.let { syncOnePedalFromCar(it) } } catch (_: Exception) {}
            try { cdm.fetchCurrent("car.drive_setting.esp_enable")?.trim()?.toIntOrNull()?.let { syncEspFromCar(it) } } catch (_: Exception) {}
            try { cdm.fetchCurrent("car.drive_setting.steering_wheel_assist_mode")?.trim()?.toIntOrNull()?.let { syncSteerModeFromCar(it) } } catch (_: Exception) {}
            // car.hvac.power_mode (mestre do AC) não vem por push confiável — poll ativo
            // garante valor estável no LAN e no cloud (corrige PWA "desligado" + flicker iPad).
            try { cdm.fetchCurrent("car.hvac.power_mode")?.trim()?.toIntOrNull()?.let { latestHvacPowerMode = it } } catch (_: Exception) {}

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

    // Trip A/B descontinuado — publishTripHistory virou no-op.
    // Bridge ignora "trips/history" e os tópicos "trip_a" e "trip_b".
    @Suppress("UNUSED_PARAMETER")
    fun publishTripHistory(entries: List<TripHistoryEntry>) {}

    @Suppress("UNUSED_PARAMETER")
    private fun publishTripHistoryInternal(c: MqttClient, entries: List<TripHistoryEntry>) {}

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

    // ── Refuel history ────────────────────────────────────────────────────────

    fun publishRefuelHistory(entries: List<RefuelEntry>) {
        if (entries.isEmpty()) return
        val c = client
        if (c == null || !c.isConnected) {
            AppLogger.w(TAG, "publishRefuelHistory: offline, não publicado agora")
            return
        }
        executor.submit { publishRefuelHistoryInternal(c, entries) }
    }

    private fun publishRefuelHistoryInternal(c: MqttClient, entries: List<RefuelEntry>) {
        try {
            val fmt = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.getDefault())
            fun f1(v: Float) = String.format(java.util.Locale.US, "%.1f", v)
            fun f2(v: Float) = String.format(java.util.Locale.US, "%.2f", v)
            val refuelsJson = entries.joinToString(",") { e ->
                val ts = fmt.format(Date(e.timestampMs))
                """{"timestamp":"$ts","timestamp_ms":${e.timestampMs},"fuel_l_before":${f2(e.fuelLBefore)},"fuel_l_after":${f2(e.fuelLAfter)},"liters_added":${f2(e.litersAdded)},"odometer_km":${f1(e.odometerKm)},"price_per_liter":${f2(e.pricePerLiter)}}"""
            }
            val payload = """{"count":${entries.size},"refuels":[$refuelsJson]}"""
            AppLogger.i(TAG, "→ Publicando histórico de abastecimentos (QoS 1, retained): $prefix/refuels/history")
            c.publish("$prefix/refuels/history", payload.toByteArray(), 1, true)
            AppLogger.i(TAG, "✓ Histórico de abastecimentos publicado: ${entries.size} registro(s)")
        } catch (e: Exception) {
            AppLogger.e(TAG, "✗ Abastecimentos FALHOU: ${e::class.simpleName}: ${e.message}")
        }
    }

    // Backoff escalonado: Starlink/4G recuperam quase na hora — a primeira
    // tentativa em 250ms quase sempre cola. Se o broker estiver fora de vez,
    // espaça pra não martelar.
    //   tentativas 1–3    → 250ms (Starlink/WiFi blip)
    //   tentativas 4–8    → 500ms
    //   tentativas 9–18   → 1s
    //   19ª em diante     → 3s
    private fun reconnectDelayMs(): Long = when {
        reconnectAttempts <= 3  -> 250L
        reconnectAttempts <= 8  -> 500L
        reconnectAttempts <= 18 -> 1_000L
        else                    -> 3_000L
    }

    private fun scheduleReconnect() {
        if (!enabled || isReconnecting.getAndSet(true)) return
        executor.submit {
            reconnectAttempts++
            Thread.sleep(reconnectDelayMs())
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

    /**
     * IDs cuja fonte de verdade migrou pra integração GWM Brasil no HA.
     * No discovery publicamos payload vazio nesses tópicos para que o HA
     * REMOVA as entidades antigas que duplicavam o que agora vem do GWM.
     * Manter o publish do dado no broker é inofensivo (bridge ignora via
     * MIGRATED_TO_HA), mas as entidades em HA precisam ser apagadas.
     */
    private val MIGRATED_TO_HA_IDS = setOf(
        "door_fl", "door_fr", "door_rl", "door_rr", "door_trunk",
        "window_fl", "window_fr", "window_rl", "window_rr",
        "sunroof", "lock_state", "ac_state", "engine_state",
        "charging_state",
        // Trip A/B descontinuados — remove entidade "Histórico de Trips" do HA
        "trips_history",
    )

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
            val topic = "homeassistant/sensor/haval_ecotrip_${s.id}/config"
            if (s.id in MIGRATED_TO_HA_IDS) {
                // Remove a entidade do HA publicando config vazio (retained).
                try { c.publish(topic, ByteArray(0), 1, true) } catch (_: Exception) {}
                continue
            }
            val dcPart   = if (s.dc   != null) ""","device_class":"${s.dc}"""" else ""
            val iconPart = if (s.icon != null) ""","icon":"${s.icon}"""" else ""
            val unitPart = if (s.unit.isNotEmpty()) ""","unit_of_measurement":"${s.unit}"""" else ""
            val scPart   = if (s.sc   != null) ""","state_class":"${s.sc}"""" else ""
            val payload  = """{"name":"${s.name}","state_topic":"${s.topic}","unique_id":"haval_ecotrip_${s.id}","device":$device$unitPart$scPart$dcPart$iconPart}"""
            try { c.publish(topic, payload.toByteArray(), 1, true) } catch (_: Exception) {}
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
            val topic = "homeassistant/binary_sensor/haval_ecotrip_${b.id}/config"
            if (b.id in MIGRATED_TO_HA_IDS) {
                // Remove a entidade do HA publicando config vazio (retained).
                try { c.publish(topic, ByteArray(0), 1, true) } catch (_: Exception) {}
                continue
            }
            val dcPart   = if (b.dc   != null) ""","device_class":"${b.dc}"""" else ""
            val iconPart = if (b.icon != null) ""","icon":"${b.icon}"""" else ""
            val payload  = """{"name":"${b.name}","state_topic":"${b.topic}","unique_id":"haval_ecotrip_${b.id}","payload_on":"1","payload_off":"0","device":$device$dcPart$iconPart}"""
            try { c.publish(topic, payload.toByteArray(), 1, true) } catch (_: Exception) {}
        }

        // Sensor: versão do app instalada no carro
        val appVersionPayload = """{"name":"Versão do App","state_topic":"$prefix/app_version","unique_id":"haval_ecotrip_app_version","icon":"mdi:cellphone-arrow-down","device":$device}"""
        try { c.publish("homeassistant/sensor/haval_ecotrip_app_version/config", appVersionPayload.toByteArray(), 1, true) } catch (_: Exception) {}

        // Sensor: última atualização de dados (timestamp ISO)
        val lastUpdatePayload = """{"name":"Última Atualização","state_topic":"$prefix/last_update","device_class":"timestamp","unique_id":"haval_ecotrip_last_update","icon":"mdi:clock-check-outline","device":$device}"""
        try { c.publish("homeassistant/sensor/haval_ecotrip_last_update/config", lastUpdatePayload.toByteArray(), 1, true) } catch (_: Exception) {}

        // Trip A/B descontinuado — publica payload vazio retained pra REMOVER
        // a entidade "Histórico de Trips" do HA caso ainda exista.
        try { c.publish("homeassistant/sensor/haval_ecotrip_trips_history/config", ByteArray(0), 1, true) } catch (_: Exception) {}

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
        password         = _loadSecurePassword()
        tls              = prefs.getBoolean(SharedPreferencesKeys.MQTT_TLS,               false)
        paired           = prefs.getBoolean(SharedPreferencesKeys.MQTT_PAIRED,            false)
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

        // hvac/* serializado (thread única) pra não floodar o barramento; resto no pool.
        val exec = if (cmd.startsWith("hvac/")) hvacExecutor else cmdExecutor
        exec.submit {
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
                "set_price_gas_per_l" -> {
                    // Bridge publica esse tópico (retained) a cada mudança do médio
                    // ponderado calculado a partir dos abastecimentos no PWA.
                    val v = payload.trim().toFloatOrNull()
                    if (v != null && v > 0) {
                        prefs.edit().putFloat(SharedPreferencesKeys.PRICE_GASOLINE_PER_L, v).apply()
                        TripManager.getInstance().setPriceGasoline(v)
                        AppLogger.i(TAG, "Preço gasolina atualizado pelo bridge: R$ $v/L")
                    }
                }
                "set_price_kwh" -> {
                    val v = payload.trim().toFloatOrNull()
                    if (v != null && v > 0) {
                        prefs.edit().putFloat(SharedPreferencesKeys.PRICE_ENERGY_PER_KWH, v).apply()
                        TripManager.getInstance().setPriceEnergy(v)
                        AppLogger.i(TAG, "Preço energia atualizado pelo bridge: R$ $v/kWh")
                    }
                }
                "rules/set" -> {
                    // Lista completa de regras de automação (JSON array), entregue
                    // pelo bridge via MQTT retido. O motor persiste e passa a avaliar.
                    AutomationManager.setRules(payload)
                    publishResult("rules/set", "ok")
                }
                "refresh_charge_limit" -> {
                    // Força releitura do limite real do carro e re-publica em ha/charge_limit/state.
                    // Usado pelo PWA quando abre a Config de Recarga (caso user tenha mudado
                    // direto no carro e o sync por listener tenha perdido o evento).
                    val readBack = try {
                        car.fetchCurrent("car.ev_setting.charge_soc_limit_config")?.trim()
                    } catch (e: Exception) {
                        AppLogger.w(TAG, "refresh_charge_limit fetchCurrent falhou: ${e.message}")
                        null
                    }
                    val carVal = readBack?.toIntOrNull()
                    val pct = if (carVal != null) carValToPct(carVal) else null
                    if (pct != null) {
                        AppLogger.i(TAG, "refresh_charge_limit: carro = ${pct}% — re-publicando")
                        // Bypassa o guard `lastPublishedChargeLimitPct` pra forçar nova publicação
                        lastPublishedChargeLimitPct = -1
                        publishChargeLimitState(pct)
                    } else {
                        publishResult("refresh_charge_limit", "error: leitura falhou")
                    }
                }
                "drive_mode" -> {
                    // Recebe valor numérico bruto: 0=HEV, 1=Prior. EV, 3=EV puro.
                    val target = payload.trim().toIntOrNull()
                    if (target == null || target !in setOf(0, 1, 3)) {
                        val msg = "error: valor inválido ('$payload'). Use 0 (HEV), 1 (Prior. EV) ou 3 (EV)."
                        AppLogger.w(TAG, msg)
                        publishResult("drive_mode", msg)
                        return@submit
                    }

                    val now = System.currentTimeMillis()
                    val carActiveMs = now - lastCarDataMs
                    val carRecentlyActive = lastCarDataMs > 0L && carActiveMs <= 60_000L
                    if (carRecentlyActive)
                        AppLogger.i(TAG, "Carro ativo há ${carActiveMs / 1000}s — enviando drive_mode=$target")
                    else
                        AppLogger.w(TAG, "Carro sem dados há ${carActiveMs / 1000}s — tentando drive_mode=$target mesmo assim")

                    val ok = car.requestSetting(
                        key   = "car.ev_setting.power_model_config",
                        value = target.toString(),
                    )
                    if (!ok) {
                        val msg = if (carRecentlyActive)
                            "error: carro ativo mas recusou o comando"
                        else
                            "error: carro não respondeu — pode estar dormindo"
                        AppLogger.w(TAG, msg)
                        publishResult("drive_mode", msg)
                        return@submit
                    }
                    AppLogger.i(TAG, "drive_mode requestSetting aceito. Aguardando 5s pra ECU processar...")
                    Thread.sleep(5_000)

                    val readBack = try {
                        car.fetchCurrent("car.ev_setting.power_model_config")?.trim()
                    } catch (e: Exception) {
                        AppLogger.w(TAG, "drive_mode fetchCurrent falhou: ${e.message}")
                        null
                    }
                    val confirmed = readBack?.toIntOrNull()
                    if (confirmed != null && confirmed in setOf(0, 1, 3)) {
                        AppLogger.i(TAG, "Confirmado drive_mode=$confirmed")
                        publishDriveModeState(confirmed)
                        val resultMsg = if (confirmed == target) "ok:$confirmed"
                                        else "ok:$confirmed (solicitado $target — carro aplicou $confirmed)"
                        publishResult("drive_mode", resultMsg)
                    } else {
                        AppLogger.w(TAG, "Leitura de confirmação drive_mode falhou. Fallback ao pretendido.")
                        publishDriveModeState(target)
                        publishResult("drive_mode", "ok:$target (fallback — leitura de confirmação falhou)")
                    }
                }
                "refresh_drive_mode" -> {
                    val readBack = try {
                        car.fetchCurrent("car.ev_setting.power_model_config")?.trim()
                    } catch (e: Exception) {
                        AppLogger.w(TAG, "refresh_drive_mode fetchCurrent falhou: ${e.message}")
                        null
                    }
                    val carVal = readBack?.toIntOrNull()
                    if (carVal != null && carVal in setOf(0, 1, 3)) {
                        AppLogger.i(TAG, "refresh_drive_mode: carro = $carVal — re-publicando")
                        lastPublishedDriveMode = -1
                        publishDriveModeState(carVal)
                    } else {
                        publishResult("refresh_drive_mode", "error: leitura falhou")
                    }
                }
                "power_reserve" -> {
                    // 1=Inteligente, 2=Prioritário
                    val target = payload.trim().toIntOrNull()
                    if (target == null || target !in setOf(1, 2)) {
                        publishResult("power_reserve", "error: valor inválido ('$payload')")
                        return@submit
                    }
                    val ok = car.requestSetting(
                        key   = "car.ev_setting.power_reserve_config",
                        value = target.toString(),
                    )
                    if (!ok) {
                        publishResult("power_reserve", "error: carro recusou ou está dormindo")
                        return@submit
                    }
                    Thread.sleep(3_000)
                    val readBack = try { car.fetchCurrent("car.ev_setting.power_reserve_config")?.trim() }
                                   catch (_: Exception) { null }
                    val confirmed = readBack?.toIntOrNull()
                    if (confirmed != null && confirmed in setOf(1, 2)) {
                        publishPowerReserveState(confirmed)
                        publishResult("power_reserve", if (confirmed == target) "ok:$confirmed"
                                                       else "ok:$confirmed (solicitado $target)")
                    } else {
                        publishPowerReserveState(target)
                        publishResult("power_reserve", "ok:$target (fallback)")
                    }
                }
                "charge_soc_target" -> {
                    // 20..80 (%)
                    val target = payload.trim().toIntOrNull()
                    if (target == null || target !in 20..80) {
                        publishResult("charge_soc_target", "error: valor fora da faixa 20..80 ('$payload')")
                        return@submit
                    }
                    val ok = car.requestSetting(
                        key   = "car.ev_setting.charge_soc_target_config",
                        value = target.toString(),
                    )
                    if (!ok) {
                        publishResult("charge_soc_target", "error: carro recusou ou está dormindo")
                        return@submit
                    }
                    Thread.sleep(3_000)
                    val readBack = try { car.fetchCurrent("car.ev_setting.charge_soc_target_config")?.trim() }
                                   catch (_: Exception) { null }
                    val confirmed = readBack?.toIntOrNull()
                    if (confirmed != null && confirmed in 20..80) {
                        publishSocTargetState(confirmed)
                        publishResult("charge_soc_target", if (confirmed == target) "ok:$confirmed"
                                                           else "ok:$confirmed (solicitado $target)")
                    } else {
                        publishSocTargetState(target)
                        publishResult("charge_soc_target", "ok:$target (fallback)")
                    }
                }
                "refresh_power_reserve" -> {
                    val readBack = try { car.fetchCurrent("car.ev_setting.power_reserve_config")?.trim() }
                                   catch (_: Exception) { null }
                    val carVal = readBack?.toIntOrNull()
                    if (carVal != null && carVal in setOf(1, 2)) {
                        lastPublishedPowerReserve = -1
                        publishPowerReserveState(carVal)
                    } else publishResult("refresh_power_reserve", "error: leitura falhou")
                }
                "refresh_charge_soc_target" -> {
                    val readBack = try { car.fetchCurrent("car.ev_setting.charge_soc_target_config")?.trim() }
                                   catch (_: Exception) { null }
                    val carVal = readBack?.toIntOrNull()
                    if (carVal != null && carVal in 20..80) {
                        lastPublishedSocTarget = -1
                        publishSocTargetState(carVal)
                    } else publishResult("refresh_charge_soc_target", "error: leitura falhou")
                }
                "terrain_mode" -> {
                    val target = payload.trim().toIntOrNull()
                    if (target == null || target !in setOf(0, 1, 2, 3, 4, 5, 11)) {
                        publishResult("terrain_mode", "error: valor inválido ('$payload')")
                        return@submit
                    }
                    val ok = car.requestSetting(key = "car.drive_setting.drive_mode", value = target.toString())
                    if (!ok) { publishResult("terrain_mode", "error: carro recusou ou está dormindo"); return@submit }
                    Thread.sleep(3_000)
                    val confirmed = try { car.fetchCurrent("car.drive_setting.drive_mode")?.trim()?.toIntOrNull() } catch (_: Exception) { null }
                    if (confirmed != null && confirmed in setOf(0, 1, 2, 3, 4, 5, 11)) {
                        publishTerrainModeState(confirmed)
                        publishResult("terrain_mode", if (confirmed == target) "ok:$confirmed" else "ok:$confirmed (solicitado $target)")
                    } else {
                        publishTerrainModeState(target)
                        publishResult("terrain_mode", "ok:$target (fallback)")
                    }
                }
                "hazard" -> {
                    // Pisca-alerta (4 setas): alterna car.light_setting.sport_mode_light.
                    // Chamado pelo iPad a cada ~1s (0/1). Mantém SIMPLES e rápido — sem
                    // confirmação/sleep, pois roda repetidamente em sequência.
                    val target = if (payload.trim() == "1") 1 else 0
                    val ok = car.requestSetting(key = "car.light_setting.sport_mode_light", value = target.toString())
                    publishResult("hazard", if (ok) "ok:$target" else "error: recusado/dormindo")
                    return@submit
                }
                "regen_level" -> {
                    val target = payload.trim().toIntOrNull()
                    if (target == null || target !in setOf(0, 1, 2)) {
                        publishResult("regen_level", "error: valor inválido ('$payload')")
                        return@submit
                    }
                    val ok = car.requestSetting(key = "car.ev_setting.energy_recovery_level", value = target.toString())
                    if (!ok) { publishResult("regen_level", "error: carro recusou ou está dormindo"); return@submit }
                    Thread.sleep(3_000)
                    val confirmed = try { car.fetchCurrent("car.ev_setting.energy_recovery_level")?.trim()?.toIntOrNull() } catch (_: Exception) { null }
                    if (confirmed != null && confirmed in setOf(0, 1, 2)) {
                        publishRegenLevelState(confirmed)
                        publishResult("regen_level", if (confirmed == target) "ok:$confirmed" else "ok:$confirmed (solicitado $target)")
                    } else {
                        publishRegenLevelState(target)
                        publishResult("regen_level", "ok:$target (fallback)")
                    }
                }
                "one_pedal" -> {
                    val target = payload.trim().toIntOrNull()
                    if (target == null || target !in setOf(0, 1)) {
                        publishResult("one_pedal", "error: valor inválido ('$payload')")
                        return@submit
                    }
                    // OTIMISTA ANTES do requestSetting (que pode bloquear) → confirma já.
                    publishOnePedalState(target)
                    val ok = car.requestSetting(key = "car.ev.setting.pedal_control_enable", value = target.toString())
                    if (!ok) {
                        val actual = try { car.fetchCurrent("car.ev.setting.pedal_control_enable")?.trim()?.toIntOrNull() } catch (_: Exception) { null }
                        if (actual != null && actual in setOf(0, 1)) publishOnePedalState(actual)  // reverte
                        publishResult("one_pedal", "error: carro recusou ou está dormindo"); return@submit
                    }
                    Thread.sleep(3_000)
                    val confirmed = try { car.fetchCurrent("car.ev.setting.pedal_control_enable")?.trim()?.toIntOrNull() } catch (_: Exception) { null }
                    if (confirmed != null && confirmed in setOf(0, 1)) {
                        publishOnePedalState(confirmed)
                        publishResult("one_pedal", if (confirmed == target) "ok:$confirmed" else "ok:$confirmed (solicitado $target)")
                    } else {
                        publishOnePedalState(target)
                        publishResult("one_pedal", "ok:$target (fallback)")
                    }
                }
                "esp" -> {
                    val target = payload.trim().toIntOrNull()
                    if (target == null || target !in setOf(0, 1)) {
                        publishResult("esp", "error: valor inválido ('$payload')")
                        return@submit
                    }
                    // OTIMISTA ANTES do requestSetting: o requestSetting pode bloquear
                    // segundos; ecoar já faz o cluster confirmar na hora. Se o carro
                    // recusar, revertemos logo abaixo.
                    publishEspState(target)
                    val ok = car.requestSetting(key = "car.drive_setting.esp_enable", value = target.toString())
                    if (!ok) {
                        val actual = try { car.fetchCurrent("car.drive_setting.esp_enable")?.trim()?.toIntOrNull() } catch (_: Exception) { null }
                        if (actual != null && actual in setOf(0, 1)) publishEspState(actual)  // reverte o otimista
                        publishResult("esp", "error: carro recusou ou está dormindo"); return@submit
                    }
                    Thread.sleep(3_000)
                    val confirmed = try { car.fetchCurrent("car.drive_setting.esp_enable")?.trim()?.toIntOrNull() } catch (_: Exception) { null }
                    if (confirmed != null && confirmed in setOf(0, 1)) {
                        publishEspState(confirmed)
                        publishResult("esp", if (confirmed == target) "ok:$confirmed" else "ok:$confirmed (solicitado $target)")
                    } else {
                        publishEspState(target)
                        publishResult("esp", "ok:$target (fallback)")
                    }
                }
                "steer_mode" -> {
                    val target = payload.trim().toIntOrNull()
                    if (target == null || target !in setOf(0, 1, 2)) {
                        publishResult("steer_mode", "error: valor inválido ('$payload')")
                        return@submit
                    }
                    val ok = car.requestSetting(key = "car.drive_setting.steering_wheel_assist_mode", value = target.toString())
                    if (!ok) { publishResult("steer_mode", "error: carro recusou ou está dormindo"); return@submit }
                    Thread.sleep(3_000)
                    val confirmed = try { car.fetchCurrent("car.drive_setting.steering_wheel_assist_mode")?.trim()?.toIntOrNull() } catch (_: Exception) { null }
                    if (confirmed != null && confirmed in setOf(0, 1, 2)) {
                        publishSteerModeState(confirmed)
                        publishResult("steer_mode", if (confirmed == target) "ok:$confirmed" else "ok:$confirmed (solicitado $target)")
                    } else {
                        publishSteerModeState(target)
                        publishResult("steer_mode", "ok:$target (fallback)")
                    }
                }
                "hf_mode" -> {
                    // Modo de alta frequência (250ms entre publishes) acionado pelo PWA
                    // enquanto a aba cluster/conforto está aberta. Bridge envia '0' se não
                    // houver heartbeat, então não precisa de timeout no APK.
                    val on = payload.trim() == "1"
                    if (hfModeActive != on) {
                        hfModeActive = on
                        AppLogger.i(TAG, if (on) "HF mode ON — publish a cada ${HF_MODE_INTERVAL_MS}ms" else "HF mode OFF — intervalo normal restaurado")
                    }
                }
                "diag" -> {
                    // Payload JSON: { enabled: bool, interval_sec: int }
                    try {
                        val o = JSONObject(payload)
                        val enabled = o.optBoolean("enabled", false)
                        val interval = o.optInt("interval_sec", 5)
                        applyDiagState(enabled, interval)
                    } catch (e: Exception) {
                        AppLogger.w(TAG, "[diag] payload inválido: '$payload' (${e.message})")
                    }
                }
                else -> {
                    // Comandos HVAC: cmd/hvac/<control> — escreve no barramento via Shizuku.
                    // Bridge já validou range/tipo; aqui só mapeia control → chave do bus.
                    if (cmd.startsWith("diag_set/")) {
                        // Tenta gravar uma constante arbitrária via Shizuku.
                        // Bridge envia o valor cru; APK chama requestSetting e publica
                        // resultado em diag_ack/<KEY>.
                        val keyName = cmd.removePrefix("diag_set/")
                        val constant = CarConstants.entries.firstOrNull { it.name == keyName }
                        if (constant == null) {
                            try {
                                val ack = JSONObject().put("ok", false).put("error", "chave desconhecida: $keyName")
                                client?.publish("$prefix/diag_ack/$keyName", ack.toString().toByteArray(), 1, false)
                            } catch (_: Exception) {}
                            return@submit
                        }
                        AppLogger.i(TAG, "[diag] set ${constant.value} = '$payload'")
                        val ok = try { car.requestSetting(key = constant.value, value = payload) }
                                 catch (e: Exception) { AppLogger.w(TAG, "requestSetting falhou: ${e.message}"); false }
                        // Pequena pausa pra ECU processar antes de ler de volta
                        Thread.sleep(800)
                        val applied = try { car.fetchCurrent(constant.value) } catch (_: Exception) { null }
                        val ack = JSONObject()
                            .put("ok", ok)
                            .put("applied", applied ?: JSONObject.NULL)
                            .put("requested", payload)
                            .put("bus_key", constant.value)
                        if (!ok) ack.put("error", "carro rejeitou (read-only ou dormindo)")
                        try {
                            client?.publish("$prefix/diag_ack/$keyName", ack.toString().toByteArray(), 1, false)
                        } catch (e: Exception) { AppLogger.w(TAG, "publish ack falhou: ${e.message}") }
                        return@submit
                    }
                    if (cmd.startsWith("vehicle/")) {
                        // Comandos físicos via binder IVehicle (vidro/teto/cortina/porta).
                        // Usados pelo motor de automações e por teste manual. Payloads:
                        //   vehicle/window         {"window":0,"status":1}  ou {"all":true,"status":1}
                        //   vehicle/skylight       <int level>   (0=fechado)
                        //   vehicle/shade          <int level>
                        //   vehicle/door           {"p1":0,"p2":1}
                        //   vehicle/windows_status (sem payload) → lê e publica o array
                        val sub = cmd.removePrefix("vehicle/")
                        try {
                            when (sub) {
                                "window" -> {
                                    val o = JSONObject(payload)
                                    val status = o.getInt("status")
                                    val ok = if (o.optBoolean("all", false))
                                        VehicleControlManager.setAllWindows(status)
                                    else
                                        VehicleControlManager.setWindowStatus(o.getInt("window"), status)
                                    publishResult("vehicle/window", if (ok) "ok" else "error")
                                }
                                "skylight" -> {
                                    val ok = VehicleControlManager.setSkylightLevel(payload.trim().toInt())
                                    publishResult("vehicle/skylight", if (ok) "ok" else "error")
                                }
                                "shade" -> {
                                    val ok = VehicleControlManager.setShadeScreensLevel(payload.trim().toInt())
                                    publishResult("vehicle/shade", if (ok) "ok" else "error")
                                }
                                "door" -> {
                                    val o = JSONObject(payload)
                                    val ok = VehicleControlManager.setDoorOpen(o.getInt("p1"), o.getInt("p2"))
                                    publishResult("vehicle/door", if (ok) "ok" else "error")
                                }
                                "windows_status" -> {
                                    val arr = VehicleControlManager.getWindowsStatus()
                                    publishResult("vehicle/windows_status",
                                        arr?.joinToString(",", "[", "]") ?: "error")
                                }
                                "read" -> {
                                    // Lê qualquer chave: car.* via fetchCurrent, ou "rain_intensity" via IVehicle.
                                    val key = payload.trim()
                                    val v = if (key == "rain_intensity") VehicleControlManager.getRainIntensity()?.toString()
                                            else CarDataManager.getInstance().fetchCurrent(key)
                                    publishResult("vehicle/read", v ?: "null")
                                }
                                else -> publishResult("vehicle/$sub", "error: subcomando desconhecido")
                            }
                        } catch (e: Exception) {
                            AppLogger.w(TAG, "[vehicle] '$sub' payload inválido: ${e.message}")
                            publishResult("vehicle/$sub", "error: ${e.message}")
                        }
                        return@submit
                    }
                    if (cmd.startsWith("hvac/")) {
                        val control = cmd.removePrefix("hvac/")
                        // ON/OFF "inteligente": OFF zera o fan (guardando o valor atual);
                        // ON liga o compressor (ac_enable=1) e restaura o fan anterior.
                        if (control == "power") {
                            // Mestre do AC: car.hvac.power_mode (0=tudo desligado, 1=ligado).
                            val target = if (payload.trim() == "1") 1 else 0
                            val ok = car.requestSetting(key = "car.hvac.power_mode", value = target.toString())
                            if (!ok) { publishResult("hvac/power", "error: carro recusou ou está dormindo"); return@submit }
                            latestHvacPowerMode = target
                            publishResult("hvac/power", "ok:$target")
                            return@submit
                        }
                        val busKey = when (control) {
                            "driver_temp"    -> "car.hvac.driver_temperature"
                            "passenger_temp" -> "car.hvac.pass_temperature"
                            "fan_speed"      -> "car.hvac.fan_speed"
                            "sync"           -> "car.hvac.sync_enable"
                            "auto"           -> "car.hvac.auto_enable"
                            "ac_enable"      -> "car.hvac.ac_enable"  // master ON/OFF do AC (compressor)
                            "cycle_mode"     -> "car.hvac.cycle_mode"
                            "blower_mode"    -> "car.hvac.blower_mode"
                            "acmax"          -> "car.hvac.acmax_enable"
                            "anion"          -> "car.hvac.anion_enable"
                            "aqs"            -> "car.hvac.aqs_enable"
                            "heating"        -> "car.hvac.heating_enable"
                            "front_defrost"  -> "car.hvac.front_defrost_enable"
                            "rear_defrost"   -> "car.hvac.rear_defrost_enable"
                            "auto_defrost"   -> "car.hvac.setting.auto_defrost_enable"
                            "seat_vent_drv"  -> "car.comfort_setting.driver_seat_ventilation_level"
                            "seat_vent_pass" -> "car.comfort_setting.passenger_seat_ventilation_level"
                            else -> null
                        }
                        if (busKey == null) {
                            publishResult("hvac/$control", "error: chave desconhecida")
                            return@submit
                        }
                        AppLogger.i(TAG, "HVAC set: $busKey = $payload")
                        val ok = try {
                            car.requestSetting(key = busKey, value = payload)
                        } catch (e: Exception) {
                            AppLogger.w(TAG, "requestSetting falhou: ${e.message}")
                            false
                        }
                        if (!ok) {
                            publishResult("hvac/$control", "error: carro rejeitou ou está dormindo")
                            return@submit
                        }
                        Thread.sleep(2500)
                        val confirmed = try { car.fetchCurrent(busKey) } catch (_: Exception) { null }
                        val resultMsg = when {
                            confirmed == null -> "ok:$payload (fallback — leitura falhou)"
                            confirmed == payload -> "ok:$confirmed"
                            else -> "ok:$confirmed (solicitado $payload)"
                        }
                        publishResult("hvac/$control", resultMsg)
                        AppLogger.i(TAG, "✓ HVAC aplicado: $busKey solicitado=$payload confirmado=$confirmed")
                    } else {
                        AppLogger.w(TAG, "Comando desconhecido: $cmd")
                    }
                }
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

    /**
     * Entry point pra comandos vindos do LocalApiServer (LAN do iPad).
     * Reusa o mesmo handler do MQTT — execução vai pro executor single-thread
     * (serializa todos os comandos) e publica resultado via MQTT pro Mac mini
     * (dual-publish), igual se tivesse vindo do bridge.
     */
    fun dispatchLocalCommand(cmd: String, payload: String) {
        handleIncomingCommand("$prefix/cmd/$cmd", payload)
    }

    // ─── Modo diagnóstico ────────────────────────────────────────────
    // Quando ativado pela PWA via cmd/diag, o APK lê TODAS as constantes
    // do CarConstants em loop e publica em diag/<KEY> a cada N segundos.
    // Bridge propaga via WS pro PWA, e salva snapshot em diag_state.json.
    @Volatile private var diagEnabled = false
    @Volatile private var diagIntervalSec = 5
    @Volatile private var diagTimer: Timer? = null

    private fun applyDiagState(enabled: Boolean, intervalSec: Int, source: String = "cmd") {
        diagEnabled = enabled
        diagIntervalSec = intervalSec.coerceIn(1, 300)
        // Persiste em SharedPreferences pra sobreviver restart do app
        try {
            appContext?.getSharedPreferences(SharedPreferencesKeys.PREFS_NAME, Context.MODE_PRIVATE)?.edit()
                ?.putBoolean("diag_enabled", enabled)
                ?.putInt("diag_interval_sec", diagIntervalSec)
                ?.apply()
        } catch (_: Exception) {}
        // Cancela timer antigo
        diagTimer?.cancel()
        diagTimer = null
        if (!enabled) {
            AppLogger.i(TAG, "[diag] DESATIVADO")
            publishDiagState(source)
            return
        }
        AppLogger.i(TAG, "[diag] ATIVADO (intervalo ${diagIntervalSec}s, ${CarConstants.entries.size} constantes)")
        val periodMs = diagIntervalSec * 1000L
        val t = Timer("diag-publisher", true)
        t.scheduleAtFixedRate(object : TimerTask() {
            override fun run() {
                try { publishDiagSnapshot() } catch (e: Exception) {
                    AppLogger.w(TAG, "[diag] erro no loop: ${e.message}")
                }
            }
        }, 500L, periodMs)
        diagTimer = t
        publishDiagState(source)
    }

    // Publica estado real do modo diag em diag/state (retained) — o bridge
    // usa isso como única fonte de verdade pra refletir o toggle na PWA.
    private fun publishDiagState(source: String) {
        val c = client ?: return
        if (!c.isConnected) return
        try {
            val state = JSONObject()
                .put("enabled", diagEnabled)
                .put("interval_sec", diagIntervalSec)
                .put("applied_at", System.currentTimeMillis())
                .put("source", source)
            c.publish("$prefix/diag/state", state.toString().toByteArray(), 1, true)
            AppLogger.i(TAG, "[diag] state publicado: enabled=$diagEnabled interval=$diagIntervalSec src=$source")
        } catch (e: Exception) {
            AppLogger.w(TAG, "[diag] erro publicando state: ${e.message}")
        }
    }

    private fun publishDiagSnapshot() {
        val c = client ?: return
        if (!c.isConnected) return
        val car = CarDataManager.getInstance()
        var ok = 0; var fail = 0
        for (k in CarConstants.entries) {
            try {
                val raw = car.fetchCurrent(k.value)
                if (raw != null) {
                    c.publish("$prefix/diag/${k.name}", raw.toByteArray(), 0, false)
                    ok++
                } else fail++
            } catch (_: Exception) { fail++ }
        }
        AppLogger.d(TAG, "[diag] snapshot: $ok ok / $fail null")
    }

    // Pega estado persistido em SharedPreferences (chamado no init)
    private fun restoreDiagState(prefs: SharedPreferences) {
        val enabled = prefs.getBoolean("diag_enabled", false)
        val interval = prefs.getInt("diag_interval_sec", 5)
        // Espera 5s pra MQTT conectar antes de publicar/aplicar
        executor.submit {
            Thread.sleep(5_000)
            if (enabled) {
                AppLogger.i(TAG, "[diag] estado persistido encontrado — restaurando (interval ${interval}s)")
                applyDiagState(true, interval, source = "restore")
            } else {
                diagEnabled = false
                diagIntervalSec = interval
                // Publica o estado real (disabled) pra bridge saber que o APK está vivo
                publishDiagState("restore")
            }
        }
    }

    // Handler pra debounce do status: blips curtos de WiFi/Starlink fazem o
    // socket cair e voltar em <10s. Sem debounce, a UI pisca "Desconectado"
    // mesmo quando a recuperação foi quase imediata. status interno é atualizado
    // na hora; só o evento p/ UI atrasa 12s no DOWNGRADE de CONNECTED.
    private val statusDebounceHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private var pendingDowngrade: Runnable? = null

    private fun setStatus(s: Status) {
        val prev = status
        status = s

        // Cancela downgrade pendente (subida volta a ser instantânea).
        pendingDowngrade?.let { statusDebounceHandler.removeCallbacks(it) }
        pendingDowngrade = null

        when {
            s == Status.CONNECTED -> {
                // Subida pra CONNECTED: instantâneo (mostra logo "Conectado").
                onStatusChange?.invoke(s)
            }
            prev == Status.CONNECTED -> {
                // Saindo de CONNECTED: segura o evento pra UI por 12s. Se a
                // conexão voltar nesse tempo (Starlink/WiFi blip), nem mostra
                // "Desconectado"/"Conectando" pro user.
                val r = Runnable {
                    if (status != Status.CONNECTED) onStatusChange?.invoke(status)
                    pendingDowngrade = null
                }
                pendingDowngrade = r
                statusDebounceHandler.postDelayed(r, 12_000L)
            }
            else -> {
                // Transições entre estados não-CONNECTED (CONNECTING↔ERROR↔DISCONNECTED): direto.
                onStatusChange?.invoke(s)
            }
        }
    }
}
