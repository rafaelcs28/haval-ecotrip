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
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.BugReport
import androidx.compose.material.icons.filled.BarChart
import androidx.compose.material.icons.filled.SystemUpdate
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Shadow
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
import br.com.redesurftank.ecotrip.ui.components.RollingWindowCard
import br.com.redesurftank.ecotrip.ui.theme.*

private val mainHandler = Handler(Looper.getMainLooper())

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

    var showHistory       by remember { mutableStateOf(false) }
    var showChargeHistory by remember { mutableStateOf(false) }
    var showAutoTrips     by remember { mutableStateOf(false) }
    var showStats         by remember { mutableStateOf(false) }
    var showSettings      by remember { mutableStateOf(false) }
    var showLog           by remember { mutableStateOf(false) }
    var minAutoTripDist   by remember { mutableStateOf(tripManager.getMinAutoTripDist()) }
    var lastCompletedTrip by remember { mutableStateOf<AutoTripEntry?>(null) }
    // Lista de viagens automáticas — carregada uma vez quando a tela é aberta e
    // actualizada após renomear ou limpar. Evita chamar getAutoTripHistory() a cada
    // recomposição (que criaria uma nova lista instável e poderia causar loops).
    var autoTripEntries   by remember { mutableStateOf<List<AutoTripEntry>>(emptyList()) }

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
                        tripManager.onDrivingReady(state)
                    }
                    CarConstants.CAR_EV_INFO_CUR_CHARGE_CURRENT.value -> {
                        mqttManager.latestChargeCurrentA = value.trim().toFloatOrNull() ?: 0f
                        // Potência do motor: V (car.ev_info.power_battery_voltage) × A / 1000 = kW
                        val motorKw = mqttManager.latestBatteryVoltageV * mqttManager.latestChargeCurrentA / 1000f
                        mqttManager.latestMotorPowerKw = motorKw
                        tripManager.updateMotorPowerKw(motorKw)
                        syncCharging()
                    }
                    CarConstants.CAR_BASIC_BATTERY_VOLTAGE.value -> {
                        // Apenas armazena — não entra no cálculo de potência
                        mqttManager.latestBasicBattVoltageV = value.trim().toFloatOrNull() ?: 0f
                    }
                    CarConstants.CAR_EV_INFO_POWER_BATTERY_VOLTAGE.value -> {
                        mqttManager.latestBatteryVoltageV = value.trim().toFloatOrNull() ?: 0f
                        // Recalcula potência do motor com nova tensão
                        val motorKw = mqttManager.latestBatteryVoltageV * mqttManager.latestChargeCurrentA / 1000f
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
                    CarConstants.CAR_HVAC_FAN_SPEED.value -> {
                        mqttManager.latestHvacFanSpeed = value.trim().toIntOrNull() ?: 0
                    }
                    CarConstants.CAR_HVAC_SYNC_ENABLE.value -> {
                        mqttManager.latestHvacSyncEnable = value.trim().toIntOrNull() ?: 0
                    }
                    CarConstants.CAR_HVAC_AUTO_ENABLE.value -> {
                        mqttManager.latestHvacAutoEnable = value.trim().toIntOrNull() ?: 0
                    }
                    else -> tripManager.onDataChanged(key, value)
                }
                // Publica imediatamente quando qualquer sinal muda (debounce 1s interno)
                mqttManager.markChanged()
            }
        }

        val connectedListener: () -> Unit = {
            try {
                // Fetch vehicle model for MQTT discovery before connecting
                mqttManager.vehicleModel1 = carManager.fetchCurrent(CarConstants.CAR_BASIC_VEHICLE_MODEL1.value)?.trim() ?: ""
                mqttManager.vehicleModel2 = carManager.fetchCurrent(CarConstants.CAR_BASIC_VEHICLE_MODEL2.value)?.trim() ?: ""

                val powerMode = carManager.fetchCurrent(CarConstants.CAR_BASIC_POWER_MODE.value)
                val mode = powerMode?.trim()?.toIntOrNull() ?: 0
                if (mode in 1..3) tripManager.onSessionStart()

                // Busca imediata de combustível e SOC — estas chaves chegam raramente via listener
                // passivo, então lemos ativamente na conexão para não ficar zerado até o próximo update.
                carManager.fetchCurrent(CarConstants.CAR_BASIC_REMAIN_FUEL_PERCENTAGE.value)
                    ?.trim()?.let { tripManager.onDataChanged(CarConstants.CAR_BASIC_REMAIN_FUEL_PERCENTAGE.value, it) }

                carManager.fetchCurrent(CarConstants.CAR_EV_INFO_SOC_OF_BATTERY.value)
                    ?.trim()?.let { tripManager.onDataChanged(CarConstants.CAR_EV_INFO_SOC_OF_BATTERY.value, it) }

                carManager.fetchCurrent(CarConstants.CAR_EV_INFO_BATTERY_CHARGE_PERCENTAGE.value)
                    ?.trim()?.let { tripManager.onDataChanged(CarConstants.CAR_EV_INFO_BATTERY_CHARGE_PERCENTAGE.value, it) }

                // Motor power % em tempo real (energy_output_percentage) — busca imediata ao conectar
                carManager.fetchCurrent(CarConstants.CAR_EV_INFO_ENERGY_OUTPUT_PERCENTAGE.value)
                    ?.trim()?.let { raw ->
                        raw.toIntOrNull()?.let { mqttManager.latestBattPowerPct = it }
                        tripManager.onDataChanged(CarConstants.CAR_EV_INFO_ENERGY_OUTPUT_PERCENTAGE.value, raw)
                    }

                // SOC da bateria (cur_battery_power_percentage) — busca imediata para SOC inicial
                carManager.fetchCurrent(CarConstants.CAR_EV_INFO_CUR_BATTERY_POWER_PERCENTAGE.value)
                    ?.trim()?.let { tripManager.onDataChanged(CarConstants.CAR_EV_INFO_CUR_BATTERY_POWER_PERCENTAGE.value, it) }

                // Busca imediata de driving_ready_state — inicia trip automático se carro já estiver ligado
                // (feito após busca de SOC/fuel para que latestSocPct/latestFuelPct estejam disponíveis)
                carManager.fetchCurrent(CarConstants.CAR_BASIC_DRIVING_READY_STATE.value)
                    ?.trim()?.toIntOrNull()?.let { tripManager.onDrivingReady(it) }

                // Busca imediata de temperaturas — chegam raramente via listener passivo
                carManager.fetchCurrent(CarConstants.CAR_BASIC_OUTSIDE_TEMP.value)
                    ?.trim()?.toFloatOrNull()?.let { mqttManager.latestOutsideTemp = it }
                carManager.fetchCurrent(CarConstants.CAR_BASIC_INSIDE_TEMP.value)
                    ?.trim()?.toFloatOrNull()?.let { mqttManager.latestInsideTemp = it }

                // Busca imediata do limite de carga SOC para sincronizar com HA
                carManager.fetchCurrent(CarConstants.CAR_EV_SETTING_CHARGE_SOC_LIMIT.value)
                    ?.trim()?.toIntOrNull()?.let { mqttManager.syncChargeLimitFromCar(it) }

                // Busca imediata de medidas elétricas do pack de bateria
                // Tensão e corrente — busca em ordem para calcular potência do motor ao conectar
                carManager.fetchCurrent(CarConstants.CAR_BASIC_BATTERY_VOLTAGE.value)
                    ?.trim()?.toFloatOrNull()?.let { mqttManager.latestBasicBattVoltageV = it }
                carManager.fetchCurrent(CarConstants.CAR_EV_INFO_CUR_CHARGE_CURRENT.value)
                    ?.trim()?.toFloatOrNull()?.let { amps ->
                        mqttManager.latestChargeCurrentA = amps
                        val motorKw = mqttManager.latestBasicBattVoltageV * amps / 1000f
                        mqttManager.latestMotorPowerKw = motorKw
                        tripManager.updateMotorPowerKw(motorKw)
                    }
                carManager.fetchCurrent(CarConstants.CAR_EV_INFO_POWER_BATTERY_VOLTAGE.value)
                    ?.trim()?.toFloatOrNull()?.let { mqttManager.latestBatteryVoltageV = it }
                carManager.fetchCurrent(CarConstants.CAR_EV_INFO_POWER_BATTERY_CURRENT.value)
                    ?.trim()?.toFloatOrNull()?.let { mqttManager.latestBatteryCurrentA = it }
                carManager.fetchCurrent(CarConstants.CAR_EV_INFO_CHARGING_STATE.value)
                    ?.trim()?.toIntOrNull()?.let { mqttManager.latestChargingState = it }
                carManager.fetchCurrent(CarConstants.CAR_EV_INFO_CHARGE_REMAINING_TIME.value)
                    ?.trim()?.toIntOrNull()?.let { mqttManager.latestChargeRemainingMin = it }
                // Notifica TripManager com o estado inicial de carga após busca dos valores elétricos
                syncCharging()

                // Odômetro total — muda raramente; busca ativa ao conectar para ter logo o valor
                carManager.fetchCurrent(CarConstants.CAR_BASIC_TOTAL_ODOMETER.value)
                    ?.trim()?.toFloatOrNull()?.let { mqttManager.latestOdometerKm = it }

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

    if (showStats) {
        StatsScreen(tripManager = tripManager, onBack = { showStats = false })
        return
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
            priceGasoline = priceGasoline,
            onPriceGasolineChange = { newVal ->
                priceGasoline = newVal
                tripManager.setPriceGasoline(newVal)
            },
            priceEnergy = priceEnergy,
            onPriceEnergyChange = { newVal ->
                priceEnergy = newVal
                tripManager.setPriceEnergy(newVal)
            },
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

    if (showHistory) {
        HistoryScreen(
            entries        = history,
            onClearHistory = {
                tripManager.clearHistory()
                history = emptyList()
            },
            onDeleteEntry  = { entry ->
                tripManager.deleteHistoryEntry(entry)
                history = tripManager.getHistory()
            },
            onRenameEntry  = { entry, name ->
                tripManager.renameTripHistoryEntry(entry.timestampMs, name)
                history = tripManager.getHistory()
                mqttManager.publishTripHistory(history)
            },
            onBack = { showHistory = false },
        )
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

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(VoidBlack)
            .systemBarsPadding()
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            // ── Left: title + version badge + connection dot + car name
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Text(
                    "ECOTRIP",
                    fontSize      = 19.sp,
                    fontWeight    = FontWeight.ExtraBold,
                    color         = NeonLime,
                    letterSpacing = 2.sp,
                    style         = TextStyle(
                        shadow = Shadow(
                            color      = NeonLime.copy(alpha = 0.45f),
                            offset     = Offset.Zero,
                            blurRadius = 18f,
                        )
                    ),
                )
                Text(
                    "v${BuildConfig.VERSION_NAME}",
                    fontSize   = 10.sp,
                    fontWeight = FontWeight.SemiBold,
                    color      = NeonLime.copy(alpha = 0.7f),
                    modifier   = Modifier
                        .background(NeonLime.copy(alpha = 0.08f), RoundedCornerShape(5.dp))
                        .border(1.dp, NeonLime.copy(alpha = 0.2f), RoundedCornerShape(5.dp))
                        .padding(horizontal = 7.dp, vertical = 2.dp),
                )
                if (mqttStatus == MqttManager.Status.CONNECTED) {
                    Box(Modifier.size(6.dp).background(NeonLime, CircleShape))
                } else {
                    val (mqttLabel, mqttColor) = when (mqttStatus) {
                        MqttManager.Status.CONNECTING   -> "MQTT..." to WarnYellow
                        MqttManager.Status.ERROR        -> "MQTT erro" to androidx.compose.ui.graphics.Color(0xFFFF4444)
                        else                            -> "MQTT off"  to TextSecondary
                    }
                    Text(
                        mqttLabel,
                        fontSize = 9.sp,
                        color    = mqttColor,
                        modifier = Modifier
                            .background(mqttColor.copy(alpha = 0.12f), RoundedCornerShape(4.dp))
                            .border(1.dp, mqttColor.copy(alpha = 0.35f), RoundedCornerShape(4.dp))
                            .padding(horizontal = 5.dp, vertical = 2.dp),
                    )
                }
                Text("Haval H6 PHEV34", fontSize = 11.sp, color = TextSecondary.copy(alpha = 0.6f))
            }

            // ── Right: update chip + action buttons
            Row(verticalAlignment = Alignment.CenterVertically) {
                // Update area — sempre visível; clique verifica manualmente
                when {
                    downloadProgress in 0..99 -> {
                        // Baixando: mostra progresso
                        Text(
                            "$downloadProgress%",
                            fontSize   = 11.sp,
                            fontWeight = FontWeight.ExtraBold,
                            color      = NeonLime,
                            modifier   = Modifier
                                .background(NeonLime.copy(alpha = 0.10f), RoundedCornerShape(8.dp))
                                .border(1.dp, NeonLime.copy(alpha = 0.28f), RoundedCornerShape(8.dp))
                                .padding(horizontal = 12.dp, vertical = 4.dp),
                        )
                    }
                    isCheckingUpdate -> {
                        // Verificando: mostra indicador
                        Text(
                            "...",
                            fontSize = 11.sp,
                            color    = TextSecondary,
                            modifier = Modifier.padding(end = 4.dp),
                        )
                    }
                    updateAvailable -> {
                        // Nova versão disponível: chip verde de download
                        androidx.compose.material3.TextButton(
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
                                    modifier           = Modifier.size(14.dp),
                                )
                                Text(
                                    updateMgr.latestRelease?.version?.let { "v$it disponível" } ?: "Atualizar",
                                    fontSize   = 11.sp,
                                    fontWeight = FontWeight.ExtraBold,
                                    color      = NeonLime,
                                )
                            }
                        }
                    }
                    else -> {
                        // Em dia: mostra versão atual cinza — clicável para verificar
                        androidx.compose.material3.TextButton(
                            onClick        = { updateMgr.checkForUpdate() },
                            contentPadding = PaddingValues(horizontal = 4.dp, vertical = 0.dp),
                        ) {
                            Text(
                                "v${BuildConfig.VERSION_NAME}",
                                fontSize = 11.sp,
                                color    = TextSecondary,
                            )
                        }
                    }
                }
                IconButton(onClick = { showLog = true }) {
                    Icon(Icons.Default.BugReport, contentDescription = "Log", tint = TextSecondary)
                }
                IconButton(onClick = { showStats = true }) {
                    Icon(Icons.Default.BarChart, contentDescription = "Estatísticas", tint = Green)
                }
                IconButton(onClick = { showChargeHistory = true }) {
                    Icon(Icons.Default.BatteryChargingFull, contentDescription = "Recargas", tint = AuroraTeal)
                }
                IconButton(onClick = { showAutoTrips = true }) {
                    Icon(Icons.Default.DirectionsCar, contentDescription = "Viagens Auto", tint = AccentBlue)
                }
                IconButton(onClick = { showHistory = true }) {
                    Icon(Icons.Default.History, contentDescription = "Histórico", tint = TextSecondary)
                }
                IconButton(onClick = { showSettings = true }) {
                    Icon(Icons.Default.Settings, contentDescription = "Configurações", tint = TextSecondary)
                }
            }
        }

        RollingWindowCard(
            snapshot = rolling,
            onReset  = { tripManager.resetRolling() },
            modifier = Modifier.fillMaxWidth(),
        )

        // Mostra viagem ao vivo quando em andamento; caso contrário, última salva
        val displayTrip   = inProgressTrip ?: autoTripEntries.firstOrNull()
        val displayIsLive = inProgressTrip != null
        if (displayTrip != null) {
            InProgressTripCard(
                trip     = displayTrip,
                isLive   = displayIsLive,
                nowMs    = nowMs,
                modifier = Modifier.fillMaxWidth(),
            )
        }

    }

}

