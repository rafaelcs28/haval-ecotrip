package br.com.redesurftank.ecotrip.ui.screens

import android.os.Handler
import android.os.Looper
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import kotlinx.coroutines.delay
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.material.icons.filled.BatteryChargingFull
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.BugReport
import androidx.compose.material.icons.filled.SystemUpdate
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
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
import br.com.redesurftank.ecotrip.managers.CarDataManager
import br.com.redesurftank.ecotrip.managers.MqttManager
import br.com.redesurftank.ecotrip.managers.ChargeHistoryEntry
import br.com.redesurftank.ecotrip.managers.RollingSnapshot
import br.com.redesurftank.ecotrip.managers.TripHistoryEntry
import br.com.redesurftank.ecotrip.managers.TripId
import br.com.redesurftank.ecotrip.managers.TripManager
import br.com.redesurftank.ecotrip.managers.TripSnapshot
import br.com.redesurftank.ecotrip.managers.UpdateManager
import br.com.redesurftank.ecotrip.models.CarConstants
import br.com.redesurftank.ecotrip.ui.components.RollingWindowCard
import br.com.redesurftank.ecotrip.ui.components.TripCard
import br.com.redesurftank.ecotrip.ui.theme.*

private val mainHandler = Handler(Looper.getMainLooper())

