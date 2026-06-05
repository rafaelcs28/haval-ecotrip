package br.com.redesurftank.ecotrip.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Sync
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import br.com.redesurftank.ecotrip.managers.AutoTripEntry
import br.com.redesurftank.ecotrip.ui.theme.*
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import java.util.TimeZone

// ── Filtro de período ─────────────────────────────────────────────────────────

private enum class AutoTripFilter(val label: String) {
    ALL       ("Tudo"),
    TODAY     ("Hoje"),
    DAYS_7    ("7 dias"),
    DAYS_30   ("30 dias"),
    THIS_MONTH("Este mês"),
}

private fun List<AutoTripEntry>.applyPreset(filter: AutoTripFilter): List<AutoTripEntry> {
    if (filter == AutoTripFilter.ALL) return this
    val cal = Calendar.getInstance()
    val threshold: Long = when (filter) {
        AutoTripFilter.TODAY -> {
            cal.set(Calendar.HOUR_OF_DAY, 0); cal.set(Calendar.MINUTE, 0)
            cal.set(Calendar.SECOND, 0);      cal.set(Calendar.MILLISECOND, 0)
            cal.timeInMillis
        }
        AutoTripFilter.DAYS_7   -> System.currentTimeMillis() - 7L  * 86_400_000L
        AutoTripFilter.DAYS_30  -> System.currentTimeMillis() - 30L * 86_400_000L
        AutoTripFilter.THIS_MONTH -> {
            cal.set(Calendar.DAY_OF_MONTH, 1)
            cal.set(Calendar.HOUR_OF_DAY, 0); cal.set(Calendar.MINUTE, 0)
            cal.set(Calendar.SECOND, 0);      cal.set(Calendar.MILLISECOND, 0)
            cal.timeInMillis
        }
        AutoTripFilter.ALL -> 0L
    }
    return filter { it.startMs >= threshold }
}

private fun autoTripUtcMsToLocalMidnight(utcMs: Long): Long {
    val utcCal = Calendar.getInstance(TimeZone.getTimeZone("UTC"))
    utcCal.timeInMillis = utcMs
    return Calendar.getInstance().apply {
        set(utcCal.get(Calendar.YEAR), utcCal.get(Calendar.MONTH),
            utcCal.get(Calendar.DAY_OF_MONTH), 0, 0, 0)
        set(Calendar.MILLISECOND, 0)
    }.timeInMillis
}

private fun fmtAutoTripDur(sec: Long): String {
    val h = sec / 3600
    val m = (sec % 3600) / 60
    val s = sec % 60
    return when {
        h > 0 -> "${h}h ${m}min"
        m > 0 -> "${m}min ${s}s"
        else  -> "${s}s"
    }
}

/** Verde/amarelo/laranja baseado em kWh/100km. */
private fun efficiencyColor(kwh100km: Float): Color = when {
    kwh100km <= 0f    -> TextSecondary
    kwh100km < 20f    -> Green
    kwh100km < 30f    -> WarnYellow
    else              -> AccentOrange
}

