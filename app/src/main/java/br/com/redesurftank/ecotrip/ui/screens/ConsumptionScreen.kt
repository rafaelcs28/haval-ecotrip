package br.com.redesurftank.ecotrip.ui.screens

import android.os.Handler
import android.os.Looper
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.material.icons.filled.BatteryChargingFull
import androidx.compose.material.icons.filled.DirectionsCar
import androidx.compose.material.icons.filled.LocalGasStation
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.BugReport
import androidx.compose.material.icons.filled.SystemUpdate
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import br.com.redesurftank.ecotrip.BuildConfig
import br.com.redesurftank.ecotrip.managers.BackupManager
import br.com.redesurftank.ecotrip.managers.CarDataManager
import br.com.redesurftank.ecotrip.managers.MqttManager
import br.com.redesurftank.ecotrip.managers.AutoTripEntry
import br.com.redesurftank.ecotrip.managers.ChargeHistoryEntry
import br.com.redesurftank.ecotrip.managers.RollingSnapshot
import br.com.redesurftank.ecotrip.managers.TripHistoryEntry
import br.com.redesurftank.ecotrip.managers.TripManager
import br.com.redesurftank.ecotrip.managers.UpdateManager
import br.com.redesurftank.ecotrip.models.CarConstants
import br.com.redesurftank.ecotrip.ui.components.BulletBar
import br.com.redesurftank.ecotrip.ui.components.HeroGauge
import br.com.redesurftank.ecotrip.ui.components.LinearMeter
import br.com.redesurftank.ecotrip.ui.components.MetricBlock
import br.com.redesurftank.ecotrip.ui.components.MiniBar
import br.com.redesurftank.ecotrip.ui.components.SocStripBar
import br.com.redesurftank.ecotrip.ui.components.StatusBadge
import br.com.redesurftank.ecotrip.ui.theme.*
import androidx.compose.ui.graphics.vector.rememberVectorPainter

private val mainHandler = Handler(Looper.getMainLooper())

// Chaves de telemetria contínua que mudam o tempo todo durante a condução.
// Vão pra via expressa: publish só desses tópicos a até 20 Hz (debounce 50ms),
// pra PWA atualizar speed/RPM/power em quase tempo real.
private val FAST_LANE_KEYS: Set<String> = setOf(
    CarConstants.CAR_BASIC_VEHICLE_SPEED.value,
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
    CarConstants.CAR_BASIC_DOOR_LOCK_STATUS.value,
    CarConstants.CAR_BASIC_DOOR_STATUS.value,
    CarConstants.CAR_BASIC_WINDOW_STATUS.value,
    CarConstants.CAR_BASIC_SUNROOF_STATUS.value,
)

