package br.com.redesurftank.ecotrip.ui.screens

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
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

// ── Screen ────────────────────────────────────────────────────────────────────

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AutoTripsScreen(
    entries: List<AutoTripEntry>,
    onClear: () -> Unit,
    onBack:  () -> Unit,
) {
    var selectedFilter   by remember { mutableStateOf(AutoTripFilter.ALL) }
    var customStartDayMs by remember { mutableStateOf<Long?>(null) }
    var customEndDayMs   by remember { mutableStateOf<Long?>(null) }
    var showStartPicker  by remember { mutableStateOf(false) }
    var showEndPicker    by remember { mutableStateOf(false) }

    val startPickerState = rememberDatePickerState()
    val endPickerState   = rememberDatePickerState()
    val dateLabelFmt     = remember { SimpleDateFormat("dd/MM/yy", Locale.getDefault()) }

    val hasCustomRange = customStartDayMs != null || customEndDayMs != null

    // ── Lista filtrada ────────────────────────────────────────────────────────
    val filtered = remember(entries, selectedFilter, customStartDayMs, customEndDayMs) {
        if (hasCustomRange) {
            val start = customStartDayMs ?: 0L
            val end   = if (customEndDayMs != null) {
                Calendar.getInstance().apply {
                    timeInMillis = customEndDayMs!!
                    set(Calendar.HOUR_OF_DAY, 23); set(Calendar.MINUTE, 59)
                    set(Calendar.SECOND, 59);       set(Calendar.MILLISECOND, 999)
                }.timeInMillis
            } else Long.MAX_VALUE
            entries.filter { it.startMs in start..end }
        } else {
            entries.applyPreset(selectedFilter)
        }
    }

    // ── Totais do período ─────────────────────────────────────────────────────
    val totalKm     = remember(filtered) { filtered.sumOf { it.distKm.toDouble() }.toFloat() }
    val totalSec    = remember(filtered) { filtered.sumOf { it.timeSec } }
    val totalNet    = remember(filtered) { filtered.sumOf { it.netKwh.toDouble() }.toFloat() }
    val totalFuel   = remember(filtered) { filtered.sumOf { it.fuelL.toDouble() }.toFloat() }
    val showSummary = selectedFilter != AutoTripFilter.ALL || hasCustomRange

    // ── DatePicker — Início ───────────────────────────────────────────────────
    if (showStartPicker) {
        DatePickerDialog(
            onDismissRequest = { showStartPicker = false },
            confirmButton = {
                TextButton(onClick = {
                    startPickerState.selectedDateMillis?.let { utcMs ->
                        customStartDayMs = autoTripUtcMsToLocalMidnight(utcMs)
                        selectedFilter   = AutoTripFilter.ALL
                    }
                    showStartPicker = false
                }) { Text("OK") }
            },
            dismissButton = {
                TextButton(onClick = { showStartPicker = false }) { Text("Cancelar") }
            },
        ) {
            DatePicker(state = startPickerState, title = {
                Text("Data inicial", modifier = Modifier.padding(start = 24.dp, top = 16.dp), fontSize = 14.sp)
            })
        }
    }

    // ── DatePicker — Fim ──────────────────────────────────────────────────────
    if (showEndPicker) {
        DatePickerDialog(
            onDismissRequest = { showEndPicker = false },
            confirmButton = {
                TextButton(onClick = {
                    endPickerState.selectedDateMillis?.let { utcMs ->
                        customEndDayMs = autoTripUtcMsToLocalMidnight(utcMs)
                        selectedFilter = AutoTripFilter.ALL
                    }
                    showEndPicker = false
                }) { Text("OK") }
            },
            dismissButton = {
                TextButton(onClick = { showEndPicker = false }) { Text("Cancelar") }
            },
        ) {
            DatePicker(state = endPickerState, title = {
                Text("Data final", modifier = Modifier.padding(start = 24.dp, top = 16.dp), fontSize = 14.sp)
            })
        }
    }

    // ── Layout ────────────────────────────────────────────────────────────────
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(SurfaceDeep)
            .systemBarsPadding()
            .padding(horizontal = 10.dp, vertical = 4.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {

        // Cabeçalho
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                IconButton(onClick = onBack) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Voltar", tint = TextSecondary)
                }
                Text("Viagens Auto", fontSize = 21.sp, fontWeight = FontWeight.Bold, color = AccentBlue)
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    if (showSummary) "${filtered.size}/${entries.size} viagens"
                    else "${entries.size} viagens",
                    fontSize = 12.sp, color = TextSecondary,
                )
                if (entries.isNotEmpty()) {
                    TextButton(onClick = onClear) {
                        Text("Limpar", fontSize = 13.sp, color = TextSecondary)
                    }
                }
            }
        }

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

            AnimatedVisibility(visible = hasCustomRange) {
                IconButton(
                    onClick  = { customStartDayMs = null; customEndDayMs = null },
                    modifier = Modifier.size(36.dp),
                ) {
                    Icon(Icons.Default.Close, contentDescription = "Limpar datas", tint = TextSecondary, modifier = Modifier.size(18.dp))
                }
            }
        }

        // ── Card de resumo do período ─────────────────────────────────────────
        AnimatedVisibility(visible = showSummary && filtered.isNotEmpty()) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(AccentBlue.copy(alpha = 0.07f), RoundedCornerShape(12.dp))
                    .border(1.dp, AccentBlue.copy(alpha = 0.25f), RoundedCornerShape(12.dp))
                    .padding(horizontal = 16.dp, vertical = 10.dp),
                horizontalArrangement = Arrangement.spacedBy(0.dp),
            ) {
                AutoPeriodStat("${filtered.size}", "Viagens", modifier = Modifier.weight(1f))
                AutoPeriodStat("%.1f km".format(totalKm), "Distância", color = AccentBlue, modifier = Modifier.weight(1.4f))
                AutoPeriodStat(fmtAutoTripDur(totalSec), "Tempo", modifier = Modifier.weight(1.4f))
                AutoPeriodStat("%.2f kWh".format(totalNet), "kWh líq.", color = Green, modifier = Modifier.weight(1.5f))
                if (totalFuel > 0.001f) {
                    AutoPeriodStat("%.2f L".format(totalFuel), "Combustível", color = AccentOrange, modifier = Modifier.weight(1.3f))
                }
            }
        }

        AnimatedVisibility(visible = showSummary && filtered.isEmpty()) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(SurfaceCard, RoundedCornerShape(12.dp))
                    .border(1.dp, BorderColor, RoundedCornerShape(12.dp))
                    .padding(16.dp),
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
        if (entries.isEmpty()) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text(
                    "Nenhuma viagem automática registrada ainda.\nAs viagens são criadas ao mudar de P para D ou R.",
                    fontSize = 14.sp,
                    color = TextSecondary,
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                )
            }
        } else {
            LazyColumn(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                itemsIndexed(filtered) { _, entry ->
                    AutoTripEntryRow(entry = entry)
                }
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
private fun AutoTripEntryRow(entry: AutoTripEntry) {
    var expanded by remember { mutableStateOf(false) }

    val dateFmtFull = remember { SimpleDateFormat("dd/MM HH:mm", Locale.getDefault()) }
    val timeFmt     = remember { SimpleDateFormat("HH:mm", Locale.getDefault()) }

    val durationSec = (entry.endMs - entry.startMs) / 1000L
    val avgSpeed    = if (entry.timeSec > 0) entry.distKm / (entry.timeSec / 3600f) else 0f
    val socDelta    = entry.endSocPct - entry.startSocPct
    val fuelDelta   = entry.endFuelPct - entry.startFuelPct
    val socColor    = when {
        socDelta > -10f -> Green
        socDelta > -25f -> WarnYellow
        else            -> AccentOrange
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(SurfaceCard, RoundedCornerShape(12.dp))
            .border(1.dp, BorderColor, RoundedCornerShape(12.dp))
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

            // Data + horário
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    "${dateFmtFull.format(Date(entry.startMs))} → ${timeFmt.format(Date(entry.endMs))}",
                    fontSize   = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    color      = TextPrimary,
                    maxLines   = 1,
                    overflow   = TextOverflow.Ellipsis,
                )
                Text(fmtAutoTripDur(durationSec), fontSize = 11.sp, color = TextSecondary)
            }

            // Métricas inline
            AutoCompactMetric("%.1f km".format(entry.distKm),   "dist")
            AutoCompactMetric("%.1f kWh".format(entry.netKwh),  "liq.")
            if (entry.fuelL > 0.001f)
                AutoCompactMetric("%.2f L".format(entry.fuelL), "comb")

            // Botão expandir
            Icon(
                if (expanded) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                contentDescription = if (expanded) "Recolher" else "Expandir",
                tint     = TextSecondary,
                modifier = Modifier.size(18.dp),
            )
        }

        // ── Detalhes expandidos ────────────────────────────────────────────────
        AnimatedVisibility(visible = expanded) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(start = 14.dp, end = 14.dp, bottom = 12.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                HorizontalDivider(color = Separator, thickness = 0.5.dp)
                Spacer(Modifier.height(2.dp))

                // Linha 1: km, vel, kWh liq, combustível
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    AutoDetailMetric("Distância",  "%.1f km".format(entry.distKm),        AccentBlue,   Modifier.weight(1f))
                    AutoDetailMetric("Vel. Média", "%.1f km/h".format(avgSpeed),           TextPrimary,  Modifier.weight(1f))
                    AutoDetailMetric("kWh líquido","%.2f kWh".format(entry.netKwh),        Green,        Modifier.weight(1f))
                    if (entry.fuelL > 0.001f)
                        AutoDetailMetric("Combustível","%.3f L".format(entry.fuelL),       AccentOrange, Modifier.weight(1f))
                }

                // Linha 2: energia bruta, regen, condução
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    AutoDetailMetric("Bruto",      "%.2f kWh".format(entry.energyKwh),    TextSecondary, Modifier.weight(1f))
                    AutoDetailMetric("Regenerado", "%.2f kWh".format(entry.regenKwh),     AuroraTeal,    Modifier.weight(1f))
                    AutoDetailMetric("Cond. efetiva", fmtAutoTripDur(entry.timeSec),       TextSecondary, Modifier.weight(1f))
                }

                // Linha 3: SOC início → fim
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

                // Linha 4: Combustível % início → fim
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
            }
        }
    }
}

// ── Métricas inline da linha compacta ─────────────────────────────────────────

@Composable
private fun AutoCompactMetric(value: String, label: String) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(value, fontSize = 12.sp, fontWeight = FontWeight.Bold, color = TextPrimary)
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
