package br.com.redesurftank.ecotrip.ui.screens

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import br.com.redesurftank.ecotrip.managers.BackupManager
import br.com.redesurftank.ecotrip.managers.LocalApiServer
import br.com.redesurftank.ecotrip.managers.MqttManager
import br.com.redesurftank.ecotrip.managers.TripManager
import br.com.redesurftank.ecotrip.services.CarTelemetryService
import br.com.redesurftank.ecotrip.ui.theme.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Todos os IPs locais de interfaces ativas (não loopback). Head unit do Haval
 *  costuma ter múltiplas: WiFi cliente (192.168.x.x), AP interno (10.x.x.x),
 *  USB tethering, etc. iPad só alcança o IP da MESMA rede dele. Listamos todos
 *  pra user descobrir qual usar. */
private data class NetIfAddr(val ifName: String, val ip: String)

private fun getLocalIpAddresses(): List<NetIfAddr> = try {
    java.net.NetworkInterface.getNetworkInterfaces().toList()
        .filter { it.isUp && !it.isLoopback }
        .flatMap { iface ->
            iface.inetAddresses.toList()
                .filter { it is java.net.Inet4Address && !it.isLoopbackAddress }
                .mapNotNull { addr ->
                    addr.hostAddress?.let { NetIfAddr(iface.name, it) }
                }
        }
} catch (_: Exception) { emptyList() }

/** Extrai o host da URL do Home Assistant e monta a URL do Bridge na porta 3000. */
private fun deriveBridgeFromHaUrl(haUrl: String): String {
    if (haUrl.isBlank()) return ""
    return try {
        val host = java.net.URL(haUrl).host
        if (host.isNotBlank()) "http://$host:3000" else ""
    } catch (_: Exception) { "" }
}

