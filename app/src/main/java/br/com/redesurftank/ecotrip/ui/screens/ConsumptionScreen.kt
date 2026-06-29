package br.com.redesurftank.ecotrip.ui.screens

import android.os.Handler
import android.os.Looper
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.material.icons.filled.BatteryChargingFull
import androidx.compose.material.icons.filled.DirectionsCar
import androidx.compose.material.icons.filled.LocalGasStation
import androidx.compose.material.icons.filled.Place
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
import br.com.redesurftank.ecotrip.managers.UplinkManager
import br.com.redesurftank.ecotrip.managers.LiveDriveScore
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
private val PTBR = java.util.Locale("pt", "BR")   // milhares "." e decimal ","

private val mainHandler = Handler(Looper.getMainLooper())

// Nota: FAST_LANE_KEYS / IMMEDIATE_PUBLISH_KEYS e o carListener completo agora
// vivem em MqttManager.attachGlobalCarDataListener() — listener global, sempre
// ativo, independente de qual tela do Compose estiver montada.

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
    var liveScore       by remember { mutableStateOf(tripManager.getLiveDriveScore()) }
    var showScoreDetail by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { while (true) { liveScore = tripManager.getLiveDriveScore(); delay(2_000L) } }

    // Layout da home + estado do corpo do carro (pro carro interativo)
    var homeLayout by remember { mutableStateOf(tripManager.getHomeLayout()) }
    // Carrossel: false = tela favorita (homeLayout 0/1/2) · true = Controles (WebView)
    var controlesOpen by remember { mutableStateOf(tripManager.getControlesOpen()) }
    // Gesto de 2 dedos na favorita (MainActivity) abre Controles; swipe no limite volta.
    DisposableEffect(Unit) {
        br.com.redesurftank.ecotrip.ui.screens.ControlesWebHost.onEnterRequest = {
            controlesOpen = true; tripManager.setControlesOpen(true)
        }
        br.com.redesurftank.ecotrip.ui.screens.ControlesWebHost.onExit = {
            controlesOpen = false; tripManager.setControlesOpen(false)
        }
        onDispose { }
    }
    var carDoors   by remember { mutableStateOf("") }
    var carWindows by remember { mutableStateOf("") }
    var carSunroof by remember { mutableStateOf(0) }
    var carLocked  by remember { mutableStateOf(true) }
    var carFrontLight by remember { mutableStateOf(false) }
    var carAcOn      by remember { mutableStateOf(false) }
    var carTurnLeft  by remember { mutableStateOf(false) }
    var carTurnRight by remember { mutableStateOf(false) }

    // Lê o estado do corpo do carro a cada 3s (portas/vidros/teto/trava)
    LaunchedEffect(Unit) {
        while (true) {
            val d = withContext(Dispatchers.IO) { carManager.fetchCurrent(CarConstants.CAR_BASIC_DOOR_STATUS.value)?.trim() }
            val w = withContext(Dispatchers.IO) { carManager.fetchCurrent(CarConstants.CAR_BASIC_WINDOW_STATUS.value)?.trim() }
            val s = withContext(Dispatchers.IO) { carManager.fetchCurrent(CarConstants.CAR_BASIC_SUNROOF_STATUS.value)?.trim() }
            val l = withContext(Dispatchers.IO) { carManager.fetchCurrent(CarConstants.CAR_BASIC_DOOR_LOCK_STATUS.value)?.trim() }
            val fl = withContext(Dispatchers.IO) { carManager.fetchCurrent(CarConstants.CAR_BASIC_FRONT_LIGHT_STATUS.value)?.trim() }
            val ac = withContext(Dispatchers.IO) { carManager.fetchCurrent(CarConstants.CAR_HVAC_AC_ENABLE.value)?.trim() }
            if (d != null) carDoors = d
            if (w != null) carWindows = w
            if (s != null) carSunroof = s.toFloatOrNull()?.toInt() ?: 0
            if (l != null) carLocked = (l.toFloatOrNull()?.toInt() == 1) // 1=trancado (confirmado no barramento)
            // Farol: vale o fetchCurrent OU o valor da inscrição (evento) — o que reportar ligado
            carFrontLight = (fl?.toFloatOrNull()?.toInt() == 1) || (mqttManager.latestFrontLight == 1)
            // AC (master): fetchCurrent OU o último valor do broadcast — o que reportar ligado
            carAcOn = (ac?.toFloatOrNull()?.toInt() == 1) || (mqttManager.latestHvacAcEnable == 1)
            delay(3_000L)
        }
    }

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
            // Setas (atualiza a cada 1s — barato, em memória): pisca enquanto ativa
            carTurnLeft  = mqttManager.isTurnLeftActive()
            carTurnRight = mqttManager.isTurnRightActive()
            if (ticks % 5 == 0) tripManager.tickTime()
            // Sinais da viagem (distância/energia/regen/SOC/combustível) chegam RARAMENTE
            // pelo listener passivo do GWM — a distância "travava" por centenas de metros.
            // Busca ativa a cada 5 s e alimenta o TripManager: a home/viagem atualiza em
            // ~tempo real (odômetro tem resolução ~100 m). Misturar com o push é seguro:
            // onDist/onEnergy só somam o DELTA do último valor visto.
            if (ticks % 5 == 2) {
                suspend fun pull(key: String) = withContext(Dispatchers.IO) { carManager.fetchCurrent(key)?.trim() }
                val odo  = pull(CarConstants.CAR_BASIC_CUR_JOURNEY_ODOMETER.value)
                val enr  = pull(CarConstants.CAR_EV_INFO_CYCLE_ENERGY_CONSUME_INFO.value)
                val rgn  = pull(CarConstants.CAR_EV_INFO_ENERGY_RECOVERY_INFO.value)
                val soc  = pull(CarConstants.CAR_EV_INFO_SOC_OF_BATTERY.value)
                val fuel = pull(CarConstants.CAR_BASIC_REMAIN_FUEL_PERCENTAGE.value)
                odo?.let  { tripManager.onDataChanged(CarConstants.CAR_BASIC_CUR_JOURNEY_ODOMETER.value, it) }
                enr?.let  { tripManager.onDataChanged(CarConstants.CAR_EV_INFO_CYCLE_ENERGY_CONSUME_INFO.value, it) }
                rgn?.let  { tripManager.onDataChanged(CarConstants.CAR_EV_INFO_ENERGY_RECOVERY_INFO.value, it) }
                soc?.let  { tripManager.onDataChanged(CarConstants.CAR_EV_INFO_SOC_OF_BATTERY.value, it) }
                fuel?.let { tripManager.onDataChanged(CarConstants.CAR_BASIC_REMAIN_FUEL_PERCENTAGE.value, it) }
            }
        }
    }

    var showChargeHistory by remember { mutableStateOf(false) }
    var showAutoTrips     by remember { mutableStateOf(false) }
    var showSettings      by remember { mutableStateOf(false) }
    var showSocArrival    by remember { mutableStateOf(false) }
    var navDest           by remember { mutableStateOf<MqttManager.NavDest?>(null) }
    var navPlan           by remember { mutableStateOf<RoutePlan?>(null) }
    val undoScope         = rememberCoroutineScope()
    var showLog           by remember { mutableStateOf(false) }
    var minAutoTripDist   by remember { mutableStateOf(tripManager.getMinAutoTripDist()) }
    var lastCompletedTrip by remember { mutableStateOf<AutoTripEntry?>(null) }
    // Lista de viagens automáticas — carregada uma vez quando a tela é aberta e
    // actualizada após renomear ou limpar. Evita chamar getAutoTripHistory() a cada
    // recomposição (que criaria uma nova lista instável e poderia causar loops).
    var autoTripEntries   by remember { mutableStateOf<List<AutoTripEntry>>(emptyList()) }
    var resumableTrip     by remember { mutableStateOf<AutoTripEntry?>(null) }
    // startMs da última viagem que o usuário dismissou ("Não") — usada pelo polling
    // pra não fazer o banner reaparecer enquanto for a MESMA viagem retomável.
    // Quando uma viagem nova vira retomável (startMs diferente), o banner volta.
    var dismissedResumeStartMs by remember { mutableStateOf<Long?>(null) }

    // Verifica continuamente se há viagem retomável. Aparece e some sozinho conforme
    // as condições mudam (janela 60min, distância da viagem em curso, etc).
    // Espera 3s antes do primeiro check — evita popup competindo com a partida do
    // carro (vários apps Android Auto inicializando ao mesmo tempo).
    LaunchedEffect(Unit) {
        delay(3_000L)
        while (true) {
            // Só oferece "continuar viagem" enquanto o carro está em driving_ready=1.
            // Antes o banner aparecia 3s após desligar (mesmo sem abrir porta),
            // forçando o user a dismissar manualmente. Agora some sozinho quando
            // o carro sai de driving_ready e volta quando entra de novo.
            val carReady = mqttManager.latestDrivingReadyState == 1
            val candidate = if (carReady) tripManager.getResumableLastTrip() else null
            // Ignora se o usuário já dismissou ESTA viagem específica
            resumableTrip = if (candidate != null && candidate.startMs == dismissedResumeStartMs) null
                            else candidate
            delay(5_000L)
        }
    }

    // Destino vindo do celular (Nav Relay → bridge → cmd/nav_dest): NÃO abre a tela
    // Chegada; alimenta o banner "viagem em andamento" na home. NÃO some ao desligar
    // o carro — a rota é dona do bridge (state.route, retido em nav_dest) e só some
    // quando o bridge a encerra (chegou ao destino final / expirou) publicando vazio,
    // o que zera incomingNavDest. Assim, parar numa parada e desligar não apaga o destino.
    //   • Com legs (rota multi-parada do bridge) → usa o ETA/SOC por perna já calculado.
    //   • Sem legs (payload antigo / offline) → recalcula localmente a cada 30s.
    LaunchedEffect(Unit) {
        var lastTs = 0L
        var lastCompute = 0L
        while (true) {
            val nd = mqttManager.incomingNavDest
            if (nd == null) {
                if (navDest != null) { navDest = null; navPlan = null }
            } else {
                if (nd.ts != lastTs) {
                    lastTs = nd.ts; navDest = nd
                    navPlan = if (nd.legs.isEmpty())
                        try { fetchArrivalPlan(tripManager, nd.lat, nd.lng, nd.name, nd.etaClock) } catch (e: Exception) { navPlan }
                    else null
                    lastCompute = System.currentTimeMillis()
                } else {
                    navDest = nd   // mantém a ref mais nova (janela de desfazer expira sozinha)
                }
                if (nd.legs.isEmpty() && System.currentTimeMillis() - lastCompute > 30_000L) {
                    navPlan = try { fetchArrivalPlan(tripManager, nd.lat, nd.lng, nd.name, nd.etaClock) } catch (e: Exception) { navPlan }
                    lastCompute = System.currentTimeMillis()
                }
            }
            delay(2_000L)
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

        // NOTA: carListener, connectedListener e syncCharging() foram movidos pra
        // MqttManager.attachGlobalCarDataListener() (chamado em MqttManager.init).
        // Antes viviam aqui dentro do DisposableEffect e eram descadastrados toda
        // vez que a tela saía de composição — RPM/SOC/speed paravam de ser
        // capturados. Agora rodam sempre, independente da UI.

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
                            Text(String.format(PTBR, "%,.1f km", trip.distKm), fontSize = 18.sp, fontWeight = FontWeight.Bold, color = AccentBlue)
                            Text("distância", fontSize = 11.sp, color = TextSecondary)
                        }
                        Column {
                            Text(String.format(PTBR, "%,.2f kWh", trip.netKwh), fontSize = 18.sp, fontWeight = FontWeight.Bold, color = Green)
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
                                Text(String.format(PTBR, "R$ %,.2f", costBrl), fontSize = 15.sp, fontWeight = FontWeight.Bold, color = WarnYellow)
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

    if (showSocArrival) {
        SocArrivalScreen(tripManager = tripManager, onBack = { showSocArrival = false })
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
            minAutoTripDist = minAutoTripDist,
            onMinAutoTripDistChange = { newVal ->
                minAutoTripDist = newVal
                tripManager.setMinAutoTripDist(newVal)
            },
            homeLayout = homeLayout,
            onHomeLayoutChange = { newVal ->
                homeLayout = newVal
                tripManager.setHomeLayout(newVal)
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

    if (showScoreDetail) {
        ScoreDetailDialog(liveScore) { showScoreDetail = false }
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

    val baseHd = buildHomeData(
        trip = displayTrip, isLive = displayIsLive, nowMs = nowMs,
        priceGasL = priceGasoline, priceKwh = priceEnergy,
        socNowPct = rolling.currentSocPct, tempC = displayTrip?.outsideTempC?.toInt() ?: 0,
        rangeEvKm = 0, doorCsv = carDoors, windowCsv = carWindows,
        sunroof = carSunroof, locked = carLocked, frontLight = carFrontLight,
        turnLeft = carTurnLeft, turnRight = carTurnRight, acOn = carAcOn,
    )
    // Banner "viagem em andamento" (destino do celular) sobreposto ao HomeData.
    //   • navDest com legs (rota multi-parada do bridge) → destino final = última perna,
    //     paradas intermediárias na faixa; a parada recém-concluída (undo) entra riscada.
    //   • senão, navPlan local (destino único).
    val nd = navDest
    val finalLeg = nd?.legs?.lastOrNull()
    val hd = when {
        finalLeg != null -> {
            val stops = mutableListOf<HomeNavStop>()
            nd.undo?.let { u ->
                if (u.untilMs > System.currentTimeMillis())
                    stops.add(HomeNavStop(u.name, "", 0, done = true))
            }
            nd.legs.dropLast(1).forEach { l ->
                stops.add(HomeNavStop(l.name, l.etaClock, l.socArrival, done = false))
            }
            baseHd.copy(
                navActive = true, navName = finalLeg.name, navDistKm = finalLeg.distKm.toFloat(),
                navEtaMin = finalLeg.etaMin, navEtaClock = finalLeg.etaClock, navArrivalSoc = finalLeg.socArrival,
                navStops = stops,
            )
        }
        navPlan != null -> baseHd.copy(
            navActive = true, navName = navPlan!!.destName, navDistKm = navPlan!!.distanceKm,
            navEtaMin = navPlan!!.durationMin, navEtaClock = navPlan!!.etaClock, navArrivalSoc = navPlan!!.predictedSoc,
        )
        else -> baseHd
    }

    // Ações de navegação no header do layout: uplink + chip de update + botões
    val navActions: @Composable RowScope.() -> Unit = {
        if (liveScore.valid) {
            val sc = scoreColorOf(liveScore.score)
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                modifier = Modifier
                    .padding(end = 8.dp)
                    .background(sc.copy(alpha = 0.14f), RoundedCornerShape(12.dp))
                    .border(1.5.dp, sc.copy(alpha = 0.55f), RoundedCornerShape(12.dp))
                    .clickable { showScoreDetail = true }
                    .padding(horizontal = 14.dp, vertical = 6.dp),
            ) {
                Text("🎯", fontSize = 18.sp)
                Text("${liveScore.score}", fontSize = 24.sp, fontWeight = FontWeight.ExtraBold, color = sc)
            }
        }
        UplinkChip()
        when {
            downloadProgress in 0..99 -> {
                Text(
                    "$downloadProgress%",
                    fontSize = 13.sp, fontWeight = FontWeight.ExtraBold, color = NeonLime,
                    modifier = Modifier
                        .background(NeonLime.copy(alpha = 0.10f), RoundedCornerShape(8.dp))
                        .border(1.dp, NeonLime.copy(alpha = 0.28f), RoundedCornerShape(8.dp))
                        .padding(horizontal = 12.dp, vertical = 4.dp),
                )
            }
            isCheckingUpdate -> {
                Text("...", fontSize = 11.sp, color = TextSecondary, modifier = Modifier.padding(end = 4.dp))
            }
            updateAvailable -> {
                TextButton(
                    onClick = { updateMgr.downloadAndInstall(context) },
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
                        Icon(Icons.Default.SystemUpdate, "Atualizar", tint = NeonLime, modifier = Modifier.size(16.dp))
                        Text(
                            updateMgr.latestRelease?.version?.let { "v$it" } ?: "Atualizar",
                            fontSize = 13.sp, fontWeight = FontWeight.ExtraBold, color = NeonLime,
                        )
                    }
                }
            }
        }
        IconButton(onClick = { showSocArrival = true }) { Icon(Icons.Default.Place, "SOC na chegada", tint = NeonLime) }
        IconButton(onClick = { showLog = true }) { Icon(Icons.Default.BugReport, "Log", tint = TextSecondary) }
        IconButton(onClick = { showChargeHistory = true }) { Icon(Icons.Default.BatteryChargingFull, "Recargas", tint = AuroraTeal) }
        IconButton(onClick = { showAutoTrips = true }) { Icon(Icons.Default.DirectionsCar, "Viagens Auto", tint = AccentBlue) }
        IconButton(onClick = { showSettings = true }) { Icon(Icons.Default.Settings, "Configurações", tint = TextSecondary) }
    }

    // systemBarsPadding insere o conteúdo na área segura (1792×660 no head unit):
    // a dock esquerda (128px) e a barra de status (60px) do sistema ficam fora.
    // O layout Controles (WebView) preenche essa área (HTML sem reservar faixas).
    Box(modifier = Modifier.fillMaxSize().systemBarsPadding()) {
        // Tela favorita (sempre desenhada por trás). A Controles é um overlay
        // (WebView fora do Compose) mostrado quando controlesOpen=true.
        when (homeLayout) {
            0 -> { /* layout Tesla = Web("home/tesla-fluxo.html") via HomeTeslaWebLayout abaixo */ }
            1 -> HomeEuropeanLayout(hd, actions = navActions)
            else -> HomeClaudeLayout(hd, actions = navActions) { m -> InteractiveCar(hd, m) }
        }
        // WebView fica acima do ComposeView → esconde o home Tesla quando há
        // overlay Compose aberto (Settings/Recargas/Viagens/Log), senão ficaria atrás.
        val anyOverlay = showSettings || showChargeHistory || showAutoTrips || showLog
        if (homeLayout == 0 && !controlesOpen && !anyOverlay) {
            HomeTeslaWebLayout(
                hd,
                onOpenSettings = { showSettings = true },
                onOpenRecargas = { showChargeHistory = true },
                onOpenViagens = { showAutoTrips = true },
            )
        }
        if (controlesOpen) {
            ControlesLayout(
                hd,
                onOpenSettings = { showSettings = true },
                onOpenRecargas = { showChargeHistory = true },
                onOpenViagens = { showAutoTrips = true },
                onCheckUpdate = { if (updateMgr.isUpdateAvailable) updateMgr.downloadAndInstall(context) else updateMgr.checkForUpdate() },
            )
        }

        // ── Banner de continuação: aparece quando há viagem retomável ────────
        resumableTrip?.let { last ->
            val gapMin = ((System.currentTimeMillis() - last.endMs) / 60_000L).toInt().coerceAtLeast(0)
            Surface(
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .padding(horizontal = 40.dp, vertical = 16.dp)
                    .fillMaxWidth(),
                color = SurfaceCard,
                shape = RoundedCornerShape(10.dp),
                border = androidx.compose.foundation.BorderStroke(1.dp, AccentBlue.copy(alpha = 0.4f)),
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Text("🔄", fontSize = 18.sp)
                    Column(modifier = Modifier.weight(1f)) {
                        Text("Continuar viagem anterior?", fontSize = 14.sp, fontWeight = FontWeight.Bold, color = TextPrimary)
                        Text("Terminou há ${gapMin} min · ${"%.1f".format(last.distKm)} km", fontSize = 11.sp, color = TextSecondary)
                    }
                    OutlinedButton(
                        onClick = {
                            tripManager.dismissResume(last.startMs)
                            dismissedResumeStartMs = last.startMs
                            resumableTrip = null
                        },
                        colors = ButtonDefaults.outlinedButtonColors(contentColor = TextSecondary),
                    ) { Text("Não", fontSize = 12.sp) }
                    Button(
                        onClick = {
                            if (tripManager.resumeLastTrip()) {
                                dismissedResumeStartMs = null
                                resumableTrip = null
                                autoTripEntries = tripManager.getAutoTripHistory()
                            }
                        },
                        colors = ButtonDefaults.buttonColors(containerColor = AccentBlue),
                    ) { Text("Continuar", fontSize = 12.sp, fontWeight = FontWeight.Bold) }
                }
            }
        }

        // ── Desfazer avanço de parada: o carro marcou uma parada como concluída por
        // proximidade. Mostra por ~5 min com a opção de desfazer (volta a parada à rota).
        navDest?.undo?.takeIf { it.untilMs > System.currentTimeMillis() }?.let { u ->
            Surface(
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .padding(horizontal = 40.dp, vertical = 12.dp)
                    .fillMaxWidth(),
                color = SurfaceCard,
                shape = RoundedCornerShape(10.dp),
                border = androidx.compose.foundation.BorderStroke(1.dp, AuroraTeal.copy(alpha = 0.4f)),
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Text(if (u.skipped) "⤼" else "✓", fontSize = 18.sp, color = AuroraTeal)
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            if (u.skipped) "Parada pulada: ${u.name}" else "Parada concluída: ${u.name}",
                            fontSize = 14.sp, fontWeight = FontWeight.Bold, color = TextPrimary,
                        )
                        Text(
                            if (u.skipped) "Indo direto pro destino" else "Avançou pra próxima parada",
                            fontSize = 11.sp, color = TextSecondary,
                        )
                    }
                    OutlinedButton(
                        onClick = { undoScope.launch { postRouteUndo(tripManager) } },
                        colors = ButtonDefaults.outlinedButtonColors(contentColor = AuroraTeal),
                    ) { Text("Desfazer", fontSize = 12.sp, fontWeight = FontWeight.Bold) }
                }
            }
        }

        // ── Pular parada: numa rota multi-parada, deixa pular a PRÓXIMA parada e ir
        // direto pro destino. A ≤2 km vira um aviso destacado (laranja). Sem undo
        // ativo (evita empilhar com o banner de desfazer).
        val skipNext = navDest?.legs?.firstOrNull { !it.isFinal }
        val undoActive = navDest?.undo?.let { it.untilMs > System.currentTimeMillis() } == true
        if (skipNext != null && !undoActive && resumableTrip == null) {
            val near = skipNext.distKm <= 2.0
            val accent = if (near) Color(0xFFFF9F0A) else AccentBlue
            Surface(
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .padding(horizontal = 40.dp, vertical = 16.dp)
                    .fillMaxWidth(),
                color = SurfaceCard,
                shape = RoundedCornerShape(10.dp),
                border = androidx.compose.foundation.BorderStroke(1.dp, accent.copy(alpha = 0.4f)),
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Text("⤼", fontSize = 18.sp, color = accent)
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            if (near) "A ${"%.1f".format(skipNext.distKm)} km de ${skipNext.name}" else "Próxima parada: ${skipNext.name}",
                            fontSize = 14.sp, fontWeight = FontWeight.Bold, color = TextPrimary,
                        )
                        Text(
                            if (near) "Não precisa parar? Pule e vá direto." else "${"%.1f".format(skipNext.distKm)} km",
                            fontSize = 11.sp, color = TextSecondary,
                        )
                    }
                    Button(
                        onClick = { undoScope.launch { postRouteSkip(tripManager) } },
                        colors = ButtonDefaults.buttonColors(containerColor = accent),
                    ) { Text("Pular parada", fontSize = 12.sp, fontWeight = FontWeight.Bold) }
                }
            }
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
    priceGasL: Float,
    priceKwh:  Float,
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
    // km/L econômico (ver TripManager.combinedKmL pro mesmo princípio)
    val netPos   = trip.netKwh.coerceAtLeast(0f)
    val kwhAsL   = if (priceGasL > 0f && priceKwh > 0f) netPos * priceKwh / priceGasL else netPos / 8.9f
    val kmlEq    = if (trip.distKm > 0.1f && (kwhAsL + trip.fuelL) > 0.001f)
        trip.distKm / (kwhAsL + trip.fuelL) else 0f
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
                    String.format(PTBR, "%,.1f km", trip.distKm),
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
                unit  = "km/L econ.",
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
                value = if (trip.netKwh > 0.01f) String.format(PTBR, "%,.2f kWh", trip.netKwh) else "--",
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