// ── Screen ────────────────────────────────────────────────────────────────────

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AutoTripsScreen(
    entries:        List<AutoTripEntry>,
    inProgress:     AutoTripEntry? = null,
    priceGasL:      Float = 6.0f,
    priceEnergyKwh: Float = 0.9f,
    minDistKm:      Float = 0f,
    onRename:       (AutoTripEntry, String) -> Unit = { _, _ -> },
    onClear:        () -> Unit,
    onForceSync:    (onResult: (Int) -> Unit) -> Unit = {},
    onBack:         () -> Unit,
) {
    val context          = LocalContext.current
    var syncLabel        by remember { mutableStateOf("") }
    val syncScope        = androidx.compose.runtime.rememberCoroutineScope()
    var selectedFilter   by remember { mutableStateOf(AutoTripFilter.ALL) }
    var customStartDayMs by remember { mutableStateOf<Long?>(null) }
    var customEndDayMs   by remember { mutableStateOf<Long?>(null) }
    var showStartPicker  by remember { mutableStateOf(false) }
    var showEndPicker    by remember { mutableStateOf(false) }
    val dateLabelFmt     = remember { SimpleDateFormat("dd/MM/yy", Locale.getDefault()) }

    val hasCustomRange = customStartDayMs != null || customEndDayMs != null

    // ── Lista filtrada ────────────────────────────────────────────────────────
    val filtered = remember(entries, selectedFilter, customStartDayMs, customEndDayMs, minDistKm) {
        val distFiltered = if (minDistKm > 0f) entries.filter { it.distKm >= minDistKm } else entries
        if (hasCustomRange) {
            val start = customStartDayMs ?: 0L
            val end   = if (customEndDayMs != null) {
                Calendar.getInstance().apply {
                    timeInMillis = customEndDayMs!!
                    set(Calendar.HOUR_OF_DAY, 23); set(Calendar.MINUTE, 59)
                    set(Calendar.SECOND, 59);       set(Calendar.MILLISECOND, 999)
                }.timeInMillis
            } else Long.MAX_VALUE
            distFiltered.filter { it.startMs in start..end }
        } else {
            distFiltered.applyPreset(selectedFilter)
        }
    }

    // ── Totais do período ─────────────────────────────────────────────────────
    val totalKm      = remember(filtered) { filtered.sumOf { it.distKm.toDouble() }.toFloat() }
    val totalSec     = remember(filtered) { filtered.sumOf { it.timeSec } }
    val totalNet     = remember(filtered) { filtered.sumOf { it.netKwh.toDouble() }.toFloat() }
    val totalFuel    = remember(filtered) { filtered.sumOf { it.fuelL.toDouble() }.toFloat() }
    val totalCostBrl = remember(filtered, priceGasL, priceEnergyKwh) {
        filtered.sumOf { (it.fuelL * priceGasL + it.netKwh.coerceAtLeast(0f) * priceEnergyKwh).toDouble() }.toFloat()
    }
    val showSummary  = selectedFilter != AutoTripFilter.ALL || hasCustomRange

    // ── DatePicker nativo (compatível com Android personalizado do carro) ────────
    // Usamos android.app.DatePickerDialog em vez de Material3 DatePickerDialog
    // para evitar crashes no ROM customizado da central multimídia.
    if (showStartPicker) {
        DisposableEffect(Unit) {
            val cal = Calendar.getInstance()
            customStartDayMs?.let { cal.timeInMillis = it }
            val dialog = android.app.DatePickerDialog(
                context,
                { _, year, month, day ->
                    customStartDayMs = Calendar.getInstance().apply {
                        set(year, month, day, 0, 0, 0)
                        set(Calendar.MILLISECOND, 0)
                    }.timeInMillis
                    selectedFilter = AutoTripFilter.ALL
                    showStartPicker = false
                },
                cal.get(Calendar.YEAR),
                cal.get(Calendar.MONTH),
                cal.get(Calendar.DAY_OF_MONTH),
            )
            dialog.setOnDismissListener { showStartPicker = false }
            dialog.show()
            onDispose { try { dialog.dismiss() } catch (_: Exception) {} }
        }
    }

    if (showEndPicker) {
        DisposableEffect(Unit) {
            val cal = Calendar.getInstance()
            customEndDayMs?.let { cal.timeInMillis = it }
            val dialog = android.app.DatePickerDialog(
                context,
                { _, year, month, day ->
                    customEndDayMs = Calendar.getInstance().apply {
                        set(year, month, day, 0, 0, 0)
                        set(Calendar.MILLISECOND, 0)
                    }.timeInMillis
                    selectedFilter = AutoTripFilter.ALL
                    showEndPicker = false
                },
                cal.get(Calendar.YEAR),
                cal.get(Calendar.MONTH),
                cal.get(Calendar.DAY_OF_MONTH),
            )
            dialog.setOnDismissListener { showEndPicker = false }
            dialog.show()
            onDispose { try { dialog.dismiss() } catch (_: Exception) {} }
        }
    }

    // ── Layout ────────────────────────────────────────────────────────────────
    ClaudeScreen(
        title = "Viagens",
        onBack = onBack,
        accent = AccentBlue,
        headerRight = {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                if (syncLabel.isNotEmpty()) {
                    Text(syncLabel, fontSize = 10.sp, color = when {
                    syncLabel.startsWith("✓") -> Green
                    syncLabel.startsWith("⚠") -> Color(0xFFFFA726) // laranja
                    syncLabel.startsWith("✗") -> Color(0xFFEF5350) // vermelho
                    else -> TextSecondary
                })
                }
                // Botão de sync manual para o bridge (iPhone PWA) — forceAll = true
                IconButton(onClick = {
                    if (syncLabel == "enviando…") return@IconButton  // evita double-tap
                    syncLabel = "enviando…"
                    onForceSync { sent ->
                        syncLabel = when (sent) {
                            -3 -> "✗ Falha de rede — verifique a URL"
                            -2 -> "⚠ Sem viagens gravadas"
                            -1 -> "✗ URL não configurada"
                            0  -> "✓ já sincronizado"
                            else -> "✓ $sent trips → iPhone"
                        }
                        syncScope.launch {
                            delay(6_000)
                            syncLabel = ""
                        }
                    }
                }) {
                    Icon(Icons.Default.Sync, contentDescription = "Sincronizar com iPhone", tint = AccentBlue, modifier = Modifier.size(20.dp))
                }
                Text(
                    if (showSummary) "${filtered.size}/${entries.size} viagens"
                    else "${entries.size} viagens",
                    fontSize = 12.sp, color = TextSecondary,
                )
                if (entries.isNotEmpty()) {
                    TextButton(onClick = onClear) {
                        Text("Limpar", fontSize = 14.sp, color = TextSecondary)
                    }
                }
            }
        },
    ) {

        // ── Chips de período predefinido ──────────────────────────────────────
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            AutoTripFilter.entries.forEach { filter ->
                val selected = !hasCustomRange && filter == selectedFilter
                FilterChip(
                    selected = selected,
                    onClick  = {
                        selectedFilter   = filter
                        customStartDayMs = null
                        customEndDayMs   = null
                    },
                    label = {
                        Text(
                            filter.label,
                            fontSize = 12.sp,
                            fontWeight = if (selected) FontWeight.Bold else FontWeight.Normal,
                        )
                    },
                    colors = FilterChipDefaults.filterChipColors(
                        selectedContainerColor = AccentBlue.copy(alpha = 0.20f),
                        selectedLabelColor     = AccentBlue,
                        containerColor         = SurfaceCard,
                        labelColor             = if (hasCustomRange) TextSecondary.copy(alpha = 0.4f) else TextSecondary,
                    ),
                    border = FilterChipDefaults.filterChipBorder(
                        enabled             = true,
                        selected            = selected,
                        selectedBorderColor = AccentBlue.copy(alpha = 0.6f),
                        borderColor         = if (hasCustomRange) BorderColor.copy(alpha = 0.4f) else BorderColor,
                        borderWidth         = 1.dp,
                        selectedBorderWidth = 1.dp,
                    ),
                )
            }
        }

        // ── Seletor de período customizado ────────────────────────────────────
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            val startLabel = customStartDayMs?.let { dateLabelFmt.format(Date(it)) } ?: "De"
            val startActive = customStartDayMs != null
            OutlinedButton(
                onClick = { showStartPicker = true },
                modifier = Modifier.height(36.dp),
                shape  = RoundedCornerShape(8.dp),
                colors = ButtonDefaults.outlinedButtonColors(
                    containerColor = if (startActive) AccentBlue.copy(alpha = 0.12f) else SurfaceCard,
                    contentColor   = if (startActive) AccentBlue else TextSecondary,
                ),
                border = androidx.compose.foundation.BorderStroke(
                    1.dp,
                    if (startActive) AccentBlue.copy(alpha = 0.5f) else BorderColor,
                ),
                contentPadding = PaddingValues(horizontal = 12.dp, vertical = 0.dp),
            ) {
                Text("📅 $startLabel", fontSize = 12.sp, fontWeight = if (startActive) FontWeight.Bold else FontWeight.Normal)
            }

            Text("—", fontSize = 12.sp, color = TextSecondary)

            val endLabel = customEndDayMs?.let { dateLabelFmt.format(Date(it)) } ?: "Até"
            val endActive = customEndDayMs != null
            OutlinedButton(
                onClick = { showEndPicker = true },
                modifier = Modifier.height(36.dp),
                shape  = RoundedCornerShape(8.dp),
                colors = ButtonDefaults.outlinedButtonColors(
                    containerColor = if (endActive) AccentBlue.copy(alpha = 0.12f) else SurfaceCard,
                    contentColor   = if (endActive) AccentBlue else TextSecondary,
                ),
                border = androidx.compose.foundation.BorderStroke(
                    1.dp,
                    if (endActive) AccentBlue.copy(alpha = 0.5f) else BorderColor,
                ),
                contentPadding = PaddingValues(horizontal = 12.dp, vertical = 0.dp),
            ) {
                Text("📅 $endLabel", fontSize = 12.sp, fontWeight = if (endActive) FontWeight.Bold else FontWeight.Normal)
            }

            if (hasCustomRange) {
                IconButton(
                    onClick  = { customStartDayMs = null; customEndDayMs = null },
                    modifier = Modifier.size(36.dp),
                ) {
                    Icon(Icons.Default.Close, contentDescription = "Limpar datas", tint = TextSecondary, modifier = Modifier.size(18.dp))
                }
            }
        }

        // ── Card de resumo do período ─────────────────────────────────────────
        if (showSummary && filtered.isNotEmpty()) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .claudeCard(AccentBlue)
                    .padding(horizontal = 18.dp, vertical = 14.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Row(
                    Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(0.dp),
                ) {
                    AutoPeriodStat("${filtered.size}", "Viagens",   modifier = Modifier.weight(1f))
                    AutoPeriodStat("%.1f km".format(totalKm),       "Distância", color = AccentBlue, modifier = Modifier.weight(1.4f))
                    AutoPeriodStat(fmtAutoTripDur(totalSec),        "Tempo",     modifier = Modifier.weight(1.4f))
                    AutoPeriodStat("%.2f kWh".format(totalNet),     "kWh líq.",  color = Green,       modifier = Modifier.weight(1.5f))
                    if (totalFuel > 0.001f)
                        AutoPeriodStat("%.2f L".format(totalFuel),  "Combust.",  color = AccentOrange, modifier = Modifier.weight(1.3f))
                }
                if (totalCostBrl > 0.01f) {
                    Row(
                        Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(0.dp),
                    ) {
                        AutoPeriodStat("R$ %.2f".format(totalCostBrl), "Custo total", color = WarnYellow, modifier = Modifier.weight(1.5f))
                        if (filtered.size > 1)
                            AutoPeriodStat("R$ %.2f".format(totalCostBrl / filtered.size), "Méd/viagem", color = WarnYellow, modifier = Modifier.weight(1.5f))
                        val avgCostPerKm = if (totalKm > 0.1f) totalCostBrl / totalKm else 0f
                        if (avgCostPerKm > 0f)
                            AutoPeriodStat("%.3f".format(avgCostPerKm), "R$/km", color = WarnYellow, modifier = Modifier.weight(1f))
                        else
                            Spacer(Modifier.weight(1f))
                    }
                }
            }
        }

        if (showSummary && filtered.isEmpty()) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .claudeCard(AccentBlue)
                    .padding(18.dp),
                contentAlignment = Alignment.Center,
            ) {
                val label = if (hasCustomRange) {
                    val s = customStartDayMs?.let { dateLabelFmt.format(Date(it)) } ?: "?"
                    val e = customEndDayMs?.let   { dateLabelFmt.format(Date(it)) } ?: "?"
                    "Nenhuma viagem entre $s e $e."
                } else {
                    "Nenhuma viagem em \"${selectedFilter.label}\"."
                }
                Text(label, fontSize = 13.sp, color = TextSecondary)
            }
        }

        // ── Lista ─────────────────────────────────────────────────────────────
        // weight(1f) é obrigatório: sem ele o Column passa altura unbounded ao LazyColumn
        // (devido ao verticalArrangement = spacedBy), causando crash no ROM do carro.
        // Sempre usamos LazyColumn para que o card em andamento apareça mesmo sem histórico.
        LazyColumn(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            // Card de viagem em andamento — aparece enquanto o carro está rodando
            if (inProgress != null) {
                item(key = "in_progress") {
                    InProgressAutoTripCard(inProgress)
                }
            }

            if (entries.isEmpty()) {
                item(key = "empty_msg") {
                    Box(
                        Modifier
                            .fillParentMaxWidth()
                            .height(120.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            "Nenhuma viagem automática registrada ainda.\nAs viagens são criadas ao ligar o carro.",
                            fontSize  = 14.sp,
                            color     = TextSecondary,
                            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                        )
                    }
                }
            } else {
                itemsIndexed(filtered, key = { _, e -> e.startMs }) { _, entry ->
                    AutoTripEntryRow(
                        entry          = entry,
                        priceGasL      = priceGasL,
                        priceEnergyKwh = priceEnergyKwh,
                        onRename       = { newName -> onRename(entry, newName) },
                    )
                }
            }
        }
    }
}

