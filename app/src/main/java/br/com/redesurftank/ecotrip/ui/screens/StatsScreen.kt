package br.com.redesurftank.ecotrip.ui.screens

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import br.com.redesurftank.ecotrip.managers.ChargeHistoryEntry
import br.com.redesurftank.ecotrip.managers.TripHistoryEntry
import br.com.redesurftank.ecotrip.ui.theme.*
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import java.util.TimeZone

// ── Filtros de período ────────────────────────────────────────────────────────

private enum class StatsFilter(val label: String) {
    ALL       ("Tudo"),
    TODAY     ("Hoje"),
    DAYS_7    ("7 dias"),
    DAYS_30   ("30 dias"),
    THIS_MONTH("Este mês"),
}

private fun <T> List<T>.applyStatsFilter(
    filter: StatsFilter,
    getTs:  (T) -> Long,
): List<T> {
    if (filter == StatsFilter.ALL) return this
    val cal = Calendar.getInstance()
    val threshold: Long = when (filter) {
        StatsFilter.TODAY -> {
            cal.set(Calendar.HOUR_OF_DAY, 0); cal.set(Calendar.MINUTE, 0)
            cal.set(Calendar.SECOND, 0);      cal.set(Calendar.MILLISECOND, 0)
            cal.timeInMillis
        }
        StatsFilter.DAYS_7   -> System.currentTimeMillis() - 7L  * 86_400_000L
        StatsFilter.DAYS_30  -> System.currentTimeMillis() - 30L * 86_400_000L
        StatsFilter.THIS_MONTH -> {
            cal.set(Calendar.DAY_OF_MONTH, 1)
            cal.set(Calendar.HOUR_OF_DAY, 0); cal.set(Calendar.MINUTE, 0)
            cal.set(Calendar.SECOND, 0);      cal.set(Calendar.MILLISECOND, 0)
            cal.timeInMillis
        }
        StatsFilter.ALL -> 0L
    }
    return filter { getTs(it) >= threshold }
}

private fun statsUtcMsToLocalMidnight(utcMs: Long): Long {
    val utcCal = Calendar.getInstance(TimeZone.getTimeZone("UTC"))
    utcCal.timeInMillis = utcMs
    return Calendar.getInstance().apply {
        set(utcCal.get(Calendar.YEAR), utcCal.get(Calendar.MONTH),
            utcCal.get(Calendar.DAY_OF_MONTH), 0, 0, 0)
        set(Calendar.MILLISECOND, 0)
    }.timeInMillis
}

private fun fmtStatDur(sec: Long): String {
    val d = sec / 86400
    val h = (sec % 86400) / 3600
    val m = (sec % 3600) / 60
    return when {
        d > 0 -> "${d}d ${h}h ${m}min"
        h > 0 -> "${h}h ${m}min"
        else  -> "${m}min"
    }
}

// ── Dados agregados ───────────────────────────────────────────────────────────

private data class DriveStats(
    val count:        Int,
    val distKm:       Float,
    val timeSec:      Long,
    val energyKwh:    Float,
    val regenKwh:     Float,
    val fuelL:        Float,
    val costBrl:      Float,
) {
    val netKwh:      Float get() = energyKwh - regenKwh
    val avgSpeedKmh: Float get() = if (timeSec > 0) distKm / (timeSec / 3600f) else 0f
    val kwhPer100km: Float get() = if (distKm > 0.1f) (netKwh / distKm) * 100f else 0f
    val kmPerL:      Float get() = if (fuelL > 0.001f) distKm / fuelL else 0f
    val costPerKm:   Float get() = if (distKm > 0.1f && costBrl > 0f) costBrl / distKm else 0f
    val hasCost:     Boolean get() = costBrl > 0.01f
}

private data class ChargeStats(
    val count:       Int,
    val energyKwh:   Float,
    val durationSec: Long,
) {
    val avgPowerKw: Float get() = if (durationSec > 0) energyKwh / (durationSec / 3600f) else 0f
}