/** Chip de uplink de internet (Starlink/4G/OEM) no header — em todos os layouts. */
@Composable
private fun UplinkChip() {
    var up by remember { mutableStateOf(UplinkManager.current()) }
    LaunchedEffect(Unit) { while (true) { up = UplinkManager.current(); delay(5000) } }
    val pair = when (up) {
        "WLAN" -> "📡 Starlink" to Color(0xFF39FF88)
        "4G"   -> "📶 4G" to Color(0xFFFF5F1F)
        "OFF"  -> "🌐 OEM" to Color(0xFF8E8E93)
        else   -> null   // "?" → sem leitura → esconde
    } ?: return
    val (txt, c) = pair
    Text(
        txt, fontSize = 13.sp, fontWeight = FontWeight.ExtraBold, color = c,
        modifier = Modifier
            .padding(end = 4.dp)
            .border(1.dp, c.copy(alpha = 0.4f), RoundedCornerShape(8.dp))
            .padding(horizontal = 10.dp, vertical = 4.dp),
    )
}

// ── Score de condução ao vivo: cor por faixa + diálogo de detalhe ───────────
private fun scoreColorOf(s: Int): Color = when {
    s < 50 -> Color(0xFFFF5F1F)   // baixo
    s < 75 -> Color(0xFFFFB648)   // médio
    else   -> Color(0xFF28C98A)   // bom
}