// ── Card de viagem em andamento ───────────────────────────────────────────────

@Composable
private fun InProgressAutoTripCard(inProgress: AutoTripEntry) {
    val elapsedSec = (inProgress.endMs - inProgress.startMs) / 1000L
    val kwh100km   = if (inProgress.distKm > 0.1f) inProgress.netKwh / inProgress.distKm * 100f else 0f
    val effColor   = efficiencyColor(kwh100km)
    val socDelta   = inProgress.endSocPct - inProgress.startSocPct
    val socColor   = when {
        socDelta > -10f -> Green
        socDelta > -25f -> WarnYellow
        else            -> AccentOrange
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .claudeCard(NeonLime)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        // Cabeçalho: indicador verde + rótulo + tempo decorrido
        Row(
            Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Box(
                    modifier = Modifier
                        .size(8.dp)
                        .background(Green, CircleShape),
                )
                Text(
                    "Em andamento",
                    fontSize   = 14.sp,
                    fontWeight = FontWeight.Bold,
                    color      = Green,
                )
            }
            Text(
                fmtAutoTripDur(elapsedSec),
                fontSize   = 13.sp,
                fontWeight = FontWeight.SemiBold,
                color      = TextSecondary,
            )
        }

        // Métricas da viagem atual
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(0.dp),
        ) {
            AutoPeriodStat(
                "%.1f km".format(inProgress.distKm),
                "Distância",
                color    = AccentBlue,
                modifier = Modifier.weight(1.3f),
            )
            AutoPeriodStat(
                fmtAutoTripDur(inProgress.timeSec),
                "Cond. efetiva",
                modifier = Modifier.weight(1.4f),
            )
            if (kwh100km > 0f)
                AutoPeriodStat(
                    "%.1f".format(kwh100km),
                    "kWh/100km",
                    color    = effColor,
                    modifier = Modifier.weight(1.3f),
                )
            else
                Spacer(Modifier.weight(1.3f))

            if (inProgress.startSocPct > 0f && socDelta < 0f)
                AutoPeriodStat(
                    "%.0f%%".format(socDelta),
                    "SOC Δ",
                    color    = socColor,
                    modifier = Modifier.weight(1f),
                )
            else
                Spacer(Modifier.weight(1f))
        }

        // Linha energia / regen / combustível (somente se não-zero)
        if (inProgress.netKwh > 0f || inProgress.fuelL > 0.001f) {
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(0.dp),
            ) {
                if (inProgress.netKwh > 0f)
                    AutoPeriodStat(
                        "%.2f kWh".format(inProgress.netKwh),
                        "kWh líq.",
                        color    = Green,
                        modifier = Modifier.weight(1.5f),
                    )
                if (inProgress.regenKwh > 0f)
                    AutoPeriodStat(
                        "%.2f kWh".format(inProgress.regenKwh),
                        "Regen",
                        color    = AuroraTeal,
                        modifier = Modifier.weight(1.5f),
                    )
                if (inProgress.fuelL > 0.001f)
                    AutoPeriodStat(
                        "%.3f L".format(inProgress.fuelL),
                        "Combustível",
                        color    = AccentOrange,
                        modifier = Modifier.weight(1.5f),
                    )
                Spacer(Modifier.weight(1f))
            }
        }
    }
}