@Composable
fun SettingsScreen(
    tankCapacity: Float,
    onTankChange: (Float) -> Unit,
    maxHistory: Int,
    onMaxHistoryChange: (Int) -> Unit,
    mqttManager: MqttManager,
    minAutoTripDist: Float,
    onMinAutoTripDistChange: (Float) -> Unit,
    homeLayout: Int,
    onHomeLayoutChange: (Int) -> Unit,
    backupManager: BackupManager,
    tripManager: TripManager,
    onClearAll: () -> Unit = {},
    onBack: () -> Unit,
) {
    var showClearConfirm  by remember { mutableStateOf(false) }
    var clearDoneMsg      by remember { mutableStateOf("") }
    var showV8            by remember { mutableStateOf(false) }
    var showV8Cluster     by remember { mutableStateOf(false) }
    var mqttEnabled      by remember { mutableStateOf(mqttManager.enabled) }
    var host             by remember { mutableStateOf(mqttManager.host) }
    var port             by remember { mutableStateOf(mqttManager.port.toString()) }
    var username         by remember { mutableStateOf(mqttManager.username) }
    var password         by remember { mutableStateOf(mqttManager.password) }
    var tls              by remember { mutableStateOf(mqttManager.tls) }
    var prefix           by remember { mutableStateOf(mqttManager.prefix) }
    var pairCode         by remember { mutableStateOf("") }
    var pairMsg          by remember { mutableStateOf("") }
    var pairing          by remember { mutableStateOf(false) }
    var pairedState      by remember { mutableStateOf(mqttManager.paired) }
    var showMqttManual   by remember { mutableStateOf(false) }
    var bridgeUrlStr     by remember {
        mutableStateOf(
            mqttManager.bridgeUrl.ifEmpty {
                deriveBridgeFromHaUrl(backupManager.haExportUrl)
            }
        )
    }
    var bridgeTokenStr   by remember { mutableStateOf(mqttManager.bridgeToken) }
    val intervalOptions = remember {
        listOf(
            250, 500,
            1_000, 3_000, 5_000, 10_000, 20_000, 30_000, 40_000, 50_000, 60_000,
            120_000, 180_000, 300_000, 600_000, 900_000,
            1_800_000, 2_700_000, 3_600_000,
        )
    }
    fun intervalLabel(ms: Int) = when {
        ms < 1_000             -> "${ms} ms"
        ms < 60_000            -> "${ms / 1_000} s"
        ms % 60_000 == 0       -> "${ms / 60_000} min"
        else                   -> "${ms / 1_000} s"
    }
    fun snapToIndex(ms: Int) = intervalOptions.indices.minByOrNull { kotlin.math.abs(intervalOptions[it] - ms) } ?: 0
    var wifiIntervalIdx     by remember { mutableStateOf(snapToIndex(mqttManager.publishIntervalWifiMs)) }
    var cellularIntervalIdx by remember { mutableStateOf(snapToIndex(mqttManager.publishIntervalCellularMs)) }
    val publishIntervalWifiMs     by remember { derivedStateOf { intervalOptions[wifiIntervalIdx] } }
    val publishIntervalCellularMs by remember { derivedStateOf { intervalOptions[cellularIntervalIdx] } }
    var mqttStatus       by remember { mutableStateOf(mqttManager.status) }
    var showPass         by remember { mutableStateOf(false) }
    val context      = LocalContext.current
    val scope        = rememberCoroutineScope()
    var backupStatus by remember { mutableStateOf("") }
    var backupLoading by remember { mutableStateOf(false) }
    var importUrl    by remember { mutableStateOf("") }
    var haUrl        by remember {
        mutableStateOf(
            backupManager.haExportUrl.ifEmpty {
                if (mqttManager.host.isNotEmpty()) "http://${mqttManager.host}:8123" else ""
            }
        )
    }

    val importFileLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument()
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            backupLoading = true
            backupStatus  = ""
            val result = withContext(Dispatchers.IO) {
                runCatching { backupManager.importBackupFromUri(uri) }
            }
            backupLoading = false
            result.fold(
                onSuccess = { ts ->
                    backupStatus = "✓ Backup restaurado (salvo em: $ts). Reiniciando..."
                    kotlinx.coroutines.delay(1800)
                    android.os.Process.killProcess(android.os.Process.myPid())
                },
                onFailure = { backupStatus = "✗ ${it.message}" },
            )
        }
    }

    DisposableEffect(Unit) {
        mqttManager.onStatusChange = { mqttStatus = it }
        onDispose { mqttManager.onStatusChange = null }
    }

    if (showV8) {
        V8SoundScreen(onBack = { showV8 = false })
        return
    }
    if (showV8Cluster) {
        V8ClusterScreen(onBack = { showV8Cluster = false })
        return
    }

    ClaudeScreen(title = "Configurações", onBack = onBack, accent = NeonLime, spacing = 16.dp) {
        Column(
            modifier = Modifier
                .weight(1f)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {

        // ── Som V8 (tela dedicada) ──────────────────────────────────────────────
        SectionCard(title = "Som V8") {
            Text(
                "Transforma a potência do motor elétrico em ronco de V8 pelas caixas do carro. Ative e ajuste na tela dedicada.",
                fontSize = 12.sp, color = TextSecondary,
            )
            OutlinedButton(
                onClick = { showV8 = true },
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(8.dp),
                colors = ButtonDefaults.outlinedButtonColors(contentColor = AccentOrange),
            ) {
                Text("Abrir Som V8", fontWeight = FontWeight.Bold)
            }
            OutlinedButton(
                onClick = { showV8Cluster = true },
                modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                shape = RoundedCornerShape(8.dp),
                colors = ButtonDefaults.outlinedButtonColors(contentColor = Color(0xFFFF1E1E)),
            ) {
                Text("V8 CLUSTER (tacô + velocímetro)", fontWeight = FontWeight.Bold)
            }
        }

        // ── Tela inicial (layout) ───────────────────────────────────────────────
        SectionCard(title = "Tela inicial") {
            val opts = listOf("Tesla", "Europeu", "By Claude")
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                opts.forEachIndexed { i, label ->
                    val sel = homeLayout == i
                    OutlinedButton(
                        onClick = { onHomeLayoutChange(i) },
                        modifier = Modifier.weight(1f),
                        shape = RoundedCornerShape(8.dp),
                        border = androidx.compose.foundation.BorderStroke(1.dp, if (sel) Green else Color.White.copy(alpha = 0.15f)),
                        colors = ButtonDefaults.outlinedButtonColors(
                            containerColor = if (sel) Green.copy(alpha = 0.12f) else Color.Transparent,
                            contentColor = if (sel) Green else TextSecondary,
                        ),
                    ) {
                        Text(label, fontSize = 14.sp, fontWeight = if (sel) FontWeight.Bold else FontWeight.Normal)
                    }
                }
            }
            Spacer(Modifier.height(4.dp))
            Text(
                "Estilo da tela inicial do carro, focada na viagem atual.",
                fontSize = 11.sp, color = TextSecondary,
            )
        }

        // ── Tanque ────────────────────────────────────────────────────────────
        SectionCard(title = "Tanque de combustível") {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(16.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                StepButton("−") { if (tankCapacity > 20f) onTankChange(tankCapacity - 1f) }

                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier.weight(1f),
                ) {
                    Text("%.0f L".format(tankCapacity), fontSize = 28.sp, fontWeight = FontWeight.Bold, color = Cyan)
                    Text("litros", fontSize = 12.sp, color = TextSecondary)
                }

                StepButton("+") { if (tankCapacity < 120f) onTankChange(tankCapacity + 1f) }
            }
            Spacer(Modifier.height(4.dp))
            Text(
                "Padrão: 51L (Haval H6 HEV). Afeta o cálculo de combustível consumido.",
                fontSize = 11.sp, color = TextSecondary,
            )
        }

        // Preços (read-only): vêm do bridge via cmd/set_price_kwh e
        // cmd/set_price_gas_per_l (retained). Recalculados a cada
        // abastecimento/recarga registrado no PWA — mix ponderado.
        SectionCard(title = "Preços atuais (calculados no servidor)") {
            val priceGas = tripManager.getPriceGasoline()
            val priceKwh = tripManager.getPriceEnergy()
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(16.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier.weight(1f),
                ) {
                    Text("⛽ Gasolina", fontSize = 11.sp, color = TextSecondary)
                    Text(
                        if (priceGas > 0f) "R$ %.3f".format(priceGas) else "—",
                        fontSize = 22.sp, fontWeight = FontWeight.Bold, color = Cyan,
                    )
                    Text("por litro", fontSize = 10.sp, color = TextSecondary)
                }
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier.weight(1f),
                ) {
                    Text("⚡ Energia", fontSize = 11.sp, color = TextSecondary)
                    Text(
                        if (priceKwh > 0f) "R$ %.4f".format(priceKwh) else "—",
                        fontSize = 22.sp, fontWeight = FontWeight.Bold, color = Cyan,
                    )
                    Text("por kWh", fontSize = 10.sp, color = TextSecondary)
                }
            }
            Text(
                "Valores ponderados pelo mix do tanque/bateria, atualizados a cada abastecimento e recarga registrados no PWA. Edição feita no celular.",
                fontSize = 11.sp, color = TextSecondary,
                modifier = Modifier.padding(top = 6.dp),
            )
        }

        // ── Histórico ─────────────────────────────────────────────────────────
        SectionCard(title = "Histórico de viagens") {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(16.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                StepButton("−") { if (maxHistory > 10) onMaxHistoryChange(maxHistory - 10) }
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier.weight(1f),
                ) {
                    Text("$maxHistory", fontSize = 28.sp, fontWeight = FontWeight.Bold, color = Cyan)
                    Text("viagens salvas", fontSize = 12.sp, color = TextSecondary)
                }
                StepButton("+") { if (maxHistory < 500) onMaxHistoryChange(maxHistory + 10) }
            }
            Text(
                "Viagens mais antigas são removidas automaticamente ao atingir o limite. O histórico completo fica salvo no Home Assistant.",
                fontSize = 11.sp, color = TextSecondary,
            )
        }

        // ── Conexão (SOMENTE pareamento — nada de IP/senha digitável) ─────────
        SectionCard(title = "Conexão") {
            StatusBadge(mqttStatus, if (mqttStatus == MqttManager.Status.ERROR) mqttManager.lastErrorMessage else "")
            if (pairedState) {
                Text("✅ Pareado com o app", fontSize = 14.sp, color = Green, fontWeight = FontWeight.SemiBold)
                Text("Broker, usuário e senha vêm do app — nada é digitado nem fica visível aqui.",
                    fontSize = 11.sp, color = TextSecondary)
                Button(
                    onClick = { mqttManager.unpair(); pairedState = false; pairCode = ""; pairMsg = "" },
                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFB91C1C)),
                    shape = RoundedCornerShape(8.dp),
                ) { Text("Desparear", fontSize = 13.sp, color = Color.White) }
            } else {
                Text("Parear com o app", fontSize = 14.sp, color = TextPrimary, fontWeight = FontWeight.SemiBold)
                Text("No app: Ajustes → Veículo → Conexão → Parear o carro → Gerar código. Digite o código abaixo.",
                    fontSize = 11.sp, color = TextSecondary)
                OutlinedTextField(
                    value = pairCode,
                    onValueChange = { pairCode = it.uppercase() },
                    label = { Text("Código de pareamento", fontSize = 12.sp) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                    colors = mqttFieldColors(),
                )
                Button(
                    onClick = {
                        pairing = true; pairMsg = ""
                        mqttManager.pairWithCode("https://mac-mini.tailacc6e7.ts.net", pairCode) { ok, msg ->
                            pairing = false; pairMsg = msg
                            if (ok) { pairedState = true; pairCode = "" }
                        }
                    },
                    enabled = !pairing && pairCode.isNotBlank(),
                    modifier = Modifier.fillMaxWidth(),
                    colors = ButtonDefaults.buttonColors(containerColor = Green),
                    shape = RoundedCornerShape(8.dp),
                ) { Text(if (pairing) "Pareando…" else "Parear", fontSize = 13.sp, color = SurfaceDeep, fontWeight = FontWeight.SemiBold) }
                if (pairMsg.isNotBlank()) {
                    Text(pairMsg, fontSize = 12.sp, color = if (pairMsg.contains("✓")) Green else Color(0xFFFF4444))
                }
            }
        }

        // ── LAN direta carro↔iPad ─────────────────────────────────────────────
        val ctx = LocalContext.current
        var lanEnabled by remember { mutableStateOf(CarTelemetryService.isLanEnabledPref(ctx)) }
        // Lista de IPs do head unit — recarrega a cada vez que abrir Settings
        // (em caso de WiFi reconectar e mudar IP).
        val ips = remember { getLocalIpAddresses() }
        SectionCard("📡 Servidor LAN direta (iPad)") {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        if (lanEnabled) "Ligado" else "Desligado",
                        fontSize = 13.sp,
                        color = if (lanEnabled) NeonLime else TextSecondary,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Text(
                        "Anuncia _havalobd._tcp na rede via mDNS. iPad descobre " +
                        "automaticamente e consome telemetria direto (~5ms vs ~200ms " +
                        "via Mac mini). Mantém MQTT pra Mac mini independente.",
                        fontSize = 11.sp,
                        color    = TextSecondary,
                    )
                }
                Switch(
                    checked = lanEnabled,
                    onCheckedChange = {
                        lanEnabled = it
                        CarTelemetryService.setLanEnabled(ctx, it)
                    },
                )
            }
            if (lanEnabled) {
                val activePort = LocalApiServer.activePort
                val portStr = if (activePort > 0) "$activePort" else "—"
                if (activePort <= 0) {
                    Text(
                        "⚠ Servidor NÃO está rodando (bind falhou em todas as portas)",
                        fontSize = 11.sp,
                        color = Color(0xFFFF4444),
                        fontWeight = FontWeight.SemiBold,
                    )
                }
                Text(
                    "Endereços ativos (use o da MESMA rede do iPad):",
                    fontSize = 11.sp,
                    color = TextSecondary,
                    fontWeight = FontWeight.SemiBold,
                )
                if (ips.isEmpty()) {
                    Text("—", fontSize = 12.sp, color = TextSecondary)
                } else {
                    ips.forEach { ifAddr ->
                        Text(
                            "${ifAddr.ip}:$portStr  ·  ${ifAddr.ifName}",
                            fontSize = 13.sp,
                            color = NeonLime,
                            fontWeight = FontWeight.SemiBold,
                        )
                    }
                }
                Text(
                    "wlan0 normalmente é a WiFi cliente (rede de casa/hotspot do " +
                    "iPad). ap0 / 10.x.x.x costuma ser o hotspot interno do carro. " +
                    "Teste cada IP no Safari do iPad: http://<ip>:$portStr/ — se " +
                    "responder JSON {\"ok\":true}, esse é o IP certo.",
                    fontSize = 10.sp,
                    color = TextSecondary,
                )
            }
        }

        // ── Inicialização ─────────────────────────────────────────────────────
        var bootMinimized by remember { mutableStateOf(CarTelemetryService.isBootMinimizedPref(ctx)) }
        SectionCard("Inicialização") {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        if (bootMinimized) "Inicia minimizado" else "Inicia na tela",
                        fontSize = 13.sp,
                        color = if (bootMinimized) NeonLime else TextSecondary,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Text(
                        "Ligado: ao religar o carro o app sobe no background sem aparecer na tela " +
                        "(serviço ativo, UI abre ao tocar). Desligado: abre direto na tela.",
                        fontSize = 11.sp, color = TextSecondary,
                    )
                }
                Switch(
                    checked = bootMinimized,
                    onCheckedChange = {
                        bootMinimized = it
                        CarTelemetryService.setBootMinimized(ctx, it)
                    },
                )
            }
        }

        // ── Limpar dados ──────────────────────────────────────────────────────
        SectionCard("⚠️  Limpar dados") {
            Text(
                "Remove permanentemente o histórico de viagens automáticas, sessões de recarga " +
                "e todos os totais lifetime (energia, combustível, distância).",
                fontSize = 11.sp,
                color    = TextSecondary,
            )
            Button(
                onClick  = { showClearConfirm = true; clearDoneMsg = "" },
                modifier = Modifier.fillMaxWidth(),
                colors   = ButtonDefaults.buttonColors(containerColor = Color(0xFFB91C1C)),
                shape    = RoundedCornerShape(8.dp),
            ) {
                Text("🗑  Limpar histórico completo", fontSize = 13.sp, color = Color.White, fontWeight = FontWeight.SemiBold)
            }
            if (clearDoneMsg.isNotEmpty()) {
                Text(clearDoneMsg, fontSize = 11.sp, color = NeonLime)
            }
        }

        Spacer(Modifier.height(8.dp))  // breathing room at bottom of scroll
        }
    }

    // Diálogo de confirmação
    if (showClearConfirm) {
        AlertDialog(
            onDismissRequest = { showClearConfirm = false },
            title = { Text("Limpar histórico?", fontWeight = FontWeight.Bold) },
            text  = {
                Text(
                    "Serão apagados:\n• Viagens automáticas\n• Sessões de recarga\n• Totais lifetime (energia, combustível, distância, recargas)\n• Checkpoints de estatísticas\n\nEssa ação não pode ser desfeita.",
                    fontSize = 13.sp,
                )
            },
            confirmButton = {
                Button(
                    onClick = {
                        tripManager.clearHistory()
                        tripManager.clearAutoTripHistory()
                        tripManager.clearChargeHistory()
                        tripManager.resetLifetime()
                        onClearAll()
                        showClearConfirm = false
                        clearDoneMsg = "✓ Tudo apagado. Começando do zero."
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFB91C1C)),
                ) { Text("Apagar tudo", color = Color.White) }
            },
            dismissButton = {
                TextButton(onClick = { showClearConfirm = false }) { Text("Cancelar") }
            },
            containerColor = Color(0xFF1E293B),
            titleContentColor  = Color(0xFFEEF4FF),
            textContentColor   = Color(0xFF94A3B8),
        )
    }
}