@Composable
private fun ScoreBar(label: String, v: Int, dragging: Boolean) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(label + if (dragging) "  ← puxando" else "", color = if (dragging) scoreColorOf(v) else Color(0xFFEEF4FF), fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.weight(1f))
            Text("$v", color = scoreColorOf(v), fontSize = 15.sp, fontWeight = FontWeight.ExtraBold)
        }
        Box(Modifier.fillMaxWidth().height(8.dp).background(Color(0xFF23272F), RoundedCornerShape(4.dp))) {
            Box(Modifier.fillMaxWidth((v / 100f).coerceIn(0f, 1f)).fillMaxHeight().background(scoreColorOf(v), RoundedCornerShape(4.dp)))
        }
    }
}

@Composable
private fun ScoreDetailDialog(s: LiveDriveScore, onDismiss: () -> Unit) {
    val worst = minOf(s.econ, s.smooth, s.speed)   // componente que mais puxa a nota
    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = { TextButton(onClick = onDismiss) { Text("Fechar") } },
        title = { Text("Score da viagem · ${s.score}", color = scoreColorOf(s.score), fontWeight = FontWeight.ExtraBold, fontSize = 22.sp) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                ScoreBar("Economia", s.econ, s.econ == worst)
                ScoreBar("Suavidade", s.smooth, s.smooth == worst)
                ScoreBar("Velocidade", s.speed, s.speed == worst)
                Text("Economia ajustada pelo relevo · ${s.harshBrake} freada(s) · ${s.harshAcc} aceleração(ões) bruscas",
                     color = Color(0xFF8E8E93), fontSize = 13.sp)
            }
        },
    )
}