// ── Stat do resumo ────────────────────────────────────────────────────────────

@Composable
private fun AutoPeriodStat(
    value:    String,
    label:    String,
    modifier: Modifier = Modifier,
    color:    Color = TextPrimary,
) {
    Column(modifier = modifier) {
        Text(value, fontSize = 14.sp, fontWeight = FontWeight.Bold, color = color)
        Text(label, fontSize = 10.sp, color = TextSecondary)
    }
}

// ── Card de viagem ────────────────────────────────────────────────────────────

@Composable
private fun AutoTripEntryRow(
    entry:          AutoTripEntry,
    priceGasL:      Float,
    priceEnergyKwh: Float,
    onRename:       (String) -> Unit,
) {
    var expanded        by remember { mutableStateOf(false) }
    var showRenameDialog by remember { mutableStateOf(false) }
    var renameText      by remember(entry.startMs) { mutableStateOf(entry.name) }

    val dateFmtFull = remember { SimpleDateFormat("dd/MM HH:mm", Locale.getDefault()) }
    val timeFmt     = remember { SimpleDateFormat("HH:mm", Locale.getDefault()) }

    val durationSec = (entry.endMs - entry.startMs) / 1000L
    val avgSpeed    = if (entry.timeSec > 0) entry.distKm / (entry.timeSec / 3600f) else 0f
    val kwh100km    = if (entry.distKm > 0.1f) entry.netKwh / entry.distKm * 100f else 0f
    val kmPerL      = if (entry.fuelL > 0.001f) entry.distKm / entry.fuelL else 0f
    val effColor    = efficiencyColor(kwh100km)
    val socDelta    = entry.endSocPct - entry.startSocPct
    val fuelDelta   = entry.endFuelPct - entry.startFuelPct
    val socColor    = when {
        socDelta > -10f -> Green
        socDelta > -25f -> WarnYellow
        else            -> AccentOrange
    }
    val costBrl   = entry.fuelL * priceGasL + entry.netKwh.coerceAtLeast(0f) * priceEnergyKwh
    val costPerKm = if (entry.distKm > 0.1f && costBrl > 0f) costBrl / entry.distKm else 0f

    // ── Diálogo de renomear ───────────────────────────────────────────────────
    if (showRenameDialog) {
        AlertDialog(
            onDismissRequest = { showRenameDialog = false },
            containerColor   = SurfaceCard,
            title = { Text("Renomear viagem", fontWeight = FontWeight.Bold, color = TextPrimary) },
            text  = {
                OutlinedTextField(
                    value         = renameText,
                    onValueChange = { renameText = it },
                    label         = { Text("Nome da viagem", fontSize = 12.sp) },
                    singleLine    = true,
                    modifier      = Modifier.fillMaxWidth(),
                    colors        = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor   = AccentBlue,
                        unfocusedBorderColor = BorderColor,
                        focusedLabelColor    = AccentBlue,
                        unfocusedLabelColor  = TextSecondary,
                        focusedTextColor     = TextPrimary,
                        unfocusedTextColor   = TextPrimary,
                        cursorColor          = AccentBlue,
                    ),
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    onRename(renameText.trim())
                    showRenameDialog = false
                }) {
                    Text("Salvar", color = AccentBlue, fontWeight = FontWeight.SemiBold)
                }
            },
            dismissButton = {
                TextButton(onClick = { showRenameDialog = false; renameText = entry.name }) {
                    Text("Cancelar", color = TextSecondary)
                }
            },
        )
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .claudeCard(AccentBlue)
            .clickable { expanded = !expanded },
    ) {
        // ── Linha compacta ─────────────────────────────────────────────────────
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 14.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            // Badge 🚗
            Box(
                modifier = Modifier
                    .background(AccentBlue.copy(alpha = 0.12f), RoundedCornerShape(6.dp))
                    .border(1.dp, AccentBlue.copy(alpha = 0.3f), RoundedCornerShape(6.dp))
                    .padding(horizontal = 6.dp, vertical = 2.dp),
            ) { Text("🚗", fontSize = 10.sp) }

            // Nome (se tiver) + Data + horário
            Column(modifier = Modifier.weight(1f)) {
                if (entry.name.isNotEmpty()) {
                    Text(
                        entry.name,
                        fontSize   = 13.sp,
                        fontWeight = FontWeight.SemiBold,
                        color      = TextPrimary,
                        maxLines   = 1,
                        overflow   = TextOverflow.Ellipsis,
                    )
                }
                Text(
                    "${dateFmtFull.format(Date(entry.startMs))} → ${timeFmt.format(Date(entry.endMs))}",
                    fontSize   = if (entry.name.isNotEmpty()) 11.sp else 13.sp,
                    fontWeight = if (entry.name.isNotEmpty()) FontWeight.Normal else FontWeight.SemiBold,
                    color      = if (entry.name.isNotEmpty()) TextSecondary else TextPrimary,
                    maxLines   = 1,
                    overflow   = TextOverflow.Ellipsis,
                )
                Text(fmtAutoTripDur(durationSec), fontSize = 11.sp, color = TextSecondary)
            }

            // Métricas inline — eficiência elétrica + eficiência térmica + custo
            AutoCompactMetric("%.1f km".format(entry.distKm), "dist")
            if (kwh100km > 0f)
                AutoCompactMetric("%.1f".format(kwh100km), "kWh/100", valueColor = effColor)
            if (kmPerL > 0f)
                AutoCompactMetric("%.1f".format(kmPerL), "km/L", valueColor = AccentOrange)
            if (costBrl > 0.01f)
                AutoCompactMetric("R$ %.2f".format(costBrl), "custo")

            // Botão expandir
            Icon(
                if (expanded) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                contentDescription = if (expanded) "Recolher" else "Expandir",
                tint     = TextSecondary,
                modifier = Modifier.size(18.dp),
            )
        }

        // ── Detalhes expandidos ────────────────────────────────────────────────
        if (expanded) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(start = 14.dp, end = 14.dp, bottom = 12.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                HorizontalDivider(color = Separator, thickness = 0.5.dp)
                Spacer(Modifier.height(2.dp))

                // Linha 1: eficiência — km, vel. média, kWh/100km, km/L
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    AutoDetailMetric("Distância",  "%.1f km".format(entry.distKm),  AccentBlue,  Modifier.weight(1f))
                    AutoDetailMetric("Vel. Média", "%.1f km/h".format(avgSpeed),    TextPrimary, Modifier.weight(1f))
                    if (kwh100km > 0f)
                        AutoDetailMetric("kWh/100km", "%.1f".format(kwh100km),      effColor,    Modifier.weight(1f))
                    else
                        Spacer(Modifier.weight(1f))
                    if (kmPerL > 0f)
                        AutoDetailMetric("km/L",      "%.1f".format(kmPerL),        AccentOrange,Modifier.weight(1f))
                    else
                        Spacer(Modifier.weight(1f))
                }

                // Linha 2: energia bruta + condução efetiva
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    AutoDetailMetric("kWh líquido",   "%.2f kWh".format(entry.netKwh),    Green,         Modifier.weight(1f))
                    AutoDetailMetric("Bruto",         "%.2f kWh".format(entry.energyKwh), TextSecondary, Modifier.weight(1f))
                    AutoDetailMetric("Regenerado",    "%.2f kWh".format(entry.regenKwh),  AuroraTeal,    Modifier.weight(1f))
                    AutoDetailMetric("Cond. efetiva", fmtAutoTripDur(entry.timeSec),       TextSecondary, Modifier.weight(1f))
                }

                // Linha 3: combustível (se houver) + custo
                val showFuel = entry.fuelL > 0.001f
                val showCost = costBrl > 0.01f
                if (showFuel || showCost) {
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        if (showFuel)
                            AutoDetailMetric("Combustível", "%.3f L".format(entry.fuelL),  AccentOrange, Modifier.weight(1f))
                        else
                            Spacer(Modifier.weight(1f))
                        if (showCost) {
                            AutoDetailMetric("💰 Custo",   "R$ %.2f".format(costBrl),      WarnYellow, Modifier.weight(1f))
                            if (costPerKm > 0f)
                                AutoDetailMetric("R$/km",  "%.3f".format(costPerKm),       WarnYellow, Modifier.weight(1f))
                            else
                                Spacer(Modifier.weight(1f))
                        } else {
                            Spacer(Modifier.weight(2f))
                        }
                        Spacer(Modifier.weight(1f))
                    }
                }

                // Linha 4: SOC início → fim
                if (entry.startSocPct > 0f || entry.endSocPct > 0f) {
                    Row(
                        Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        Text("Bateria:", fontSize = 11.sp, color = TextSecondary)
                        Text("%.0f%%".format(entry.startSocPct), fontSize = 13.sp, color = TextSecondary)
                        Text("→", fontSize = 11.sp, color = TextSecondary)
                        Text("%.0f%%".format(entry.endSocPct), fontSize = 13.sp, fontWeight = FontWeight.Bold, color = socColor)
                        Text("(%.0f%%)".format(socDelta), fontSize = 11.sp, color = socColor)
                    }
                }

                // Linha 5: Combustível % início → fim
                if (entry.startFuelPct > 0f || entry.endFuelPct > 0f) {
                    Row(
                        Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        Text("Combustível:", fontSize = 11.sp, color = TextSecondary)
                        Text("%.0f%%".format(entry.startFuelPct), fontSize = 13.sp, color = TextSecondary)
                        Text("→", fontSize = 11.sp, color = TextSecondary)
                        Text("%.0f%%".format(entry.endFuelPct), fontSize = 13.sp, fontWeight = FontWeight.Bold, color = AccentOrange)
                        if (fuelDelta < -0.5f)
                            Text("(%.0f%%)".format(fuelDelta), fontSize = 11.sp, color = AccentOrange)
                    }
                }

                // Vel. máxima + pot. motor pico + temperatura externa
                if (entry.maxSpeedKmh > 0f || entry.maxPowerPct > 0 || entry.outsideTempC != null) {
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        if (entry.maxSpeedKmh > 0f)
                            AutoDetailMetric("Vel. Máxima", "%.0f km/h".format(entry.maxSpeedKmh), TextPrimary, Modifier.weight(1f))
                        else
                            Spacer(Modifier.weight(1f))
                        if (entry.maxPowerPct > 0)
                            AutoDetailMetric("Pico Motor", "${entry.maxPowerPct}%", AccentOrange, Modifier.weight(1f))
                        else
                            Spacer(Modifier.weight(1f))
                        if (entry.outsideTempC != null)
                            AutoDetailMetric("Temperatura", "%.0f°C".format(entry.outsideTempC), AccentBlue, Modifier.weight(1f))
                        else
                            Spacer(Modifier.weight(1f))
                        Spacer(Modifier.weight(1f))
                    }
                }

                // Localização (se GPS disponível)
                if (entry.startLat != 0.0 || entry.startLng != 0.0) {
                    Text(
                        "📍 (%.4f, %.4f) → (%.4f, %.4f)".format(
                            entry.startLat, entry.startLng, entry.endLat, entry.endLng
                        ),
                        fontSize = 10.sp,
                        color    = TextSecondary,
                    )
                }

                // Botão renomear
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                    TextButton(
                        onClick        = { renameText = entry.name; showRenameDialog = true },
                        contentPadding = PaddingValues(horizontal = 8.dp, vertical = 4.dp),
                    ) {
                        Icon(Icons.Default.Edit, contentDescription = "Renomear", tint = AccentBlue, modifier = Modifier.size(15.dp))
                        Spacer(Modifier.width(4.dp))
                        Text(
                            if (entry.name.isEmpty()) "Nomear" else "Renomear",
                            fontSize = 13.sp,
                            color    = AccentBlue,
                        )
                    }
                }
            }
        }
    }
}

// ── Métricas inline da linha compacta ─────────────────────────────────────────

@Composable
private fun AutoCompactMetric(value: String, label: String, valueColor: Color = TextPrimary) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(value, fontSize = 12.sp, fontWeight = FontWeight.Bold, color = valueColor)
        Text(label, fontSize = 10.sp, color = TextSecondary)
    }
}

// ── Métricas da seção expandida ───────────────────────────────────────────────

@Composable
private fun AutoDetailMetric(
    label:    String,
    value:    String,
    color:    Color    = TextPrimary,
    modifier: Modifier = Modifier,
) {
    Column(modifier = modifier) {
        Text(value, fontSize = 14.sp, fontWeight = FontWeight.Bold, color = color)
        Text(label, fontSize = 11.sp, color = TextSecondary)
    }
}
