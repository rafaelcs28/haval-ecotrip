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
import br.com.redesurftank.ecotrip.managers.MqttManager
import br.com.redesurftank.ecotrip.ui.theme.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@Composable
fun SettingsScreen(
    tankCapacity: Float,
    onTankChange: (Float) -> Unit,
    maxHistory: Int,
    onMaxHistoryChange: (Int) -> Unit,
    mqttManager: MqttManager,
    priceGasoline: Float,
    onPriceGasolineChange: (Float) -> Unit,
    priceEnergy: Float,
    onPriceEnergyChange: (Float) -> Unit,
    backupManager: BackupManager,
    onBack: () -> Unit,
) {
    var priceGasolineStr by remember { mutableStateOf(String.format(java.util.Locale.US, "%.2f", priceGasoline)) }
    var priceEnergyStr   by remember { mutableStateOf(String.format(java.util.Locale.US, "%.2f", priceEnergy)) }
    var mqttEnabled      by remember { mutableStateOf(mqttManager.enabled) }
    var host             by remember { mutableStateOf(mqttManager.host) }
    var port             by remember { mutableStateOf(mqttManager.port.toString()) }
    var username         by remember { mutableStateOf(mqttManager.username) }
    var password         by remember { mutableStateOf(mqttManager.password) }
    var prefix           by remember { mutableStateOf(mqttManager.prefix) }
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

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(SurfaceDeep)
            .systemBarsPadding()
            .padding(horizontal = 14.dp, vertical = 4.dp)
            .verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        // Header
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            IconButton(onClick = onBack) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Voltar", tint = TextSecondary)
            }
            Text("Configurações", fontSize = 21.sp, fontWeight = FontWeight.Bold, color = Green)
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

        // ── Preços ────────────────────────────────────────────────────────────
        SectionCard(title = "Preços — consumo combinado") {
            Text(
                "Usado para calcular km/L equivalente combinando combustível + energia elétrica.\nFórmula: km total ÷ (L gastos + kWh líquido × R\$/kWh ÷ R\$/L)",
                fontSize = 11.sp, color = TextSecondary,
            )
            val gasolineValid = parsePrice(priceGasolineStr) != null
            val energyValid   = parsePrice(priceEnergyStr)   != null
            OutlinedTextField(
                value = priceGasolineStr,
                onValueChange = { priceGasolineStr = it },
                label = { Text("Preço da gasolina (R\$/L)", fontSize = 12.sp) },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
                isError = priceGasolineStr.isNotEmpty() && !gasolineValid,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                colors = mqttFieldColors(),
            )
            OutlinedTextField(
                value = priceEnergyStr,
                onValueChange = { priceEnergyStr = it },
                label = { Text("Preço da energia (R\$/kWh)", fontSize = 12.sp) },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
                isError = priceEnergyStr.isNotEmpty() && !energyValid,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                colors = mqttFieldColors(),
            )
            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterEnd) {
                Button(
                    onClick = {
                        parsePrice(priceGasolineStr)?.let { onPriceGasolineChange(it) }
                        parsePrice(priceEnergyStr)?.let   { onPriceEnergyChange(it) }
                    },
                    enabled = gasolineValid && energyValid,
                    colors = ButtonDefaults.buttonColors(containerColor = Green),
                    shape  = RoundedCornerShape(8.dp),
                ) {
                    Text("Salvar preços", fontSize = 13.sp, color = SurfaceDeep, fontWeight = FontWeight.SemiBold)
                }
            }
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

        // ── MQTT ─────────────────────────────────────────────────────────────
        SectionCard(title = "MQTT / Home Assistant") {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text("Habilitar MQTT", fontSize = 14.sp, color = TextPrimary)
                Switch(
                    checked = mqttEnabled,
                    onCheckedChange = { mqttEnabled = it },
                    colors = SwitchDefaults.colors(checkedThumbColor = Green, checkedTrackColor = Green.copy(alpha = 0.4f)),
                )
            }

            if (mqttEnabled) {
                Spacer(Modifier.height(4.dp))

                MqttField("Host / IP", host, KeyboardType.Uri) { host = it }
                MqttField("Porta", port, KeyboardType.Number) { port = it }
                MqttField("Usuário", username, KeyboardType.Email) { username = it }

                OutlinedTextField(
                    value = password,
                    onValueChange = { password = it },
                    label = { Text("Senha", fontSize = 12.sp) },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                    visualTransformation = if (showPass) VisualTransformation.None else PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                    trailingIcon = {
                        TextButton(onClick = { showPass = !showPass }, contentPadding = PaddingValues(horizontal = 8.dp)) {
                            Text(if (showPass) "Ocultar" else "Mostrar", fontSize = 11.sp, color = TextSecondary)
                        }
                    },
                    colors = mqttFieldColors(),
                )

                MqttField("Prefixo de tópico", prefix, KeyboardType.Uri) { prefix = it }

                Spacer(Modifier.height(2.dp))
                Text("Intervalo de envio", fontSize = 13.sp, color = TextSecondary,
                    fontWeight = FontWeight.SemiBold)

                // ── WiFi ──────────────────────────────────────────────────────
                IntervalSlider(
                    icon        = "📶",
                    label       = "Com WiFi",
                    index       = wifiIntervalIdx,
                    options     = intervalOptions,
                    accentColor = Cyan,
                    labelFn     = ::intervalLabel,
                    onIndexChange = { wifiIntervalIdx = it },
                )

                // ── 4G / Celular ──────────────────────────────────────────────
                IntervalSlider(
                    icon        = "📡",
                    label       = "Sem WiFi (4G/celular)",
                    index       = cellularIntervalIdx,
                    options     = intervalOptions,
                    accentColor = MoltenOrange,
                    labelFn     = ::intervalLabel,
                    onIndexChange = { cellularIntervalIdx = it },
                )

                Spacer(Modifier.height(4.dp))

                // Status + Salvar
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    StatusBadge(mqttStatus, if (mqttStatus == MqttManager.Status.ERROR) mqttManager.lastErrorMessage else "")

                    Button(
                        onClick = {
                            mqttManager.enabled                   = mqttEnabled
                            mqttManager.host                      = host
                            mqttManager.port                      = port.toIntOrNull() ?: 1883
                            mqttManager.username                  = username
                            mqttManager.password                  = password
                            mqttManager.prefix                    = prefix.ifEmpty { "haval/ecotrip" }
                            mqttManager.publishIntervalWifiMs     = publishIntervalWifiMs
                            mqttManager.publishIntervalCellularMs = publishIntervalCellularMs
                            mqttManager.saveAndApply()
                        },
                        colors = ButtonDefaults.buttonColors(containerColor = Green),
                        shape  = RoundedCornerShape(8.dp),
                    ) {
                        Text("Salvar e conectar", fontSize = 13.sp, color = SurfaceDeep, fontWeight = FontWeight.SemiBold)
                    }
                }

                Spacer(Modifier.height(4.dp))
                Text(
                    "Os sensores aparecem automaticamente no Home Assistant via MQTT Discovery.",
                    fontSize = 11.sp, color = TextSecondary,
                )
            }
        }

        // ── Backup & Restauração ──────────────────────────────────────────────
        SectionCard(title = "Backup e Restauração") {
            Text(
                "Salva configurações, histórico de viagens e recargas, todos os acumulados (Trip A/B, Lifetime, Rolling) e dados de gráficos. Use para migrar entre carros ou reinstalações.",
                fontSize = 11.sp, color = TextSecondary,
            )
            // Botões exportar / importar arquivo
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Button(
                    onClick = {
                        scope.launch {
                            backupLoading = true
                            backupStatus  = ""
                            val result = withContext(Dispatchers.IO) {
                                runCatching { backupManager.exportBackup() }
                            }
                            backupLoading = false
                            result.fold(
                                onSuccess = { (_, path) -> backupStatus = "✓ Exportado: $path" },
                                onFailure = { backupStatus = "✗ ${it.message}" },
                            )
                        }
                    },
                    enabled  = !backupLoading,
                    modifier = Modifier.weight(1f),
                    colors   = ButtonDefaults.buttonColors(containerColor = AuroraTeal),
                    shape    = RoundedCornerShape(8.dp),
                ) {
                    Text("⬆ Exportar", fontSize = 13.sp, color = SurfaceDeep, fontWeight = FontWeight.SemiBold)
                }
                Button(
                    onClick  = { importFileLauncher.launch(arrayOf("application/json", "*/*")) },
                    enabled  = !backupLoading,
                    modifier = Modifier.weight(1f),
                    colors   = ButtonDefaults.buttonColors(containerColor = MoltenOrange),
                    shape    = RoundedCornerShape(8.dp),
                ) {
                    Text("⬇ Importar Arquivo", fontSize = 13.sp, color = SurfaceDeep, fontWeight = FontWeight.SemiBold)
                }
            }
            // Importar via URL
            OutlinedTextField(
                value           = importUrl,
                onValueChange   = { importUrl = it },
                label           = { Text("URL do backup (ex: http://homeassistant.local:8123/local/ecotrip-backup.json)", fontSize = 10.sp) },
                modifier        = Modifier.fillMaxWidth(),
                singleLine      = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                colors          = mqttFieldColors(),
            )
            Button(
                onClick = {
                    scope.launch {
                        backupLoading = true
                        backupStatus  = ""
                        val result = withContext(Dispatchers.IO) {
                            runCatching { backupManager.importBackupFromUrl(importUrl) }
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
                },
                enabled  = importUrl.trim().isNotEmpty() && !backupLoading,
                modifier = Modifier.fillMaxWidth(),
                colors   = ButtonDefaults.buttonColors(containerColor = PlasmaBlue),
                shape    = RoundedCornerShape(8.dp),
            ) {
                Text("⬇ Importar da URL", fontSize = 13.sp, color = SurfaceDeep, fontWeight = FontWeight.SemiBold)
            }
            if (backupLoading) {
                LinearProgressIndicator(modifier = Modifier.fillMaxWidth(), color = Green)
            }
            if (backupStatus.isNotEmpty()) {
                Text(
                    backupStatus,
                    fontSize = 12.sp,
                    color    = if (backupStatus.startsWith("✓")) NeonLime else androidx.compose.ui.graphics.Color(0xFFFF4444),
                )
            }
        }

        Spacer(Modifier.height(8.dp))  // breathing room at bottom of scroll
    }
}

// ── Helpers ──────────────────────────────────────────────────────────────────

@Composable
private fun SectionCard(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(SurfaceCard, RoundedCornerShape(12.dp))
            .border(1.dp, BorderColor, RoundedCornerShape(12.dp))
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(title, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = TextSecondary)
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