@Composable
fun ConsumptionScreen() {
    val context     = LocalContext.current
    val tripManager = remember { TripManager.getInstance() }
    val carManager  = remember { CarDataManager.getInstance() }
    val mqttManager = remember { MqttManager.getInstance() }
    val updateMgr   = remember { UpdateManager.getInstance() }

    var snapA   by remember { mutableStateOf(TripSnapshot(0f, 0f, 0f, 0f, 0L, emptyList())) }
    var snapB   by remember { mutableStateOf(TripSnapshot(0f, 0f, 0f, 0f, 0L, emptyList())) }
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
    var updateAvailable  by remember { mutableStateOf(updateMgr.isUpdateAvailable) }
    var isCheckingUpdate by remember { mutableStateOf(updateMgr.isChecking) }
    var downloadProgress by remember { mutableStateOf(updateMgr.downloadProgress) }

    // Check on startup + repeat every 10 min while app is running
    LaunchedEffect(Unit) {
        updateMgr.checkForUpdate()
        updateMgr.startPeriodicCheck(10)
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
            if (ticks % 5 == 0) tripManager.tickTime()
        }
    }

    var showHistory       by remember { mutableStateOf(false) }
    var showChargeHistory by remember { mutableStateOf(false) }
    var showSettings      by remember { mutableStateOf(false) }
    var showLog           by remember { mutableStateOf(false) }

    DisposableEffect(Unit) {
        val tripListener: (TripSnapshot, TripSnapshot, RollingSnapshot) -> Unit = { a, b, r ->
            mainHandler.post {
                snapA = a; snapB = b; rolling = r
                history = tripManager.getHistory()
                mqttManager.publish(a, b, r)
            }
        }

        // Recalcula potência de recarga e notifica TripManager quando qualquer
        // dado elétrico relevante muda (estado, corrente ou tensão).
        fun syncCharging() {
            val state   = mqttManager.latestChargingState
            val powerKw = if (state == 1 && mqttManager.latestBatteryVoltageV > 0f)
                mqttManager.latestChargeCurrentA * mqttManager.latestBatteryVoltageV / 1000f * -1f
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
                    CarConstants.CAR_EV_INFO_CUR_CHARGE_CURRENT.value -> {
                        mqttManager.latestChargeCurrentA = value.trim().toFloatOrNull() ?: 0f
                        syncCharging()
                    }
                    CarConstants.CAR_EV_INFO_POWER_BATTERY_VOLTAGE.value -> {
                        mqttManager.latestBatteryVoltageV = value.trim().toFloatOrNull() ?: 0f
                        syncCharging()
                    }
                    CarConstants.CAR_EV_INFO_POWER_BATTERY_CURRENT.value -> {
                        mqttManager.latestBatteryCurrentA = value.trim().toFloatOrNull() ?: 0f
                    }
                    CarConstants.CAR_EV_INFO_CHARGING_STATE.value -> {
                        mqttManager.latestChargingState = value.trim().toIntOrNull() ?: -1
                        syncCharging()
                    }
                    else -> tripManager.onDataChanged(key, value)
                }
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

                carManager.fetchCurrent(CarConstants.CAR_EV_INFO_CUR_BATTERY_POWER_PERCENTAGE.value)
                    ?.trim()?.let { tripManager.onDataChanged(CarConstants.CAR_EV_INFO_CUR_BATTERY_POWER_PERCENTAGE.value, it) }

                // Busca imediata de temperaturas — chegam raramente via listener passivo
                carManager.fetchCurrent(CarConstants.CAR_BASIC_OUTSIDE_TEMP.value)
                    ?.trim()?.toFloatOrNull()?.let { mqttManager.latestOutsideTemp = it }
                carManager.fetchCurrent(CarConstants.CAR_BASIC_INSIDE_TEMP.value)
                    ?.trim()?.toFloatOrNull()?.let { mqttManager.latestInsideTemp = it }

                // Busca imediata do limite de carga SOC para sincronizar com HA
                carManager.fetchCurrent(CarConstants.CAR_EV_SETTING_CHARGE_SOC_LIMIT.value)
                    ?.trim()?.toIntOrNull()?.let { mqttManager.syncChargeLimitFromCar(it) }

                // Busca imediata de medidas elétricas do pack de bateria
                carManager.fetchCurrent(CarConstants.CAR_EV_INFO_CUR_CHARGE_CURRENT.value)
                    ?.trim()?.toFloatOrNull()?.let { mqttManager.latestChargeCurrentA = it }
                carManager.fetchCurrent(CarConstants.CAR_EV_INFO_POWER_BATTERY_VOLTAGE.value)
                    ?.trim()?.toFloatOrNull()?.let { mqttManager.latestBatteryVoltageV = it }
                carManager.fetchCurrent(CarConstants.CAR_EV_INFO_POWER_BATTERY_CURRENT.value)
                    ?.trim()?.toFloatOrNull()?.let { mqttManager.latestBatteryCurrentA = it }
                carManager.fetchCurrent(CarConstants.CAR_EV_INFO_CHARGING_STATE.value)
                    ?.trim()?.toIntOrNull()?.let { mqttManager.latestChargingState = it }
                // Notifica TripManager com o estado inicial de carga após busca dos valores elétricos
                syncCharging()

            } catch (_: Exception) {}
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
            tripManager.removeListener(tripListener)
            carManager.removeListener(carListener)
            carManager.removeConnectedListener(connectedListener)
            mqttManager.onStatusChange = null
        }
    }

    if (showSettings) {
        SettingsScreen(
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

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(VoidBlack)
            .systemBarsPadding()
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(7.dp),
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
                val dotColor = when (mqttStatus) {
                    MqttManager.Status.CONNECTED    -> NeonLime
                    MqttManager.Status.CONNECTING   -> WarnYellow
                    MqttManager.Status.ERROR        -> androidx.compose.ui.graphics.Color(0xFFFF4444)
                    MqttManager.Status.DISCONNECTED -> TextSecondary
                }
                Box(Modifier.size(6.dp).background(dotColor, CircleShape))
                Text("Haval H6 HEV", fontSize = 11.sp, color = TextSecondary.copy(alpha = 0.6f))
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
                IconButton(onClick = { showChargeHistory = true }) {
                    Icon(Icons.Default.BatteryChargingFull, contentDescription = "Recargas", tint = AuroraTeal)
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

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f),
            horizontalArrangement = Arrangement.spacedBy(7.dp),
        ) {
            TripCard(
                label    = "Trip A",
                snapshot = snapA,
                onReset  = { name ->
                    mqttManager.publishTripCompleted("trip_a", snapA, name)
                    tripManager.resetTrip(TripId.A, name)
                    mqttManager.publishTripHistory(tripManager.getHistory())
                },
                modifier = Modifier.weight(1f).fillMaxHeight(),
            )
            TripCard(
                label    = "Trip B",
                snapshot = snapB,
                onReset  = { name ->
                    mqttManager.publishTripCompleted("trip_b", snapB, name)
                    tripManager.resetTrip(TripId.B, name)
                    mqttManager.publishTripHistory(tripManager.getHistory())
                },
                modifier = Modifier.weight(1f).fillMaxHeight(),
            )
        }
    }

}