// ── Helpers ──────────────────────────────────────────────────────────────────

@Composable
private fun SectionCard(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .claudeCard(NeonLime)
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(title, fontSize = 15.sp, fontWeight = FontWeight.Bold, color = NeonLime, letterSpacing = 1.sp)
        HorizontalDivider(color = Separator, thickness = 0.5.dp)
        content()
    }
}

@Composable
private fun MqttField(label: String, value: String, keyboardType: KeyboardType, onValue: (String) -> Unit) {
    OutlinedTextField(
        value = value,
        onValueChange = onValue,
        label = { Text(label, fontSize = 12.sp) },
        modifier = Modifier.fillMaxWidth(),
        singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = keyboardType),
        colors = mqttFieldColors(),
    )
}

@Composable
private fun mqttFieldColors() = OutlinedTextFieldDefaults.colors(
    focusedTextColor      = TextPrimary,
    unfocusedTextColor    = TextPrimary,
    focusedBorderColor    = Green,
    unfocusedBorderColor  = BorderColor,
    focusedLabelColor     = Green,
    unfocusedLabelColor   = TextSecondary,
    cursorColor           = Green,
)

@Composable
private fun StepButton(label: String, onClick: () -> Unit) {
    TextButton(
        onClick = onClick,
        modifier = Modifier
            .background(SurfaceDeep, RoundedCornerShape(8.dp))
            .border(1.dp, BorderColor, RoundedCornerShape(8.dp))
            .size(44.dp),
        contentPadding = PaddingValues(0.dp),
    ) {
        Text(label, fontSize = 20.sp, color = TextPrimary, fontWeight = FontWeight.Bold)
    }
}

