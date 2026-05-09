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
import br.com.redesurftank.ecotrip.managers.TripManager
import br.com.redesurftank.ecotrip.managers.LifetimeCheckpoint
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

// ── Screen ────────────────────────────────────────────────────────────────────

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun StatsScreen(
    tripManager: TripManager,
    onBack:      () -> Unit,
) {
    // ── Snapshot atual e preços ───────────────────────────────────────────────
    val current = remember { tripManager.getLifetimeSnapshot() }
    val (priceGas, priceKwh) = remember { tripManager.getPrices() }

    // ── Estado de filtro ──────────────────────────────────────────────────────
    var selectedFilter  by remember { mutableStateOf(StatsFilter.ALL) }
    var customStartMs   by remember { mutableStateOf(0L) }   // 0 = não definido
    var showStartPicker by remember { mutableStateOf(false) }
    val startPickerState = rememberDatePickerState()
    val dateLabelFmt     = remember { SimpleDateFormat("dd/MM/yy", Locale.getDefault()) }

    val hasCustomStart = customStartMs > 0L

    // ── Timestamp de início do período ────────────────────────────────────────
    val periodStartMs: Long = remember(selectedFilter, customStartMs) {
        if (hasCustomStart) return@remember customStartMs
        val cal = Calendar.getInstance()
        when (selectedFilter) {
            StatsFilter.ALL        -> 0L
            StatsFilter.TODAY      -> cal.apply {
                set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
                set(Calendar.SECOND, 0);      set(Calendar.MILLISECOND, 0)
            }.timeInMillis
            StatsFilter.DAYS_7     -> System.currentTimeMillis() - 7L  * 86_400_000L
            StatsFilter.DAYS_30    -> System.currentTimeMillis() - 30L * 86_400_000L
            StatsFilter.THIS_MONTH -> cal.apply {
                set(Calendar.DAY_OF_MONTH, 1)
                set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
                set(Calendar.SECOND, 0);      set(Calendar.MILLISECOND, 0)
            }.timeInMillis
        }
    }

    // ── Baseline do período (null = "Tudo") ───────────────────────────────────
    val isFiltered = periodStartMs > 0L
    val baseline: LifetimeCheckpoint? = remember(periodStartMs) {
        if (!isFiltered) null else tripManager.getLifetimeBaselineAt(periodStartMs)
    }
    val noBaseline = isFiltered && baseline == null

    // ── Deltas (current - baseline) ───────────────────────────────────────────
    val dEnergy    = (current.energyKwh - (baseline?.energyKwh ?: 0f)).coerceAtLeast(0f)
    val dRegen     = (current.regenKwh  - (baseline?.regenKwh  ?: 0f)).coerceAtLeast(0f)
    val dNet       = (dEnergy - dRegen).coerceAtLeast(0f)
    val dDist      = (current.distKm    - (baseline?.distKm    ?: 0f)).coerceAtLeast(0f)
    val dTime      = (current.timeSec   - (baseline?.timeSec   ?: 0L)).coerceAtLeast(0L)
    val dFuel      = (current.fuelL     - (baseline?.fuelL     ?: 0f)).coerceAtLeast(0f)
    val dCharge    = (current.chargeKwh - (baseline?.chargeKwh ?: 0f)).coerceAtLeast(0f)
    val dChargeSec = (current.chargeSec - (baseline?.chargeSec ?: 0L)).coerceAtLeast(0L)

    // ── Métricas derivadas ────────────────────────────────────────────────────
    val avgSpeed    = if (dTime > 0) dDist / (dTime / 3600f) else 0f
    val kwh100km    = if (dDist > 0.1f) dNet / dDist * 100f else 0f
    val kmPerL      = if (dFuel > 0.001f) dDist / dFuel else 0f
    val costFuel    = dFuel * priceGas
    val costEnergy  = dCharge * priceKwh
    val costTotal   = costFuel + costEnergy
    val costPerKm   = if (dDist > 0.1f && costTotal > 0f) costTotal / dDist else 0f
    val avgChargeKw = if (dChargeSec > 0) dCharge / (dChargeSec / 3600f) else 0f

    val hasDriving = dDist > 0f || dTime > 0L
    val hasCharging = dCharge > 0f || dChargeSec > 0L

    // ── DatePicker — apenas início ────────────────────────────────────────────
    if (showStartPicker) {
        DatePickerDialog(
            onDismissRequest = { showStartPicker = false },
            confirmButton = {
                TextButton(onClick = {
                    startPickerState.selectedDateMillis?.let { utcMs ->
                        customStartMs  = statsUtcMsToLocalMidnight(utcMs)
                        selectedFilter = StatsFilter.ALL
                    }
                    showStartPicker = false
                }) { Text("OK") }
            },
            dismissButton = {
                TextButton(onClick = { showStartPicker = false }) { Text("Cancelar") }
            },
        ) {
            DatePicker(state = startPickerState, title = {
                Text("Desde quando?", modifier = Modifier.padding(start = 24.dp, top = 16.dp), fontSize = 14.sp)
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
            val periodLabel = when {
                hasCustomStart -> "desde ${dateLabelFmt.format(Date(customStartMs))}"
                selectedFilter != StatsFilter.ALL -> selectedFilter.label
                else -> "lifetime"
            }
            Text(periodLabel, fontSize = 11.sp, color = TextSecondary)
        }

        // Chips de período predefinido
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            StatsFilter.entries.forEach { filter ->
                val selected = !hasCustomStart && filter == selectedFilter
                FilterChip(
                    selected = selected,
                    onClick  = {
                        selectedFilter = filter
                        customStartMs  = 0L
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
                        labelColor             = if (hasCustomStart) TextSecondary.copy(alpha = 0.4f) else TextSecondary,
                    ),
                    border = FilterChipDefaults.filterChipBorder(
                        enabled             = true,
                        selected            = selected,
                        selectedBorderColor = Green.copy(alpha = 0.5f),
                        borderColor         = if (hasCustomStart) BorderColor.copy(alpha = 0.4f) else BorderColor,
                        borderWidth         = 1.dp,
                        selectedBorderWidth = 1.dp,
                    ),
                )
            }
        }

        // Seletor de data de início custom
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            val startLabel = if (hasCustomStart) dateLabelFmt.format(Date(customStartMs)) else "Desde"
            OutlinedButton(
                onClick = { showStartPicker = true },
                modifier = Modifier.height(36.dp),
                shape  = RoundedCornerShape(8.dp),
                colors = ButtonDefaults.outlinedButtonColors(
                    containerColor = if (hasCustomStart) Green.copy(alpha = 0.10f) else SurfaceCard,
                    contentColor   = if (hasCustomStart) Green else TextSecondary,
                ),
                border = androidx.compose.foundation.BorderStroke(
                    1.dp, if (hasCustomStart) Green.copy(alpha = 0.5f) else BorderColor,
                ),
                contentPadding = PaddingValues(horizontal = 12.dp, vertical = 0.dp),
            ) {
                Text("📅 $startLabel", fontSize = 12.sp, fontWeight = if (hasCustomStart) FontWeight.Bold else FontWeight.Normal)
            }

            Text("→ agora", fontSize = 12.sp, color = TextSecondary)

            AnimatedVisibility(visible = hasCustomStart) {
                IconButton(
                    onClick  = { customStartMs = 0L },
                    modifier = Modifier.size(36.dp),
                ) {
                    Icon(Icons.Default.Close, contentDescription = "Limpar data", tint = TextSecondary, modifier = Modifier.size(18.dp))
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

            // ── Aviso: sem checkpoint para o período ──────────────────────────
            AnimatedVisibility(visible = noBaseline) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(SurfaceCard, RoundedCornerShape(12.dp))
                        .border(1.dp, BorderColor, RoundedCornerShape(12.dp))
                        .padding(16.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        "Dados insuficientes para este período.\n" +
                        "O app cria checkpoints a cada estacionamento (P).\n" +
                        "Tente ampliar o período ou aguarde mais uso do veículo.",
                        fontSize = 12.sp,
                        color = TextSecondary,
                        textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                    )
                }
            }

            // ── Seção CONDUÇÃO ────────────────────────────────────────────────
            AnimatedVisibility(visible = !noBaseline && hasDriving) {
                StatSection(
                    title       = "Condução",
                    subtitle    = if (!isFiltered) "lifetime" else selectedFilter.label.lowercase().let { if (hasCustomStart) "desde ${dateLabelFmt.format(Date(customStartMs))}" else it },
                    accentColor = Green,
                ) {
                    // Linha 1 — distância, tempo, velocidade
                    StatRow {
                        StatCell("%.1f km".format(dDist),          "Distância",   Green,       Modifier.weight(1f))
                        StatCell(fmtStatDur(dTime),                 "Tempo",       Blue,        Modifier.weight(1f))
                        StatCell("%.1f km/h".format(avgSpeed),      "Vel. Média",  TextPrimary, Modifier.weight(1f))
                    }
                    // Linha 2 — eficiência elétrica
                    StatRow {
                        StatCell("%.2f kWh/100".format(kwh100km),  "kWh/100km",   Green,       Modifier.weight(1f))
                        StatCell("%.2f kWh".format(dNet),           "Elétrico liq.", Green,     Modifier.weight(1f))
                        StatCell("%.2f kWh".format(dRegen),         "Regenerado",  AuroraTeal,  Modifier.weight(1f))
                    }
                    // Linha 3 — combustível
                    if (dFuel > 0.01f) {
                        StatRow {
                            StatCell("%.3f L".format(dFuel),        "Combustível", AccentOrange, Modifier.weight(1f))
                            StatCell("%.1f km/L".format(kmPerL),    "km/L",        AccentOrange, Modifier.weight(1f))
                            Spacer(Modifier.weight(1f))
                        }
                    }
                    // Linha 4 — custo
                    if (costTotal > 0.01f) {
                        StatRow {
                            StatCell("R$ %.2f".format(costTotal),   "Custo Total", WarnYellow,  Modifier.weight(1f))
                            StatCell("R$ %.3f/km".format(costPerKm),"Custo/km",    WarnYellow,  Modifier.weight(1f))
                            Spacer(Modifier.weight(1f))
                        }
                    }
                }
            }

            // ── Seção RECARGAS ────────────────────────────────────────────────
            AnimatedVisibility(visible = !noBaseline && hasCharging) {
                StatSection(
                    title       = "Recargas",
                    subtitle    = if (!isFiltered) "lifetime" else if (hasCustomStart) "desde ${dateLabelFmt.format(Date(customStartMs))}" else selectedFilter.label.lowercase(),
                    accentColor = AuroraTeal,
                ) {
                    StatRow {
                        StatCell("%.2f kWh".format(dCharge),        "Total Carregado", AuroraTeal, Modifier.weight(1f))
                        StatCell(fmtStatDur(dChargeSec),             "Tempo Total",     Blue,       Modifier.weight(1f))
                        StatCell("%.1f kW".format(avgChargeKw),      "Pot. Média",      AuroraTeal, Modifier.weight(1f))
                    }
                    if (costEnergy > 0.01f) {
                        StatRow {
                            StatCell("R$ %.2f".format(costEnergy),   "Custo Recarga",   WarnYellow, Modifier.weight(1f))
                            Spacer(Modifier.weight(1f))
                            Spacer(Modifier.weight(1f))
                        }
                    }
                }
            }

            // ── Resumo combinado ──────────────────────────────────────────────
            AnimatedVisibility(visible = !noBaseline && hasDriving && hasCharging && costTotal > 0.01f) {
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
                        StatCell("R$ %.2f".format(costFuel),    "Custo Comb.",   WarnYellow, Modifier.weight(1f))
                        StatCell("R$ %.2f".format(costEnergy),  "Custo Energia", WarnYellow, Modifier.weight(1f))
                        StatCell("R$ %.2f".format(costTotal),   "Total",         WarnYellow, Modifier.weight(1f))
                    }
                }
            }

            // ── Sem dados ─────────────────────────────────────────────────────
            AnimatedVisibility(visible = !noBaseline && !hasDriving && !hasCharging) {
                Box(Modifier.fillMaxWidth().padding(top = 32.dp), contentAlignment = Alignment.Center) {
                    Text(
                        if (!isFiltered)
                            "Nenhum dado registrado ainda.\nDirija e recarregue para ver estatísticas."
                        else
                            "Nenhum dado no período selecionado.",
                        fontSize = 13.sp,
                        color = TextSecondary,
                        textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                    )
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