@Composable
fun ConsumptionScreen() {
    val context     = LocalContext.current
    val tripManager = remember { TripManager.getInstance() }
    val carManager  = remember { CarDataManager.getInstance() }
    val mqttManager = remember { MqttManager.getInstance() }
    val updateMgr   = remember { UpdateManager.getInstance() }
    val backupMgr = remember { BackupManager.getInstance() }

    var rolling by remember { mutableStateOf(RollingSnapshot(0f, 0f, 0f, 0f)) }
    var history       by remember { mutableStateOf<List<TripHistoryEntry>>(emptyList()) }
    var chargeHistory by remember { mutableStateOf<List<ChargeHistoryEntry>>(emptyList()) }
    var tankCapacity  by remember { mutableStateOf(tripManager.getTankCapacity()) }
    var maxHistory    by remember { mutableStateOf(tripManager.getMaxHistoryEntries()) }
    var priceGasoline by remember { mutableStateOf(tripManager.getPriceGasoline()) }
    var priceEnergy   by remember { mutableStateOf(tripManager.getPriceEnergy()) }
    var mqttStatus      by remember { mutableStateOf(mqttManager.status) }
    var mqttFailures    by remember { mutableStateOf(mqttManager.hasRepeatedFailures) }
    var nowMs           by remember { mutableStateOf(System.currentTimeMillis()) }
    var inProgressTrip  by remember { mutableStateOf<AutoTripEntry?>(null) }
    var updateAvailable  by remember { mutableStateOf(updateMgr.isUpdateAvailable) }
    var isCheckingUpdate by remember { mutableStateOf(updateMgr.isChecking) }
    var downloadProgress by remember { mutableStateOf(updateMgr.downloadProgress) }

    // Check on startup + repeat every 3 min while app is running
    LaunchedEffect(Unit) {
        updateMgr.checkForUpdate()
        updateMgr.startPeriodicCheck(3)
    }

    DisposableEffect(updateMgr) {
        updateMgr.onUpdateStateChanged = {
            mainHandler.post {
                updateAvailable  = updateMgr.isUpdateAvailable
                isCheckingUpdate = updateMgr.isChecking
                downloadProgress = updateMgr.downloadProgress
            }
        }
        onDispose { updateMgr.onUpdateStateChanged = null }
    }

    // Tick every second for MQTT timestamp + every 5s triggers a snapshot refresh for timeSec
    LaunchedEffect(Unit) {
        var ticks = 0
        while (true) {
            delay(1000)
            nowMs = System.currentTimeMillis()
            ticks++
            inProgressTrip = tripManager.getInProgressAutoTrip()
            if (ticks % 5 == 0) tripManager.tickTime()
            // SOC e combustível chegam raramente via listener passivo no GWM —
            // busca ativa a cada 60 s garante que o auto-trip capture o valor correto ao finalizar
            if (ticks % 60 == 30) {
                // Busca ativa dos sinais que chegam raramente via listener passivo
                val socVal  = withContext(Dispatchers.IO) {
                    carManager.fetchCurrent(CarConstants.CAR_EV_INFO_SOC_OF_BATTERY.value)?.trim()
                }
                val fuelVal = withContext(Dispatchers.IO) {
                    carManager.fetchCurrent(CarConstants.CAR_BASIC_REMAIN_FUEL_PERCENTAGE.value)?.trim()
                }
                socVal?.let  { tripManager.onDataChanged(CarConstants.CAR_EV_INFO_SOC_OF_BATTERY.value, it) }
                fuelVal?.let { tripManager.onDataChanged(CarConstants.CAR_BASIC_REMAIN_FUEL_PERCENTAGE.value, it) }
            }
        }
    }

    var showChargeHistory by remember { mutableStateOf(false) }
    var showAutoTrips     by remember { mutableStateOf(false) }
    var showSettings      by remember { mutableStateOf(false) }
    var showLog           by remember { mutableStateOf(false) }
    var minAutoTripDist   by remember { mutableStateOf(tripManager.getMinAutoTripDist()) }
    var lastCompletedTrip by remember { mutableStateOf<AutoTripEntry?>(null) }
    // Lista de viagens automáticas — carregada uma vez quando a tela é aberta e
    // actualizada após renomear ou limpar. Evita chamar getAutoTripHistory() a cada
    // recomposição (que criaria uma nova lista instável e poderia causar loops).
    var autoTripEntries   by remember { mutableStateOf<List<AutoTripEntry>>(emptyList()) }
    var resumableTrip     by remember { mutableStateOf<AutoTripEntry?>(null) }

    // Verifica continuamente se há viagem retomável. Aparece e some sozinho conforme
    // as condições mudam (janela 60min, distância da viagem em curso, etc).
    // Espera 3s antes do primeiro check — evita popup competindo com a partida do
    // carro (vários apps Android Auto inicializando ao mesmo tempo).
    LaunchedEffect(Unit) {
        delay(3_000L)
        while (true) {
            resumableTrip = tripManager.getResumableLastTrip()
            delay(5_000L)
        }
    }

    DisposableEffect(Unit) {
        val tripListener: (RollingSnapshot) -> Unit = { r ->
            mainHandler.post {
                rolling = r
                history = tripManager.getHistory()
                mqttManager.publish(r)
            }
        }

        // Recalcula potência de recarga e notifica TripManager quando qualquer
        // dado elétrico relevante muda (estado, corrente ou tensão).
        fun syncCharging() {
            val state   = mqttManager.latestChargingState
            val powerKw = if (state == 1 && mqttManager.latestBatteryVoltageV > 0f)
                kotlin.math.abs(mqttManager.latestChargeCurrentA) * mqttManager.latestBatteryVoltageV / 1000f
            else 0f
            tripManager.onChargingUpdate(state == 1, powerKw)
        }

        val carListener: (String, String) -> Unit = { key, value ->
            mainHandler.post {
                mqttManager.lastCarDataMs = System.currentTimeMillis()
                when (key) {
                    CarConstants.CAR_BASIC_POWER_MODE.value -> {
                        val mode = value.trim().toIntOrNull() ?: 0
                        when (mode) {
                            1, 2, 3 -> tripManager.onSessionStart()
                            0       -> tripManager.onSessionEnd()
                        }
                    }
                    CarConstants.CAR_BASIC_VEHICLE_SPEED.value -> {
                        mqttManager.latestSpeedKmh = value.trim().toFloatOrNull() ?: 0f
                        tripManager.onDataChanged(key, value)
                    }
                    CarConstants.CAR_BASIC_INSIDE_TEMP.value -> {
                        mqttManager.latestInsideTemp = value.trim().toFloatOrNull() ?: 0f
                        tripManager.onDataChanged(key, value)
                    }
                    CarConstants.CAR_BASIC_OUTSIDE_TEMP.value -> {
                        mqttManager.latestOutsideTemp = value.trim().toFloatOrNull() ?: 0f
                        tripManager.onDataChanged(key, value)
                    }
                    CarConstants.CAR_EV_SETTING_CHARGE_SOC_LIMIT.value -> {
                        val carVal = value.trim().toIntOrNull()
                        if (carVal != null) mqttManager.syncChargeLimitFromCar(carVal)
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
                        mqttManager.latestGear = gearStr
                        tripManager.onGear(gearStr)
                    }
                    CarConstants.CAR_BASIC_DRIVING_READY_STATE.value -> {
                        val state = value.trim().toIntOrNull() ?: return@post
                        mqttManager.latestDrivingReadyState = state
                        tripManager.onDrivingReady(state)
                    }
                    CarConstants.CAR_EV_INFO_CUR_CHARGE_CURRENT.value -> {
                        val raw = value.trim().toFloatOrNull() ?: 0f
                        // O bus retorna sentinelas tipo -1001 quando o carro está
                        // parado/sem dado. Range físico real: ~ -400..+400 A.
                        val current = if (kotlin.math.abs(raw) > 500f) 0f else raw
                        mqttManager.latestChargeCurrentA = current
                        // Potência do motor: V (car.ev_info.power_battery_voltage) × A / 1000 = kW
                        val motorKw = mqttManager.latestBatteryVoltageV * current / 1000f
                        mqttManager.latestMotorPowerKw = motorKw
                        tripManager.updateMotorPowerKw(motorKw)
                        syncCharging()
                    }
                    CarConstants.CAR_BASIC_BATTERY_VOLTAGE.value -> {
                        // Apenas armazena — não entra no cálculo de potência
                        mqttManager.latestBasicBattVoltageV = value.trim().toFloatOrNull() ?: 0f
                    }
                    CarConstants.CAR_EV_INFO_POWER_BATTERY_VOLTAGE.value -> {
                        val rawV = value.trim().toFloatOrNull() ?: 0f
                        // Filtra sentinelas (range físico real: ~250..450 V)
                        val voltage = if (rawV < 100f || rawV > 600f) 0f else rawV
                        mqttManager.latestBatteryVoltageV = voltage
                        val motorKw = voltage * mqttManager.latestChargeCurrentA / 1000f
                        mqttManager.latestMotorPowerKw = motorKw
                        tripManager.updateMotorPowerKw(motorKw)
                        tripManager.onDataChanged(key, value)
                        syncCharging()
                    }
                    CarConstants.CAR_EV_INFO_POWER_BATTERY_CURRENT.value -> {
                        mqttManager.latestBatteryCurrentA = value.trim().toFloatOrNull() ?: 0f
                        tripManager.onDataChanged(key, value)
                    }
                    CarConstants.CAR_BASIC_TOTAL_ODOMETER.value -> {
                        val km = value.trim().toFloatOrNull() ?: 0f
                        mqttManager.latestOdometerKm = km
                        // não passa para TripManager (não é usado em cálculos de trip)
                    }
                    CarConstants.CAR_EV_INFO_CHARGING_STATE.value -> {
                        mqttManager.latestChargingState = value.trim().toIntOrNull() ?: -1
                        syncCharging()
                    }
                    CarConstants.CAR_EV_INFO_CHARGE_REMAINING_TIME.value -> {
                        mqttManager.latestChargeRemainingMin = value.trim().toIntOrNull() ?: 0
                    }
                    CarConstants.CAR_EV_INFO_ENERGY_OUTPUT_PERCENTAGE.value -> {
                        // % potência motor elétrico em tempo real → barra no iPhone + telemetria
                        mqttManager.latestBattPowerPct = value.trim().toIntOrNull() ?: 0
                        tripManager.onDataChanged(key, value)  // rastreia pico no auto-trip + telemetria
                    }
                    CarConstants.CAR_EV_INFO_CUR_BATTERY_POWER_PERCENTAGE.value -> {
                        // SOC da bateria → alimenta latestSocPct para SOC inicial/final dos trips
                        tripManager.onDataChanged(key, value)
                    }
                    CarConstants.CAR_BASIC_ENGINE_SPEED.value -> {
                        mqttManager.latestEngineRpm = value.trim().toIntOrNull() ?: 0
                        tripManager.onDataChanged(key, value)  // alimenta telemetryRecorder.latestEngineRpm
                    }
                    CarConstants.CAR_COMFORT_DRIVER_SEAT_VENT.value -> {
                        mqttManager.latestDriverSeatVent = value.trim().toIntOrNull() ?: 0
                    }
                    CarConstants.CAR_COMFORT_PASSENGER_SEAT_VENT.value -> {
                        mqttManager.latestPassengerSeatVent = value.trim().toIntOrNull() ?: 0
                    }
                    CarConstants.CAR_HVAC_DRIVER_TEMPERATURE.value -> {
                        mqttManager.latestHvacDriverTemp = value.trim().toFloatOrNull() ?: 0f
                    }
                    CarConstants.CAR_HVAC_PASSENGER_TEMPERATURE.value -> {
                        mqttManager.latestHvacPassengerTemp = value.trim().toFloatOrNull() ?: 0f
                    }
                    CarConstants.CAR_HVAC_FAN_SPEED.value -> {
                        mqttManager.latestHvacFanSpeed = value.trim().toIntOrNull() ?: 0
                    }
                    CarConstants.CAR_HVAC_SYNC_ENABLE.value -> {
                        mqttManager.latestHvacSyncEnable = value.trim().toIntOrNull() ?: 0
                    }
                    CarConstants.CAR_HVAC_AUTO_ENABLE.value -> {
                        mqttManager.latestHvacAutoEnable = value.trim().toIntOrNull() ?: 0
                    }
                    CarConstants.CAR_HVAC_AC_ENABLE.value -> {
                        mqttManager.latestHvacAcEnable = value.trim().toIntOrNull() ?: 0
                    }
                    CarConstants.CAR_HVAC_CYCLE_MODE.value -> {
                        mqttManager.latestHvacCycleMode = value.trim().toIntOrNull() ?: 0
                    }
                    CarConstants.CAR_BASIC_DOOR_LOCK_STATUS.value -> {
                        val raw = value.trim().toIntOrNull() ?: 0
                        mqttManager.applyLockStatus(raw)  // voting filter K=8
                    }
                    CarConstants.CAR_BASIC_DOOR_STATUS.value -> {
                        // Formato esperado: CSV "FL,FR,RL,RR,Trunk" — 0=fechada, 1=aberta.
                        // O carro emite o CSV envolvido em chaves: "{0,0,0,0,0}". Limpa
                        // qualquer não-dígito (exceto vírgula e sinal) antes de parsear,
                        // se não o primeiro/último elemento ficam grudados com `{`/`}` e
                        // viram 0 (toIntOrNull falha).
                        mqttManager.latestDoorStatusRaw = value
                        val cleaned = value.replace(Regex("[^0-9,\\-]"), "")
                        val parts = cleaned.split(",").mapNotNull { it.trim().toIntOrNull() }
                        if (parts.size >= 4) {
                            mqttManager.latestDoorFl = parts.getOrElse(0) { 0 }
                            mqttManager.latestDoorFr = parts.getOrElse(1) { 0 }
                            mqttManager.latestDoorRl = parts.getOrElse(2) { 0 }
                            mqttManager.latestDoorRr = parts.getOrElse(3) { 0 }
                            mqttManager.latestTrunk  = parts.getOrElse(4) { 0 }
                        }
                    }
                    CarConstants.CAR_BASIC_WINDOW_STATUS.value -> {
                        // CSV "FL,FR,RL,RR" — cru "1"=fechado, demais valores=aberto.
                        // O carro emite envolvido em chaves: "{1,1,1,1}". Limpa qualquer
                        // não-dígito (exceto vírgula e sinal) antes de parsear — senão o
                        // primeiro/último elemento ficam grudados com `{`/`}` e viram 0.
                        // applyWindowStatus aplica voting filter (K=8 leituras consecutivas)
                        // pra filtrar rajadas de ruído do barramento.
                        mqttManager.latestWindowStatusRaw = value
                        val cleaned = value.replace(Regex("[^0-9,\\-]"), "")
                        val parts = cleaned.split(",").mapNotNull { it.trim().toIntOrNull() }
                        if (parts.size >= 4) {
                            mqttManager.applyWindowStatus(parts[0], parts[1], parts[2], parts[3])
                        }
                    }
                    CarConstants.CAR_BASIC_SUNROOF_STATUS.value -> {
                        // 0=fechado, >0=aberto (vários estágios)
                        mqttManager.latestSunroof = value.trim().toIntOrNull() ?: 0
                    }
                    else -> tripManager.onDataChanged(key, value)
                }
                // Roteamento por tipo de chave:
                //   - IMMEDIATE_PUBLISH_KEYS  → full snapshot na hora
                //   - FAST_LANE_KEYS          → só speed/RPM/power, ~20 Hz (50ms debounce)
                //   - resto                   → full snapshot debounced a 1s
                when (key) {
                    in IMMEDIATE_PUBLISH_KEYS -> mqttManager.markChangedImmediate()
                    in FAST_LANE_KEYS         -> mqttManager.markChangedFast()
                    else                      -> mqttManager.markChanged()
                }
            }
        }

        val connectedListener: () -> Unit = {
            try {
                // Vehicle model — precisa ser lido ANTES do publishDiscovery do MQTT para popular
                // o device JSON. carListener não tem branch pra essas chaves.
                mqttManager.vehicleModel1 = carManager.fetchCurrent(CarConstants.CAR_BASIC_VEHICLE_MODEL1.value)?.trim() ?: ""
                mqttManager.vehicleModel2 = carManager.fetchCurrent(CarConstants.CAR_BASIC_VEHICLE_MODEL2.value)?.trim() ?: ""

                // Startup scan: lê TODAS as chaves do barramento e propaga via carListener.
                // Garante que mqttManager.latest* e tripManager fiquem populados desde o primeiro
                // segundo, sem depender do listener passivo do car bus (que pode demorar para
                // certas chaves chegarem). Toda a lógica per-key (parsing, syncCharging,
                // syncChargeLimitFromCar, onSessionStart, etc.) é reusada via carListener.
                for (key in CarConstants.entries) {
                    if (key == CarConstants.CAR_BASIC_VEHICLE_MODEL1 ||
                        key == CarConstants.CAR_BASIC_VEHICLE_MODEL2) continue  // já lidos acima
                    val v = try { carManager.fetchCurrent(key.value)?.trim() } catch (_: Exception) { null }
                    if (!v.isNullOrEmpty()) carListener(key.value, v)
                }
                // Snapshot completo logo após o scan — postado no mainHandler pra rodar DEPOIS
                // de todas as invocações de carListener (que também postam pro mainHandler;
                // a fila FIFO garante a ordem correta).
                mainHandler.post { mqttManager.markChangedImmediate() }
            } catch (_: Exception) {}
        }

        tripManager.onAutoTripCompleted = { entry ->
            mainHandler.post {
                lastCompletedTrip = entry
                // Atualiza lista de viagens para o card em andamento sumir e a nova aparecer
                autoTripEntries = tripManager.getAutoTripHistory()
            }
        }

        tripManager.onChargeSessionCompleted = { _ ->
            mainHandler.post {
                val updated = tripManager.getChargeHistory()
                chargeHistory = updated
                mqttManager.publishChargeHistory(updated)
            }
        }

        tripManager.onRefuelDetected = { _ ->
            mainHandler.post {
                // Publica imediato se MQTT online; offline, fica no histórico local
                // e drainQueues republicará no próximo reconnect.
                mqttManager.publishRefuelHistory(tripManager.getRefuelHistory())
            }
        }

        tripManager.addListener(tripListener)
        carManager.addListener(carListener)
        carManager.addConnectedListener(connectedListener)

        if (carManager.isConnected) connectedListener()
        history       = tripManager.getHistory()
        chargeHistory = tripManager.getChargeHistory()

        mqttManager.onStatusChange = { s ->
            mainHandler.post {
                mqttStatus   = s
                mqttFailures = mqttManager.hasRepeatedFailures
            }
        }

        onDispose {
            tripManager.onAutoTripCompleted = null
            tripManager.onChargeSessionCompleted = null
            tripManager.onRefuelDetected         = null
            tripManager.removeListener(tripListener)
            carManager.removeListener(carListener)
            carManager.removeConnectedListener(connectedListener)
            mqttManager.onStatusChange = null
        }
    }

    // Carrega viagens na inicialização (para o card da tela principal mostrar a última viagem)
    // e também ao abrir a aba de auto-trips (com sync para o bridge).
    LaunchedEffect(Unit) {
        autoTripEntries = tripManager.getAutoTripHistory()
    }
    LaunchedEffect(showAutoTrips) {
        if (showAutoTrips) {
            autoTripEntries = tripManager.getAutoTripHistory()
            tripManager.syncAutoTripsTobridge()
        }
    }

    // ── Popup resumo da última viagem automática ──────────────────────────────
    lastCompletedTrip?.let { trip ->
        val dateFmt = remember { java.text.SimpleDateFormat("HH:mm", java.util.Locale.getDefault()) }
        val durSec  = (trip.endMs - trip.startMs) / 1000L
        val durStr  = when {
            durSec >= 3600 -> "${durSec/3600}h ${(durSec%3600)/60}min"
            durSec >= 60   -> "${durSec/60}min"
            else           -> "${durSec}s"
        }
        val kwh100  = if (trip.distKm > 0.1f) trip.netKwh / trip.distKm * 100f else 0f
        val costBrl = trip.fuelL * priceGasoline + trip.netKwh.coerceAtLeast(0f) * priceEnergy

        AlertDialog(
            onDismissRequest = { lastCompletedTrip = null },
            containerColor   = SurfaceCard,
            title = {
                Text(
                    "Viagem finalizada",
                    fontWeight = FontWeight.Bold,
                    color      = AccentBlue,
                )
            },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(
                        "${dateFmt.format(java.util.Date(trip.startMs))} → ${dateFmt.format(java.util.Date(trip.endMs))}  ·  $durStr",
                        fontSize = 12.sp,
                        color    = TextSecondary,
                    )
                    HorizontalDivider(color = Separator, thickness = 0.5.dp)
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Column {
                            Text("%.1f km".format(trip.distKm), fontSize = 18.sp, fontWeight = FontWeight.Bold, color = AccentBlue)
                            Text("distância", fontSize = 11.sp, color = TextSecondary)
                        }
                        Column {
                            Text("%.2f kWh".format(trip.netKwh), fontSize = 18.sp, fontWeight = FontWeight.Bold, color = Green)
                            Text("kWh líq.", fontSize = 11.sp, color = TextSecondary)
                        }
                        if (kwh100 > 0f) Column {
                            Text("%.1f".format(kwh100), fontSize = 18.sp, fontWeight = FontWeight.Bold, color = when {
                                kwh100 < 20f -> Green; kwh100 < 30f -> WarnYellow; else -> AccentOrange
                            })
                            Text("kWh/100km", fontSize = 11.sp, color = TextSecondary)
                        }
                    }
                    if (trip.fuelL > 0.001f || costBrl > 0.01f) {
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            if (trip.fuelL > 0.001f) Column {
                                Text("%.2f L".format(trip.fuelL), fontSize = 15.sp, fontWeight = FontWeight.Bold, color = AccentOrange)
                                Text("combustível", fontSize = 11.sp, color = TextSecondary)
                            }
                            if (costBrl > 0.01f) Column {
                                Text("R$ %.2f".format(costBrl), fontSize = 15.sp, fontWeight = FontWeight.Bold, color = WarnYellow)
                                Text("custo est.", fontSize = 11.sp, color = TextSecondary)
                            }
                        }
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = { lastCompletedTrip = null }) {
                    Text("Fechar", color = AccentBlue, fontWeight = FontWeight.SemiBold)
                }
            },
        )
    }

    if (showSettings) {
        SettingsScreen(
            backupManager = backupMgr,
            tankCapacity = tankCapacity,
            onTankChange = { newVal ->
                tankCapacity = newVal
                tripManager.setTankCapacity(newVal)
            },
            maxHistory = maxHistory,
            onMaxHistoryChange = { newVal ->
                maxHistory = newVal
                tripManager.setMaxHistoryEntries(newVal)
            },
            mqttManager = mqttManager,
            minAutoTripDist = minAutoTripDist,
            onMinAutoTripDistChange = { newVal ->
                minAutoTripDist = newVal
                tripManager.setMinAutoTripDist(newVal)
            },
            tripManager = tripManager,
            onClearAll = {
                history         = emptyList()
                chargeHistory   = emptyList()
                autoTripEntries = emptyList()
            },
            onBack = { showSettings = false },
        )
        return
    }

    if (showLog) {
        LogScreen(onBack = { showLog = false })
        return
    }

    if (showChargeHistory) {
        ChargeHistoryScreen(
            entries        = chargeHistory,
            onClearHistory = {
                tripManager.clearChargeHistory()
                chargeHistory = emptyList()
            },
            onBack = { showChargeHistory = false },
        )
        return
    }

    if (showAutoTrips) {
        AutoTripsScreen(
            entries        = autoTripEntries,
            inProgress     = inProgressTrip,
            priceGasL      = priceGasoline,
            priceEnergyKwh = priceEnergy,
            minDistKm      = minAutoTripDist,
            onRename       = { entry, name ->
                tripManager.renameAutoTripEntry(entry.startMs, name)
                autoTripEntries = tripManager.getAutoTripHistory()
            },
            onClear        = {
                tripManager.clearAutoTripHistory()
                autoTripEntries = emptyList()
            },
            onForceSync    = { onResult -> tripManager.syncAutoTripsTobridge(forceAll = true, onResult = onResult) },
            onBack         = { showAutoTrips = false },
        )
        return
    }

    // Mostra viagem ao vivo quando em andamento; caso contrário, última salva
    val displayTrip   = inProgressTrip ?: autoTripEntries.firstOrNull()
    val displayIsLive = inProgressTrip != null

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Brush.verticalGradient(listOf(VoidBlack, Color(0xFF04060A))))
            .systemBarsPadding()
            .padding(horizontal = 40.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        // ── Header: logo + status pill + update chip + 4 IconButtons ─────────
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            // Esquerda: logo + pill consolidado (versão + MQTT + carro)
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text(
                    "ECOTRIP",
                    fontSize      = 22.sp,
                    fontWeight    = FontWeight.ExtraBold,
                    color         = NeonLime,
                    letterSpacing = 3.sp,
                    style         = TextStyle(
                        shadow = Shadow(
                            color      = NeonLime.copy(alpha = 0.50f),
                            offset     = Offset.Zero,
                            blurRadius = 18f,
                        )
                    ),
                )
                // Pill: ● vX.Y · Haval H6 PHEV34   (com MQTT dot/chip embutido)
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier
                        .background(NeonLime.copy(alpha = 0.06f), RoundedCornerShape(50))
                        .border(1.dp, NeonLime.copy(alpha = 0.22f), RoundedCornerShape(50))
                        .padding(horizontal = 12.dp, vertical = 4.dp),
                ) {
                    if (mqttStatus == MqttManager.Status.CONNECTED) {
                        Box(Modifier.size(6.dp).background(NeonLime, CircleShape))
                    } else {
                        val mqttColor = when (mqttStatus) {
                            MqttManager.Status.CONNECTING -> WarnYellow
                            MqttManager.Status.ERROR      -> DangerRed
                            else                          -> TextSecondary
                        }
                        Box(Modifier.size(6.dp).background(mqttColor, CircleShape))
                    }
                    Text(
                        "v${BuildConfig.VERSION_NAME}",
                        fontSize = 13.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = NeonLime,
                    )
                    Text("·", fontSize = 13.sp, color = TextSecondary.copy(alpha = 0.4f))
                    Text(
                        "Haval H6 PHEV34",
                        fontSize = 13.sp,
                        color = TextSecondary.copy(alpha = 0.85f),
                    )
                }
            }

            // Direita: update chip + 4 IconButtons (Log, Recargas, AutoTrips, Settings)
            Row(verticalAlignment = Alignment.CenterVertically) {
                // Update area — mesmas 4 condições do design anterior
                when {
                    downloadProgress in 0..99 -> {
                        Text(
                            "$downloadProgress%",
                            fontSize   = 13.sp,
                            fontWeight = FontWeight.ExtraBold,
                            color      = NeonLime,
                            modifier   = Modifier
                                .background(NeonLime.copy(alpha = 0.10f), RoundedCornerShape(8.dp))
                                .border(1.dp, NeonLime.copy(alpha = 0.28f), RoundedCornerShape(8.dp))
                                .padding(horizontal = 12.dp, vertical = 4.dp),
                        )
                    }
                    isCheckingUpdate -> {
                        Text(
                            "...",
                            fontSize = 11.sp,
                            color    = TextSecondary,
                            modifier = Modifier.padding(end = 4.dp),
                        )
                    }
                    updateAvailable -> {
                        TextButton(
                            onClick        = { updateMgr.downloadAndInstall(context) },
                            contentPadding = PaddingValues(horizontal = 12.dp, vertical = 4.dp),
                        ) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(6.dp),
                                modifier = Modifier
                                    .background(NeonLime.copy(alpha = 0.10f), RoundedCornerShape(8.dp))
                                    .border(1.dp, NeonLime.copy(alpha = 0.28f), RoundedCornerShape(8.dp))
                                    .padding(horizontal = 12.dp, vertical = 4.dp),
                            ) {
                                Icon(
                                    Icons.Default.SystemUpdate,
                                    contentDescription = "Atualizar",
                                    tint               = NeonLime,
                                    modifier           = Modifier.size(16.dp),
                                )
                                Text(
                                    updateMgr.latestRelease?.version?.let { "v$it disponível" } ?: "Atualizar",
                                    fontSize   = 13.sp,
                                    fontWeight = FontWeight.ExtraBold,
                                    color      = NeonLime,
                                )
                            }
                        }
                    }
                    else -> {
                        TextButton(
                            onClick        = { updateMgr.checkForUpdate() },
                            contentPadding = PaddingValues(horizontal = 4.dp, vertical = 0.dp),
                        ) {
                            Text(
                                "v${BuildConfig.VERSION_NAME}",
                                fontSize = 13.sp,
                                color    = TextSecondary,
                            )
                        }
                    }
                }
                IconButton(onClick = { showLog = true }) {
                    Icon(Icons.Default.BugReport, contentDescription = "Log", tint = TextSecondary)
                }
                IconButton(onClick = { showChargeHistory = true }) {
                    Icon(Icons.Default.BatteryChargingFull, contentDescription = "Recargas", tint = AuroraTeal)
                }
                IconButton(onClick = { showAutoTrips = true }) {
                    Icon(Icons.Default.DirectionsCar, contentDescription = "Viagens Auto", tint = AccentBlue)
                }
                IconButton(onClick = { showSettings = true }) {
                    Icon(Icons.Default.Settings, contentDescription = "Configurações", tint = TextSecondary)
                }
            }
        }

        // ── Ambient gradient strip (sutil linha viva abaixo do header) ───────
        Box(
            Modifier
                .fillMaxWidth()
                .height(1.dp)
                .drawBehind {
                    drawLine(
                        brush = Brush.horizontalGradient(
                            listOf(
                                Color.Transparent,
                                NeonLime.copy(alpha = 0.35f),
                                AuroraTeal.copy(alpha = 0.35f),
                                PlasmaBlue.copy(alpha = 0.20f),
                                Color.Transparent,
                            ),
                        ),
                        start = Offset(0f, 0f),
                        end = Offset(size.width, 0f),
                        strokeWidth = 1.dp.toPx(),
                    )
                },
        )

        // ── Sub-header rolling window: "DESDE ÚLTIMA PARTIDA · X km · Zerar" ─
        Row(
            modifier = Modifier.fillMaxWidth().padding(top = 2.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                Text(
                    "DESDE ÚLTIMA PARTIDA",
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Bold,
                    letterSpacing = 2.sp,
                    color = TextSecondary.copy(alpha = 0.9f),
                )
                Text("▸", fontSize = 14.sp, color = TextSecondary.copy(alpha = 0.4f))
                Text(
                    "%.1f km".format(rolling.windowKm),
                    fontSize = 16.sp,
                    fontWeight = FontWeight.ExtraBold,
                    color = AuroraTeal,
                    style = TextStyle(
                        shadow = Shadow(AuroraTeal.copy(alpha = 0.4f), Offset.Zero, 8f),
                    ),
                )
            }
            OutlinedButton(
                onClick        = { tripManager.resetRolling() },
                contentPadding = PaddingValues(horizontal = 18.dp, vertical = 4.dp),
                border         = androidx.compose.foundation.BorderStroke(1.dp, Color.White.copy(alpha = 0.12f)),
                shape          = RoundedCornerShape(6.dp),
            ) {
                Text("Zerar", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = TextSecondary)
            }
        }

        // ── Banner de continuação: aparece quando há viagem retomável ────────
        resumableTrip?.let { last ->
            val gapMin = ((System.currentTimeMillis() - last.endMs) / 60_000L).toInt().coerceAtLeast(0)
            Surface(
                modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
                color    = SurfaceCard,
                shape    = RoundedCornerShape(10.dp),
                border   = androidx.compose.foundation.BorderStroke(1.dp, AccentBlue.copy(alpha = 0.4f)),
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Text("🔄", fontSize = 18.sp)
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            "Continuar viagem anterior?",
                            fontSize = 14.sp,
                            fontWeight = FontWeight.Bold,
                            color = TextPrimary,
                        )
                        Text(
                            "Terminou há ${gapMin} min · ${"%.1f".format(last.distKm)} km",
                            fontSize = 11.sp,
                            color = TextSecondary,
                        )
                    }
                    OutlinedButton(
                        onClick = { resumableTrip = null },
                        colors = ButtonDefaults.outlinedButtonColors(contentColor = TextSecondary),
                    ) { Text("Não", fontSize = 12.sp) }
                    Button(
                        onClick = {
                            if (tripManager.resumeLastTrip()) {
                                resumableTrip = null
                                autoTripEntries = tripManager.getAutoTripHistory()
                            }
                        },
                        colors = ButtonDefaults.buttonColors(containerColor = AccentBlue),
                    ) { Text("Continuar", fontSize = 12.sp, fontWeight = FontWeight.Bold) }
                }
            }
        }

        // ── Center zone: 3 columns (Energy | Hero+Meters | Fuel) ─────────────
        // Ultrawide 1920×720: gap maior + colunas mais largas + hero bem maior.
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f)
                .padding(top = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(36.dp),
        ) {
            // ── Coluna ESQUERDA: ⚡ Energia ──────────────────────────────────
            Column(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxHeight(),
                verticalArrangement = Arrangement.Top,
            ) {
                ColumnTitle(label = "Energia", iconColor = NeonLime, icon = Icons.Default.Bolt)
                // Bruto
                MetricBlock(
                    label = "Bruto",
                    value = "%.1f".format(rolling.energyKwh),
                    unitInline = "kWh",
                )
                // Regenerada + % + mini-bar
                val regenPct = if (rolling.energyKwh > 0.01f)
                    (rolling.regenKwh / rolling.energyKwh).coerceIn(0f, 1f)
                else 0f
                MetricBlock(
                    label = "Regenerada",
                    value = "%.1f".format(rolling.regenKwh),
                    valueColor = NeonLime,
                    unitInline = "kWh",
                    auxRight = if (regenPct > 0f) "%.0f%%".format(regenPct * 100f) else null,
                    auxColor = NeonLime,
                ) {
                    if (regenPct > 0f) {
                        Spacer(Modifier.height(4.dp))
                        MiniBar(
                            fraction = regenPct,
                            fillBrush = Brush.horizontalGradient(listOf(NeonLime, NeonLime)),
                        )
                    }
                }
                // Líquida
                MetricBlock(
                    label = "Líquida",
                    value = "%.1f".format(rolling.netKwh),
                    valueColor = WarnYellow,
                    unitInline = "kWh",
                )
                // SOC: start → current, com delta
                val socDeltaRolling = rolling.currentSocPct - rolling.startSocPct
                MetricBlock(
                    label = "SOC",
                    value = if (rolling.startSocPct > 0f || rolling.currentSocPct > 0f)
                        "%.0f%% → %.0f%%".format(rolling.startSocPct, rolling.currentSocPct)
                    else "—",
                    auxRight = if (rolling.startSocPct > 0f) "%+.0f%%".format(socDeltaRolling) else null,
                    showBottomBorder = false,
                )
            }

            // ── Centro: HeroGauge + 2 LinearMeters ──────────────────────────
            Column(
                modifier = Modifier.weight(2.2f).fillMaxHeight(),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                HeroGauge(
                    value      = rolling.netKwhPer100km,
                    maxValue   = 40f,
                    label      = "kWh/100km",
                    color      = kwhPer100kmColor(rolling.netKwhPer100km),
                    tickValues = listOf(0, 10, 20, 30, 40),
                    diameter   = 360.dp,
                    valueFontSize = 80.sp,
                )
                Row(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 0.dp),
                    horizontalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    LinearMeter(
                        value             = rolling.combinedKmL,
                        maxValue          = 100f,
                        label             = "km/L eq",
                        unitLabel         = "km/L",
                        icon              = rememberVectorPainter(Icons.Default.Bolt),
                        categoryIconColor = AuroraTeal,
                        perfColor         = kmPerLEqColor(rolling.combinedKmL),
                        tickValues        = listOf(0, 25, 50, 75, 100),
                        modifier          = Modifier.weight(1f),
                    )
                    LinearMeter(
                        value             = rolling.kmPerL,
                        maxValue          = 40f,
                        label             = "km/L",
                        unitLabel         = "km/L",
                        icon              = rememberVectorPainter(Icons.Default.LocalGasStation),
                        categoryIconColor = MoltenOrange,
                        perfColor         = kmPerLColor(rolling.kmPerL),
                        tickValues        = listOf(0, 10, 20, 30, 40),
                        modifier          = Modifier.weight(1f),
                    )
                }
            }

            // ── Coluna DIREITA: ⛽ Combustível ───────────────────────────────
            Column(
                modifier = Modifier.weight(1f).fillMaxHeight(),
                verticalArrangement = Arrangement.Top,
            ) {
                ColumnTitle(label = "Combustível", iconColor = MoltenOrange, icon = Icons.Default.LocalGasStation)
                // Consumido (L)
                MetricBlock(
                    label = "Consumido",
                    value = "%.1f".format(rolling.fuelL),
                    valueColor = MoltenOrange,
                    unitInline = "L",
                )
                // Tanque start→current + mini-bar (% atual do tanque)
                val tankFrac = if (tankCapacity > 0.1f) (rolling.currentTankL / tankCapacity).coerceIn(0f, 1f) else 0f
                val tankSpent = rolling.startTankL - rolling.currentTankL
                MetricBlock(
                    label = "Tanque",
                    value = if (rolling.startTankL > 0f || rolling.currentTankL > 0f)
                        "%.1f → %.1f".format(rolling.startTankL, rolling.currentTankL)
                    else "—",
                    unitInline = "L",
                    auxRight = if (tankSpent > 0.01f) "%.1f L gastos".format(tankSpent) else null,
                ) {
                    if (tankFrac > 0f) {
                        Spacer(Modifier.height(4.dp))
                        MiniBar(
                            fraction = tankFrac,
                            fillBrush = Brush.horizontalGradient(listOf(MoltenOrange, Color(0xFFFFB890))),
                        )
                    }
                }
                // Custo total
                MetricBlock(
                    label = "Custo total",
                    value = if (rolling.costBrl > 0.01f) "R$ %.2f".format(rolling.costBrl) else "—",
                    valueColor = WarnYellow,
                )
                // Custo por km com bullet chart
                val costPerKm = rolling.costPerKm
                val costStatus = costPerKmStatus(costPerKm)
                MetricBlock(
                    label = "Custo por km",
                    value = if (costPerKm > 0f) "R$ %.3f".format(costPerKm) else "—",
                    valueColor = WarnYellow.copy(alpha = 0.95f),
                    auxRight = if (costPerKm > 0f) null else null,
                    showBottomBorder = false,
                ) {
                    if (costPerKm > 0f) {
                        Spacer(Modifier.height(6.dp))
                        BulletBar(
                            value = costPerKm,
                            maxScale = 0.60f,
                            metaPosition = 0.30f,
                            yellowEnd = 0.45f,
                        )
                        Row(
                            modifier = Modifier.fillMaxWidth().padding(top = 5.dp),
                            horizontalArrangement = Arrangement.SpaceBetween,
                        ) {
                            Text("R$ 0",     fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = TextSecondary.copy(alpha = 0.6f))
                            Text("R$ 0,60+", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = TextSecondary.copy(alpha = 0.6f))
                        }
                    }
                }
                // Badge de status alinhado no top do bloco (mostra no header do "Custo por km")
                // — fica fora do bloco pra acompanhar a label visualmente; ajustar se preferir embutido.
                if (costPerKm > 0f) {
                    Spacer(Modifier.height(4.dp))
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.End,
                    ) {
                        StatusBadge(label = costStatus.label, color = costStatus.color)
                    }
                }
            }
        }

        // ── Strip inferior: viagem em andamento / última viagem ──────────────
        if (displayTrip != null) {
            StripSection(
                trip = displayTrip,
                isLive = displayIsLive,
                nowMs = nowMs,
            )
        }
    }
}