// ── Card: Viagem em andamento / Última viagem ─────────────────────────────────

@Composable
private fun InProgressTripCard(
    trip:     AutoTripEntry,
    isLive:   Boolean,
    nowMs:    Long,
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
            .background(GlassCard, RoundedCornerShape(16.dp))
            .border(1.dp, accentColor.copy(alpha = 0.28f), RoundedCornerShape(16.dp))
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        // ── Cabeçalho ─────────────────────────────────────────────────────────
        Row(
            modifier              = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment     = Alignment.CenterVertically,
        ) {
            Row(
                verticalAlignment     = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(7.dp),
            ) {
                if (isLive) Box(Modifier.size(8.dp).background(AccentBlue, CircleShape))
                Text(
                    if (isLive) "VIAGEM EM ANDAMENTO" else "ÚLTIMA VIAGEM",
                    fontSize      = 12.sp,
                    fontWeight    = FontWeight.Bold,
                    letterSpacing = 1.6.sp,
                    color         = accentColor,
                )
            }
            Row(
                verticalAlignment     = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Text(
                    if (isLive) "desde $dateFmt" else dateFmt,
                    fontSize = 12.sp,
                    color    = TextSecondary,
                )
                Text(
                    timeStr,
                    fontSize   = 15.sp,
                    fontWeight = FontWeight.SemiBold,
                    color      = accentColor,
                )
            }
        }

        // ── Linha 1: métricas principais ──────────────────────────────────────
        Row(
            modifier              = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceEvenly,
        ) {
            TripMetricCell(
                value    = if (trip.distKm > 0f) "%.1f".format(trip.distKm) else "--",
                unit     = "km",
                color    = AccentBlue,
                bigValue = true,
            )
            TripMetricCell(
                value    = if (kwh100 > 0f) "%.1f".format(kwh100) else "--",
                unit     = "kWh/100km",
                color    = when {
                    kwh100 <= 0f -> TextSecondary
                    kwh100 < 20f -> NeonLime
                    kwh100 < 30f -> WarnYellow
                    else         -> AccentOrange
                },
                bigValue = true,
            )
            TripMetricCell(
                value    = if (kmlEq > 0f) "%.1f".format(kmlEq) else "--",
                unit     = "km/L eq",
                color    = NeonLime,
                bigValue = true,
            )
        }

        // ── Linha 2: métricas secundárias ─────────────────────────────────────
        Row(
            modifier              = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceEvenly,
        ) {
            TripMetricCell(
                value = if (trip.startSocPct > 0f) "%+.0f%%".format(socDelta) else "--",
                unit  = "SOC Δ",
                color = when {
                    socDelta < -20f -> AccentOrange
                    socDelta < 0f   -> AuroraTeal
                    else            -> TextSecondary
                },
            )
            TripMetricCell(
                value = if (trip.netKwh > 0.01f) "%.2f kWh".format(trip.netKwh) else "--",
                unit  = "elétrico líq.",
                color = AuroraTeal,
            )
            TripMetricCell(
                value = if (trip.fuelL > 0.001f) "%.2f L".format(trip.fuelL) else "--",
                unit  = "combustível",
                color = AccentOrange,
            )
        }
    }
}

@Composable
private fun TripMetricCell(
    value:    String,
    unit:     String,
    color:    androidx.compose.ui.graphics.Color,
    bigValue: Boolean = false,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier            = modifier,
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        Text(
            value,
            fontSize   = if (bigValue) 26.sp else 18.sp,
            fontWeight = FontWeight.ExtraBold,
            color      = color,
        )
        Text(
            unit,
            fontSize = 11.sp,
            color    = TextSecondary,
        )
    }
}