/** Parses a price string robustly: trims whitespace, accepts comma or dot as decimal separator. */
private fun parsePrice(raw: String): Float? =
    raw.trim().replace(',', '.').toFloatOrNull()?.takeIf { it > 0f }

@Composable
private fun StatusBadge(status: MqttManager.Status, errorMessage: String = "") {
    val (color, label) = when (status) {
        MqttManager.Status.CONNECTED    -> Pair(Green,             "Conectado")
        MqttManager.Status.CONNECTING   -> Pair(Color(0xFFFFD60A), "Conectando...")
        MqttManager.Status.ERROR        -> Pair(Color(0xFFFF4444), "Erro")
        MqttManager.Status.DISCONNECTED -> Pair(TextSecondary,     "Desconectado")
    }
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Box(Modifier.size(8.dp).background(color, RoundedCornerShape(50)))
            Text(label, fontSize = 13.sp, color = color)
        }
        if (errorMessage.isNotEmpty()) {
            Text(errorMessage, fontSize = 10.sp, color = Color(0xFFFF4444))
        }
    }
}

@Composable
private fun IntervalSlider(
    icon: String,
    label: String,
    index: Int,
    options: List<Int>,
    accentColor: Color,
    labelFn: (Int) -> String,
    onIndexChange: (Int) -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(SurfaceDeep, RoundedCornerShape(10.dp))
            .border(1.dp, accentColor.copy(alpha = 0.18f), RoundedCornerShape(10.dp))
            .padding(horizontal = 14.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text      = "$icon  $label",
                fontSize  = 12.sp,
                color     = TextSecondary,
                fontWeight = FontWeight.Medium,
            )
            Text(
                text       = labelFn(options[index]),
                fontSize   = 22.sp,
                fontWeight = FontWeight.ExtraBold,
                color      = accentColor,
            )
        }
        Slider(
            value         = index.toFloat(),
            onValueChange = { onIndexChange(it.toInt()) },
            valueRange    = 0f..(options.size - 1).toFloat(),
            steps         = options.size - 2,
            modifier      = Modifier.fillMaxWidth(),
            colors        = SliderDefaults.colors(
                thumbColor            = accentColor,
                activeTrackColor      = accentColor,
                inactiveTrackColor    = accentColor.copy(alpha = 0.2f),
                activeTickColor       = Color.Transparent,
                inactiveTickColor     = Color.Transparent,
            ),
        )
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Text(labelFn(options.first()), fontSize = 10.sp, color = TextSecondary.copy(alpha = 0.5f))
            Text(labelFn(options.last()),  fontSize = 10.sp, color = TextSecondary.copy(alpha = 0.5f))
        }
    }
}