// ── Helpers do header das colunas Energia/Combustível ─────────────────────────
@Composable
private fun ColumnTitle(
    label: String,
    iconColor: androidx.compose.ui.graphics.Color,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(bottom = 5.dp)
            .drawBehind {
                drawLine(
                    color = Color.White.copy(alpha = 0.06f),
                    start = Offset(0f, size.height),
                    end = Offset(size.width, size.height),
                    strokeWidth = 1f,
                )
            }
            .padding(bottom = 5.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = iconColor.copy(alpha = 0.85f),
            modifier = Modifier.size(17.dp),
        )
        Text(
            text = label.uppercase(),
            fontSize = 14.sp,
            fontWeight = FontWeight.Bold,
            letterSpacing = 2.sp,
            color = TextSecondary.copy(alpha = 0.8f),
        )
    }
}

// ── Strip inferior: viagem em andamento / última viagem ──────────────────────
// Substitui o antigo InProgressTripCard. Layout horizontal estilo "status bar"
// + 2 linhas de métricas (primárias grandes, secundárias menores).

@Composable
private fun StripSection(
    trip:   AutoTripEntry,
    isLive: Boolean,
    nowMs:  Long,
    modifier: Modifier = Modifier,
) {
    // Tempo: ao vivo = elapsed desde startMs; salva = duração real endMs-startMs
    val timeSec = if (isLive)
        ((nowMs - trip.startMs) / 1000L).coerceAtLeast(0L)
    else
        ((trip.endMs - trip.startMs) / 1000L).coerceAtLeast(trip.timeSec)
    val timeStr = when {
        timeSec >= 3600 -> "${timeSec / 3600}h ${(timeSec % 3600) / 60}min"
        timeSec >= 60   -> "${timeSec / 60}min"
        else            -> "${timeSec}s"
    }

    val kwh100   = if (trip.distKm > 0.5f) trip.netKwh / trip.distKm * 100f else 0f
    val kmlEq    = if (trip.distKm > 0.1f && (trip.netKwh > 0f || trip.fuelL > 0.001f))
        trip.distKm / (trip.netKwh / 8.9f + trip.fuelL) else 0f
    val socDelta = trip.endSocPct - trip.startSocPct

    val dateFmt = remember(trip.startMs) {
        java.text.SimpleDateFormat(
            if (isLive) "HH:mm" else "dd/MM  HH:mm",
            java.util.Locale.getDefault()
        ).format(java.util.Date(trip.startMs))
    }

    val accentColor = if (isLive) AccentBlue else TextSecondary

    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(top = 4.dp)
            .drawBehind {
                // Separador horizontal no topo da seção
                drawLine(
                    color = Color.White.copy(alpha = 0.04f),
                    start = Offset(0f, 0f),
                    end = Offset(size.width, 0f),
                    strokeWidth = 1f,
                )
            }
            .padding(top = 10.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        // ── Linha 1: indicador live + label + km + horário + duração + SOC bar
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                if (isLive) Box(Modifier.size(10.dp).background(AccentBlue, CircleShape))
                Text(
                    if (isLive) "VIAGEM EM ANDAMENTO" else "ÚLTIMA VIAGEM",
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Bold,
                    letterSpacing = 1.8.sp,
                    color = accentColor,
                )
                Text("▸", fontSize = 13.sp, color = TextSecondary.copy(alpha = 0.4f))
                Text(
                    "%.1f km".format(trip.distKm),
                    fontSize = 15.sp,
                    fontWeight = FontWeight.ExtraBold,
                    color = AuroraTeal,
                    style = TextStyle(shadow = Shadow(AuroraTeal.copy(alpha = 0.4f), Offset.Zero, 8f)),
                )
                Text("▸", fontSize = 13.sp, color = TextSecondary.copy(alpha = 0.4f))
                Text(
                    if (isLive) "desde $dateFmt" else dateFmt,
                    fontSize = 13.sp,
                    color = TextSecondary,
                )
                Text("▸", fontSize = 13.sp, color = TextSecondary.copy(alpha = 0.4f))
                Text(
                    timeStr,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = accentColor,
                )
            }

            // SOC bar (decisão do usuário: usa SOC da VIAGEM — trip.startSocPct e trip.endSocPct)
            // Largura limitada a 360dp pra não se estender pela tela toda; alinhado à direita.
            Spacer(modifier = Modifier.weight(1f))
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier.width(360.dp),
            ) {
                Text(
                    "SOC",
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Bold,
                    letterSpacing = 1.4.sp,
                    color = TextSecondary,
                )
                SocStripBar(
                    startSocPct   = trip.startSocPct,
                    currentSocPct = trip.endSocPct,
                    modifier = Modifier.weight(1f),
                )
                Text(
                    "%.0f%%".format(trip.endSocPct),
                    fontSize = 16.sp,
                    fontWeight = FontWeight.Bold,
                    color = AuroraTeal,
                    style = TextStyle(shadow = Shadow(AuroraTeal.copy(alpha = 0.4f), Offset.Zero, 8f)),
                )
            }
        }

        // ── Linha 2: métricas primárias (grandes, 32sp) ───────────────────────
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceEvenly,
        ) {
            StripMetric(
                value = if (trip.distKm > 0f) "%.1f".format(trip.distKm) else "--",
                unit  = "km",
                color = AccentBlue,
                big   = true,
            )
            StripMetric(
                value = if (kwh100 > 0f) "%.1f".format(kwh100) else "--",
                unit  = "kWh/100km",
                color = kwhPer100kmColor(kwh100),
                big   = true,
            )
            StripMetric(
                value = if (kmlEq > 0f) "%.1f".format(kmlEq) else "--",
                unit  = "km/L eq",
                color = kmPerLEqColor(kmlEq),
                big   = true,
            )
        }

        // ── Linha 3: métricas secundárias ─────────────────────────────────────
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceEvenly,
        ) {
            StripMetric(
                value = if (trip.startSocPct > 0f) "%+.0f%%".format(socDelta) else "--",
                unit  = "SOC Δ",
                color = when {
                    socDelta < -20f -> AccentOrange
                    socDelta < 0f   -> AuroraTeal
                    else            -> TextSecondary
                },
            )
            StripMetric(
                value = if (trip.netKwh > 0.01f) "%.2f kWh".format(trip.netKwh) else "--",
                unit  = "elétrico líq.",
                color = AuroraTeal,
            )
            StripMetric(
                value = if (trip.fuelL > 0.001f) "%.2f L".format(trip.fuelL) else "--",
                unit  = "combustível",
                color = AccentOrange,
            )
        }
    }
}

@Composable
private fun StripMetric(
    value: String,
    unit:  String,
    color: Color,
    big:   Boolean = false,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier            = modifier,
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Text(
            value,
            fontSize   = if (big) 42.sp else 26.sp,
            fontWeight = FontWeight.ExtraBold,
            color      = color,
            letterSpacing = (-1.2).sp,
            style = TextStyle(
                shadow = if (big) Shadow(color.copy(alpha = 0.4f), Offset.Zero, 12f) else null
            ),
        )
        Text(
            unit,
            fontSize = 13.sp,
            color    = TextSecondary,
            letterSpacing = 0.6.sp,
        )
    }
}