private fun List<TripHistoryEntry>.aggregate(): DriveStats = DriveStats(
    count     = size,
    distKm    = sumOf { it.distKm.toDouble() }.toFloat(),
    timeSec   = sumOf { it.timeSec },
    energyKwh = sumOf { it.energyKwh.toDouble() }.toFloat(),
    regenKwh  = sumOf { it.regenKwh.toDouble() }.toFloat(),
    fuelL     = sumOf { it.fuelL.toDouble() }.toFloat(),
    costBrl   = sumOf { it.costBrl.toDouble() }.toFloat(),
)

private fun List<ChargeHistoryEntry>.aggregate(): ChargeStats = ChargeStats(
    count       = size,
    energyKwh   = sumOf { it.energyKwh.toDouble() }.toFloat(),
    durationSec = sumOf { it.durationSec },
)

// ── Screen ────────────────────────────────────────────────────────────────────

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun StatsScreen(
    trips:   List<TripHistoryEntry>,
    charges: List<ChargeHistoryEntry>,
    onBack:  () -> Unit,
) {
    var selectedFilter   by remember { mutableStateOf(StatsFilter.ALL) }
    var customStartDayMs by remember { mutableStateOf<Long?>(null) }
    var customEndDayMs   by remember { mutableStateOf<Long?>(null) }
    var showStartPicker  by remember { mutableStateOf(false) }
    var showEndPicker    by remember { mutableStateOf(false) }

    val startPickerState = rememberDatePickerState()
    val endPickerState   = rememberDatePickerState()
    val dateLabelFmt     = remember { SimpleDateFormat("dd/MM/yy", Locale.getDefault()) }

    val hasCustomRange = customStartDayMs != null || customEndDayMs != null

    // Listas filtradas
    val filteredTrips = remember(trips, selectedFilter, customStartDayMs, customEndDayMs) {
        if (hasCustomRange) {
            val start = customStartDayMs ?: 0L
            val end   = if (customEndDayMs != null) {
                Calendar.getInstance().apply {
                    timeInMillis = customEndDayMs!!
                    set(Calendar.HOUR_OF_DAY, 23); set(Calendar.MINUTE, 59)
                    set(Calendar.SECOND, 59); set(Calendar.MILLISECOND, 999)
                }.timeInMillis
            } else Long.MAX_VALUE
            trips.filter { it.timestampMs in start..end }
        } else trips.applyStatsFilter(selectedFilter) { it.timestampMs }
    }

    val filteredCharges = remember(charges, selectedFilter, customStartDayMs, customEndDayMs) {
        if (hasCustomRange) {
            val start = customStartDayMs ?: 0L
            val end   = if (customEndDayMs != null) {
                Calendar.getInstance().apply {
                    timeInMillis = customEndDayMs!!
                    set(Calendar.HOUR_OF_DAY, 23); set(Calendar.MINUTE, 59)
                    set(Calendar.SECOND, 59); set(Calendar.MILLISECOND, 999)
                }.timeInMillis
            } else Long.MAX_VALUE
            charges.filter { it.timestampMs in start..end }
        } else charges.applyStatsFilter(selectedFilter) { it.timestampMs }
    }

    val driveStats  = remember(filteredTrips)   { filteredTrips.aggregate() }
    val chargeStats = remember(filteredCharges) { filteredCharges.aggregate() }

    // ── DatePicker — Início ───────────────────────────────────────────────────
    if (showStartPicker) {
        DatePickerDialog(
            onDismissRequest = { showStartPicker = false },
            confirmButton = {
                TextButton(onClick = {
                    startPickerState.selectedDateMillis?.let { utcMs ->
                        customStartDayMs = statsUtcMsToLocalMidnight(utcMs)
                        selectedFilter   = StatsFilter.ALL
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
                        customEndDayMs = statsUtcMsToLocalMidnight(utcMs)
                        selectedFilter = StatsFilter.ALL
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
                Text("Estatísticas", fontSize = 21.sp, fontWeight = FontWeight.Bold, color = Green)
            }
            if (hasCustomRange || selectedFilter != StatsFilter.ALL) {
                val s = customStartDayMs?.let { dateLabelFmt.format(Date(it)) }
                val e = customEndDayMs?.let   { dateLabelFmt.format(Date(it)) }
                val periodLabel = when {
                    s != null && e != null -> "$s – $e"
                    s != null              -> "desde $s"
                    e != null              -> "até $e"
                    else                   -> selectedFilter.label
                }
                Text(periodLabel, fontSize = 11.sp, color = TextSecondary)
            }
        }

        // Chips de período predefinido
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            StatsFilter.entries.forEach { filter ->
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
                        selectedContainerColor = Green.copy(alpha = 0.18f),
                        selectedLabelColor     = Green,
                        containerColor         = SurfaceCard,
                        labelColor             = if (hasCustomRange) TextSecondary.copy(alpha = 0.4f) else TextSecondary,
                    ),
                    border = FilterChipDefaults.filterChipBorder(
                        enabled             = true,
                        selected            = selected,
                        selectedBorderColor = Green.copy(alpha = 0.5f),
                        borderColor         = if (hasCustomRange) BorderColor.copy(alpha = 0.4f) else BorderColor,
                        borderWidth         = 1.dp,
                        selectedBorderWidth = 1.dp,
                    ),
                )
            }
        }

        // Seletor de datas customizado
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
                    containerColor = if (startActive) Green.copy(alpha = 0.10f) else SurfaceCard,
                    contentColor   = if (startActive) Green else TextSecondary,
                ),
                border = androidx.compose.foundation.BorderStroke(
                    1.dp, if (startActive) Green.copy(alpha = 0.5f) else BorderColor,
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
                    containerColor = if (endActive) Green.copy(alpha = 0.10f) else SurfaceCard,
                    contentColor   = if (endActive) Green else TextSecondary,
                ),
                border = androidx.compose.foundation.BorderStroke(
                    1.dp, if (endActive) Green.copy(alpha = 0.5f) else BorderColor,
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

        // Conteúdo — scrollável
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {

            // ── Sem dados ─────────────────────────────────────────────────────
            if (filteredTrips.isEmpty() && filteredCharges.isEmpty()) {
                Box(Modifier.fillMaxWidth().padding(top = 32.dp), contentAlignment = Alignment.Center) {
                    val msg = when {
                        trips.isEmpty() && charges.isEmpty() ->
                            "Nenhum dado registrado ainda.\nDirija e recarregue para ver estatísticas."
                        hasCustomRange -> {
                            val s = customStartDayMs?.let { dateLabelFmt.format(Date(it)) } ?: "?"
                            val e = customEndDayMs?.let   { dateLabelFmt.format(Date(it)) } ?: "?"
                            "Nenhum dado entre $s e $e."
                        }
                        else -> "Nenhum dado em \"${selectedFilter.label}\"."
                    }
                    Text(msg, fontSize = 13.sp, color = TextSecondary, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                }
            }

            // ── Seção CONDUÇÃO ────────────────────────────────────────────────
            AnimatedVisibility(visible = filteredTrips.isNotEmpty()) {
                StatSection(
                    title      = "Condução",
                    subtitle   = "${driveStats.count} ${if (driveStats.count == 1) "viagem" else "viagens"}",
                    accentColor = Green,
                ) {
                    // Linha 1 — distância, tempo, velocidade
                    StatRow {
                        StatCell("%.1f km".format(driveStats.distKm),       "Distância",    Green,  Modifier.weight(1f))
                        StatCell(fmtStatDur(driveStats.timeSec),              "Tempo",        Blue,   Modifier.weight(1f))
                        StatCell("%.1f km/h".format(driveStats.avgSpeedKmh), "Vel. Média",   TextPrimary, Modifier.weight(1f))
                    }
                    // Linha 2 — eficiência elétrica
                    StatRow {
                        StatCell("%.2f kWh/100".format(driveStats.kwhPer100km), "kWh/100km",    Green,  Modifier.weight(1f))
                        StatCell("%.2f kWh".format(driveStats.netKwh),           "Elétrico líq.", Green,  Modifier.weight(1f))
                        StatCell("%.2f kWh".format(driveStats.regenKwh),          "Regenerado",  AuroraTeal, Modifier.weight(1f))
                    }
                    // Linha 3 — combustível
                    if (driveStats.fuelL > 0.01f) {
                        StatRow {
                            StatCell("%.3f L".format(driveStats.fuelL),   "Combustível",  AccentOrange, Modifier.weight(1f))
                            StatCell("%.1f km/L".format(driveStats.kmPerL), "km/L",         AccentOrange, Modifier.weight(1f))
                            Spacer(Modifier.weight(1f))
                        }
                    }
                    // Linha 4 — custo
                    if (driveStats.hasCost) {
                        StatRow {
                            StatCell("R$ %.2f".format(driveStats.costBrl),    "Custo Total",  WarnYellow, Modifier.weight(1f))
                            StatCell("R$ %.3f/km".format(driveStats.costPerKm), "Custo/km",   WarnYellow, Modifier.weight(1f))
                            Spacer(Modifier.weight(1f))
                        }
                    }
                }
            }

            // ── Seção RECARGAS ────────────────────────────────────────────────
            AnimatedVisibility(visible = filteredCharges.isNotEmpty()) {
                StatSection(
                    title      = "Recargas",
                    subtitle   = "${chargeStats.count} ${if (chargeStats.count == 1) "sessão" else "sessões"}",
                    accentColor = AuroraTeal,
                ) {
                    StatRow {
                        StatCell("%.2f kWh".format(chargeStats.energyKwh),    "Total Carregado", AuroraTeal, Modifier.weight(1f))
                        StatCell(fmtStatDur(chargeStats.durationSec),           "Tempo Total",     Blue,       Modifier.weight(1f))
                        StatCell("%.1f kW".format(chargeStats.avgPowerKw),      "Pot. Média",      AuroraTeal, Modifier.weight(1f))
                    }
                }
            }

            // ── Resumo combinado (quando os dois têm dados) ───────────────────
            AnimatedVisibility(visible = filteredTrips.isNotEmpty() && filteredCharges.isNotEmpty() && driveStats.hasCost) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(WarnYellow.copy(alpha = 0.06f), RoundedCornerShape(12.dp))
                        .border(1.dp, WarnYellow.copy(alpha = 0.20f), RoundedCornerShape(12.dp))
                        .padding(horizontal = 14.dp, vertical = 10.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Text("Resumo do Período", fontSize = 12.sp, fontWeight = FontWeight.Bold, color = WarnYellow)
                    Spacer(Modifier.height(2.dp))
                    StatRow {
                        StatCell("R$ %.2f".format(driveStats.costBrl), "Custo Condução", WarnYellow, Modifier.weight(1f))
                        StatCell("%.2f kWh".format(driveStats.energyKwh), "Energia Bruta", Green,      Modifier.weight(1f))
                        StatCell("%.2f kWh".format(chargeStats.energyKwh), "kWh Carregado", AuroraTeal, Modifier.weight(1f))
                    }
                }
            }

            Spacer(Modifier.height(8.dp))
        }
    }
}

