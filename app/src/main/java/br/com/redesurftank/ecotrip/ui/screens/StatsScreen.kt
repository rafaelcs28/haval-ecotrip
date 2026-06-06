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
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import kotlinx.coroutines.delay
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import br.com.redesurftank.ecotrip.managers.TripManager
import br.com.redesurftank.ecotrip.ui.theme.*
import java.util.Calendar
private val PTBR = java.util.Locale("pt", "BR")   // milhares "." e decimal ","

// ── Filtro de período ─────────────────────────────────────────────────────────

private enum class StatsFilter(val label: String) {
    ALL       ("Tudo"),
    TODAY     ("Hoje"),
    DAYS_7    ("7 dias"),
    DAYS_30   ("30 dias"),
    THIS_MONTH("Este mês"),
}

private fun statsStartMs(filter: StatsFilter): Long {
    val cal = Calendar.getInstance()
    return when (filter) {
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

private fun fmtStatDur(sec: Long): String {
    val h = sec / 3600
    val m = (sec % 3600) / 60
    return if (h > 0) "${h}h ${m}min" else "${m}min"
}

// ── Screen ────────────────────────────────────────────────────────────────────

@Composable
fun StatsScreen(
    tripManager: TripManager,
    onBack:      () -> Unit,
) {
    var filter by remember { mutableStateOf(StatsFilter.ALL) }

    // Snapshot reativo — atualiza a cada 5 s para refletir dados chegando via MQTT
    var current by remember { mutableStateOf(tripManager.getLifetimeSnapshot()) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(5_000)
            current = tripManager.getLifetimeSnapshot()
        }
    }

    val (priceGas, priceKwh) = remember { tripManager.getPrices() }

    val periodStartMs = remember(filter) { statsStartMs(filter) }

    // Baseline: recomputa ao mudar o filtro; também recomputa se current mudou
    // (novos checkpoints podem ter sido adicionados durante a sessão)
    val baseline = remember(periodStartMs, current) {
        if (periodStartMs == 0L) null else tripManager.getLifetimeBaselineAt(periodStartMs)
    }
    val noData = filter != StatsFilter.ALL && baseline == null

    // ── Deltas ───────────────────────────────────────────────────────────────
    val dEnergy = (current.energyKwh - (baseline?.energyKwh ?: 0f)).coerceAtLeast(0f)
    val dRegen  = (current.regenKwh  - (baseline?.regenKwh  ?: 0f)).coerceAtLeast(0f)
    val dNet    = (dEnergy - dRegen).coerceAtLeast(0f)
    val dDist   = (current.distKm    - (baseline?.distKm    ?: 0f)).coerceAtLeast(0f)
    val dTime   = (current.timeSec   - (baseline?.timeSec   ?: 0L)).coerceAtLeast(0L)
    val dFuel   = (current.fuelL     - (baseline?.fuelL     ?: 0f)).coerceAtLeast(0f)

    // ── Derivadas ─────────────────────────────────────────────────────────────
    val avgSpeed  = if (dTime > 0) dDist / (dTime / 3600f) else 0f
    val kwh100km  = if (dDist > 0.1f) dNet / dDist * 100f else 0f
    val kmPerL    = if (dFuel > 0.001f) dDist / dFuel else 0f
    val costFuel  = dFuel * priceGas
    val costEnergy= dNet  * priceKwh
    val costTotal = costFuel + costEnergy
    val costPerKm = if (dDist > 0.1f && costTotal > 0f) costTotal / dDist else 0f

    val effColor = when {
        kwh100km <= 0f -> TextSecondary
        kwh100km < 20f -> Green
        kwh100km < 30f -> WarnYellow
        else           -> AccentOrange
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(SurfaceDeep)
            .systemBarsPadding()
            .padding(horizontal = 10.dp, vertical = 4.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        // ── Cabeçalho ─────────────────────────────────────────────────────────
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onClick = onBack) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Voltar", tint = TextSecondary)
            }
            Text("Estatísticas", fontSize = 21.sp, fontWeight = FontWeight.Bold, color = Green)
        }

        // ── Chips de período ──────────────────────────────────────────────────
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            StatsFilter.entries.forEach { f ->
                val selected = f == filter
                FilterChip(
                    selected = selected,
                    onClick  = { filter = f },
                    label = {
                        Text(
                            f.label,
                            fontSize   = 12.sp,
                            fontWeight = if (selected) FontWeight.Bold else FontWeight.Normal,
                        )
                    },
                    colors = FilterChipDefaults.filterChipColors(
                        selectedContainerColor = Green.copy(alpha = 0.18f),
                        selectedLabelColor     = Green,
                        containerColor         = SurfaceCard,
                        labelColor             = TextSecondary,
                    ),
                    border = FilterChipDefaults.filterChipBorder(
                        enabled             = true,
                        selected            = selected,
                        selectedBorderColor = Green.copy(alpha = 0.5f),
                        borderColor         = BorderColor,
                        borderWidth         = 1.dp,
                        selectedBorderWidth = 1.dp,
                    ),
                )
            }
        }

        // ── Aviso sem dados ────────────────────────────────────────────────────
        AnimatedVisibility(visible = noData) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(SurfaceCard, RoundedCornerShape(12.dp))
                    .border(1.dp, WarnYellow.copy(alpha = 0.4f), RoundedCornerShape(12.dp))
                    .padding(14.dp),
            ) {
                Text(
                    "Dados insuficientes para este período.\nOs checkpoints são criados a cada vez que o carro é ligado ou desligado.",
                    fontSize = 13.sp,
                    color    = WarnYellow,
                )
            }
        }

        // ── Métricas ──────────────────────────────────────────────────────────
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            // Seção: Deslocamento
            StatsSectionCard(title = "DESLOCAMENTO") {
                StatsRow {
                    StatsCell("Distância",  String.format(PTBR, "%,.1f km",dDist),                                 AccentBlue)
                    StatsCell("Tempo",      if (dTime > 0) fmtStatDur(dTime) else "—",               TextPrimary)
                    StatsCell("Vel. Média", if (avgSpeed > 0f) "%.1f km/h".format(avgSpeed) else "—", TextPrimary)
                }
            }

            // Seção: Eficiência
            StatsSectionCard(title = "EFICIÊNCIA") {
                StatsRow {
                    StatsCell("kWh/100km",    if (kwh100km > 0f) "%.1f".format(kwh100km) else "—",  effColor)
                    StatsCell("km/L",         if (kmPerL   > 0f) "%.1f".format(kmPerL)   else "—",  Green)
                    StatsCell("kWh líquido",  String.format(PTBR, "%,.2f kWh",dNet),                              Green)
                }
                StatsRow {
                    StatsCell("Energia bruta",String.format(PTBR, "%,.2f kWh",dEnergy),                            TextSecondary)
                    StatsCell("Regenerada",   String.format(PTBR, "%,.2f kWh",dRegen),                             AuroraTeal)
                    StatsCell("Combustível",  if (dFuel > 0.001f) "%.2f L".format(dFuel) else "—",  AccentOrange)
                }
            }

            // Seção: Custo (só se preços configurados)
            if (costTotal > 0.01f) {
                StatsSectionCard(title = "CUSTO ESTIMADO") {
                    StatsRow {
                        StatsCell("Total",       String.format(PTBR, "R$ %,.2f",costTotal),  WarnYellow)
                        StatsCell("Combustível", String.format(PTBR, "R$ %,.2f",costFuel),   WarnYellow)
                        StatsCell("Energia",     String.format(PTBR, "R$ %,.2f",costEnergy), WarnYellow)
                    }
                    if (costPerKm > 0f) {
                        StatsRow {
                            StatsCell("R$/km", "%.3f".format(costPerKm), WarnYellow)
                            Spacer(Modifier.weight(1f))
                            Spacer(Modifier.weight(1f))
                        }
                    }
                }
            }

            Spacer(Modifier.height(8.dp))
        }
    }
}

// ── Componentes internos ──────────────────────────────────────────────────────

@Composable
private fun StatsSectionCard(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(SurfaceCard, RoundedCornerShape(12.dp))
            .border(1.dp, BorderColor, RoundedCornerShape(12.dp))
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(
            title,
            fontSize      = 10.sp,
            color         = TextSecondary,
            fontWeight    = FontWeight.SemiBold,
            letterSpacing = 1.sp,
        )
        HorizontalDivider(color = Separator, thickness = 0.5.dp)
        content()
    }
}

@Composable
private fun StatsRow(content: @Composable RowScope.() -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        content = content,
    )
}

@Composable
private fun RowScope.StatsCell(label: String, value: String, color: Color = TextPrimary) {
    Column(modifier = Modifier.weight(1f)) {
        Text(value, fontSize = 16.sp, fontWeight = FontWeight.Bold, color = color)
        Text(label, fontSize = 11.sp, color = TextSecondary)
    }
}
