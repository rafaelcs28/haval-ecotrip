package br.com.redesurftank.ecotrip.ui.screens

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import br.com.redesurftank.ecotrip.managers.ChargeHistoryEntry
import br.com.redesurftank.ecotrip.ui.theme.*
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import java.util.TimeZone

// ── Filtros de período predefinido ────────────────────────────────────────────

private enum class ChargeFilter(val label: String) {
    ALL      ("Tudo"),
    TODAY    ("Hoje"),
    DAYS_7   ("7 dias"),
    DAYS_30  ("30 dias"),
    THIS_MONTH("Este mês"),
}

private fun List<ChargeHistoryEntry>.applyPreset(filter: ChargeFilter): List<ChargeHistoryEntry> {
    if (filter == ChargeFilter.ALL) return this
    val cal = Calendar.getInstance()
    val threshold: Long = when (filter) {
        ChargeFilter.TODAY -> {
            cal.set(Calendar.HOUR_OF_DAY, 0); cal.set(Calendar.MINUTE, 0)
            cal.set(Calendar.SECOND, 0);      cal.set(Calendar.MILLISECOND, 0)
            cal.timeInMillis
        }
        ChargeFilter.DAYS_7  -> System.currentTimeMillis() - 7L  * 86_400_000L
        ChargeFilter.DAYS_30 -> System.currentTimeMillis() - 30L * 86_400_000L
        ChargeFilter.THIS_MONTH -> {
            cal.set(Calendar.DAY_OF_MONTH, 1)
            cal.set(Calendar.HOUR_OF_DAY, 0); cal.set(Calendar.MINUTE, 0)
            cal.set(Calendar.SECOND, 0);      cal.set(Calendar.MILLISECOND, 0)
            cal.timeInMillis
        }
        ChargeFilter.ALL -> 0L
    }
    return filter { it.timestampMs >= threshold }
}

// ── Converte UTC midnight (DatePicker) → meia-noite local ────────────────────

private fun utcMsToLocalMidnight(utcMs: Long): Long {
    val utcCal = Calendar.getInstance(TimeZone.getTimeZone("UTC"))
    utcCal.timeInMillis = utcMs
    return Calendar.getInstance().apply {
        set(
            utcCal.get(Calendar.YEAR),
            utcCal.get(Calendar.MONTH),
            utcCal.get(Calendar.DAY_OF_MONTH),
            0, 0, 0,
        )
        set(Calendar.MILLISECOND, 0)
    }.timeInMillis
}