// ── Componentes internos ──────────────────────────────────────────────────────

@Composable
private fun StatSection(
    title:       String,
    subtitle:    String,
    accentColor: Color,
    content:     @Composable ColumnScope.() -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(SurfaceCard, RoundedCornerShape(12.dp))
            .border(1.dp, accentColor.copy(alpha = 0.25f), RoundedCornerShape(12.dp))
            .padding(horizontal = 14.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Box(
                modifier = Modifier
                    .background(accentColor.copy(alpha = 0.15f), RoundedCornerShape(6.dp))
                    .border(1.dp, accentColor.copy(alpha = 0.3f), RoundedCornerShape(6.dp))
                    .padding(horizontal = 8.dp, vertical = 2.dp),
            ) {
                Text(title, fontSize = 12.sp, fontWeight = FontWeight.Bold, color = accentColor)
            }
            Text(subtitle, fontSize = 11.sp, color = TextSecondary)
        }
        HorizontalDivider(color = accentColor.copy(alpha = 0.10f), thickness = 0.5.dp)
        content()
    }
}

@Composable
private fun StatRow(content: @Composable RowScope.() -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(0.dp),
        content = content,
    )
}

@Composable
private fun StatCell(
    value:    String,
    label:    String,
    color:    Color,
    modifier: Modifier = Modifier,
) {
    Column(modifier = modifier.padding(end = 4.dp)) {
        Text(value, fontSize = 14.sp, fontWeight = FontWeight.Bold, color = color)
        Text(label, fontSize = 10.sp,  color = TextSecondary)
    }
}