// ── Screen ────────────────────────────────────────────────────────────────────

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChargeHistoryScreen(
    entries: List<ChargeHistoryEntry>,
    onClearHistory: () -> Unit,
    onBack: () -> Unit,
) {
    // ── Estado dos filtros ────────────────────────────────────────────────────
    var selectedFilter    by remember { mutableStateOf(ChargeFilter.ALL) }
    var customStartDayMs  by remember { mutableStateOf<Long?>(null) }
    var customEndDayMs    by remember { mutableStateOf<Long?>(null) }
    var showStartPicker   by remember { mutableStateOf(false) }
    var showEndPicker     by remember { mutableStateOf(false) }

    val startPickerState = rememberDatePickerState()
    val endPickerState   = rememberDatePickerState()

    val dateLabelFmt = remember { SimpleDateFormat("dd/MM/yy", Locale.getDefault()) }

    val hasCustomRange = customStartDayMs != null || customEndDayMs != null

    // ── Lista filtrada ────────────────────────────────────────────────────────
    val filtered = remember(entries, selectedFilter, customStartDayMs, customEndDayMs) {
        if (hasCustomRange) {
            val start = customStartDayMs ?: 0L
            val end   = if (customEndDayMs != null) {
                Calendar.getInstance().apply {
                    timeInMillis = customEndDayMs!!
                    set(Calendar.HOUR_OF_DAY, 23)
                    set(Calendar.MINUTE, 59)
                    set(Calendar.SECOND, 59)
                    set(Calendar.MILLISECOND, 999)
                }.timeInMillis
            } else Long.MAX_VALUE
            entries.filter { it.timestampMs in start..end }
        } else {
            entries.applyPreset(selectedFilter)
        }
    }

    // ── Totais do período ─────────────────────────────────────────────────────
    val totalKwh    = remember(filtered) { filtered.sumOf { it.energyKwh.toDouble() }.toFloat() }
    val totalSec    = remember(filtered) { filtered.sumOf { it.durationSec } }
    val showSummary = selectedFilter != ChargeFilter.ALL || hasCustomRange

    // ── DatePicker — Início ───────────────────────────────────────────────────
    if (showStartPicker) {
        DatePickerDialog(
            onDismissRequest = { showStartPicker = false },
            confirmButton = {
                TextButton(onClick = {
                    startPickerState.selectedDateMillis?.let { utcMs ->
                        customStartDayMs = utcMsToLocalMidnight(utcMs)
                        selectedFilter   = ChargeFilter.ALL   // desativa preset
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
                        customEndDayMs = utcMsToLocalMidnight(utcMs)
                        selectedFilter = ChargeFilter.ALL
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

    // ── Layout principal ──────────────────────────────────────────────────────
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
                Text("Recargas", fontSize = 21.sp, fontWeight = FontWeight.Bold, color = AuroraTeal)
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    if (showSummary) "${filtered.size}/${entries.size} sessões"
                    else "${entries.size} sessões",
                    fontSize = 12.sp, color = TextSecondary,
                )
                if (entries.isNotEmpty()) {
                    TextButton(onClick = onClearHistory) {
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
            ChargeFilter.entries.forEach { filter ->
                val selected = !hasCustomRange && filter == selectedFilter
                FilterChip(
                    selected = selected,
                    onClick  = {
                        selectedFilter   = filter
                        customStartDayMs = null   // limpa datas customizadas
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
                        selectedContainerColor = AuroraTeal.copy(alpha = 0.20f),
                        selectedLabelColor     = AuroraTeal,
                        containerColor         = SurfaceCard,
                        labelColor             = if (hasCustomRange) TextSecondary.copy(alpha = 0.4f) else TextSecondary,
                    ),
                    border = FilterChipDefaults.filterChipBorder(
                        enabled             = true,
                        selected            = selected,
                        selectedBorderColor = AuroraTeal.copy(alpha = 0.6f),
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
            // Botão "De:"
            val startLabel = customStartDayMs?.let { dateLabelFmt.format(Date(it)) } ?: "De"
            val startActive = customStartDayMs != null
            OutlinedButton(
                onClick = { showStartPicker = true },
                modifier = Modifier.height(36.dp),
                shape  = RoundedCornerShape(8.dp),
                colors = ButtonDefaults.outlinedButtonColors(
                    containerColor = if (startActive) AuroraTeal.copy(alpha = 0.12f) else SurfaceCard,
                    contentColor   = if (startActive) AuroraTeal else TextSecondary,
                ),
                border = androidx.compose.foundation.BorderStroke(
                    1.dp,
                    if (startActive) AuroraTeal.copy(alpha = 0.5f) else BorderColor,
                ),
                contentPadding = PaddingValues(horizontal = 12.dp, vertical = 0.dp),
            ) {
                Text("📅 $startLabel", fontSize = 12.sp, fontWeight = if (startActive) FontWeight.Bold else FontWeight.Normal)
            }

            Text("—", fontSize = 12.sp, color = TextSecondary)

            // Botão "Até:"
            val endLabel = customEndDayMs?.let { dateLabelFmt.format(Date(it)) } ?: "Até"
            val endActive = customEndDayMs != null
            OutlinedButton(
                onClick = { showEndPicker = true },
                modifier = Modifier.height(36.dp),
                shape  = RoundedCornerShape(8.dp),
                colors = ButtonDefaults.outlinedButtonColors(
                    containerColor = if (endActive) AuroraTeal.copy(alpha = 0.12f) else SurfaceCard,
                    contentColor   = if (endActive) AuroraTeal else TextSecondary,
                ),
                border = ButtonDefaults.outlinedButtonBorder.copy(
                    brush = androidx.compose.ui.graphics.SolidColor(
                        if (endActive) AuroraTeal.copy(alpha = 0.5f) else BorderColor
                    )
                ),
                contentPadding = PaddingValues(horizontal = 12.dp, vertical = 0.dp),
            ) {
                Text("📅 $endLabel", fontSize = 12.sp, fontWeight = if (endActive) FontWeight.Bold else FontWeight.Normal)
            }

            // Limpar datas customizadas
            AnimatedVisibility(visible = hasCustomRange) {
                IconButton(
                    onClick = { customStartDayMs = null; customEndDayMs = null },
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
                    .background(AuroraTeal.copy(alpha = 0.07f), RoundedCornerShape(12.dp))
                    .border(1.dp, AuroraTeal.copy(alpha = 0.25f), RoundedCornerShape(12.dp))
                    .padding(horizontal = 16.dp, vertical = 10.dp),
                horizontalArrangement = Arrangement.spacedBy(0.dp),
            ) {
                PeriodStat(value = "${filtered.size}", label = "Sessões", modifier = Modifier.weight(1f))
                PeriodStat(
                    value    = "%.2f kWh".format(totalKwh),
                    label    = "Total Carregado",
                    modifier = Modifier.weight(1.8f),
                    color    = AuroraTeal,
                )
                PeriodStat(
                    value    = formatChargeDuration(totalSec),
                    label    = "Tempo Total",
                    modifier = Modifier.weight(1.4f),
                )
                if (filtered.size > 1) {
                    PeriodStat(
                        value    = "%.2f kWh".format(totalKwh / filtered.size),
                        label    = "Média/Sessão",
                        modifier = Modifier.weight(1.4f),
                    )
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
                    "Nenhuma recarga entre $s e $e."
                } else {
                    "Nenhuma recarga em \"${selectedFilter.label}\"."
                }
                Text(label, fontSize = 13.sp, color = TextSecondary)
            }
        }

        // ── Lista ─────────────────────────────────────────────────────────────
        if (entries.isEmpty()) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text("Nenhuma sessão de recarga registrada ainda.", fontSize = 14.sp, color = TextSecondary)
            }
        } else {
            LazyColumn(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                itemsIndexed(filtered) { _, entry ->
                    ChargeEntryRow(entry = entry)
                }
            }
        }
    }
}

// ── Stat do resumo ────────────────────────────────────────────────────────────

@Composable
private fun PeriodStat(
    value:    String,
    label:    String,
    modifier: Modifier = Modifier,
    color:    androidx.compose.ui.graphics.Color = TextPrimary,
) {
    Column(modifier = modifier) {
        Text(value, fontSize = 15.sp, fontWeight = FontWeight.Bold, color = color)
        Text(label, fontSize = 10.sp,  color = TextSecondary)
    }
}

// ── Linha de entrada ──────────────────────────────────────────────────────────

@Composable
private fun ChargeEntryRow(entry: ChargeHistoryEntry) {
    val dateFmt = SimpleDateFormat("dd/MM/yy HH:mm", Locale.getDefault())

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(SurfaceCard, RoundedCornerShape(12.dp))
            .border(1.dp, BorderColor, RoundedCornerShape(12.dp))
            .padding(horizontal = 14.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Box(
                    modifier = Modifier
                        .background(AuroraTeal.copy(alpha = 0.12f), RoundedCornerShape(6.dp))
                        .border(1.dp, AuroraTeal.copy(alpha = 0.3f), RoundedCornerShape(6.dp))
                        .padding(horizontal = 6.dp, vertical = 2.dp),
                ) { Text("⚡", fontSize = 11.sp) }
                Text(dateFmt.format(Date(entry.timestampMs)), fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = TextPrimary)
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Text("%.0f%%".format(entry.startSocPct), fontSize = 13.sp, color = TextSecondary)
                Text("→", fontSize = 11.sp, color = TextSecondary)
                Text("%.0f%%".format(entry.endSocPct), fontSize = 13.sp, fontWeight = FontWeight.Bold, color = AuroraTeal)
            }
        }

        HorizontalDivider(color = Separator, thickness = 0.5.dp)

        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(0.dp)) {
            ChargeMetric(value = formatChargeDuration(entry.durationSec), label = "Duração",    modifier = Modifier.weight(1f))
            ChargeMetric(value = "%.2f kWh".format(entry.energyKwh),     label = "Energia",    modifier = Modifier.weight(1f), color = AuroraTeal)
            ChargeMetric(value = "%.1f kW".format(entry.avgPowerKw),      label = "Pot. Média", modifier = Modifier.weight(1f))
        }
    }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

@Composable
private fun ChargeMetric(
    value:    String,
    label:    String,
    modifier: Modifier = Modifier,
    color:    androidx.compose.ui.graphics.Color = TextPrimary,
) {
    Column(modifier = modifier) {
        Text(value, fontSize = 14.sp, fontWeight = FontWeight.Bold, color = color)
        Text(label, fontSize = 11.sp, color = TextSecondary)
    }
}

private fun formatChargeDuration(sec: Long): String {
    val h = sec / 3600
    val m = (sec % 3600) / 60
    return if (h > 0) "${h}h ${m}min" else "${m}min"
}
