package br.com.redesurftank.ecotrip.ui.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import br.com.redesurftank.ecotrip.managers.RollingSnapshot
import br.com.redesurftank.ecotrip.ui.theme.*

@Composable
fun RollingWindowCard(
    snapshot: RollingSnapshot,
    onReset: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val glowBrush = Brush.horizontalGradient(
        listOf(
            Color.Transparent,
            NeonLime.copy(alpha = 0.35f),
            AuroraTeal.copy(alpha = 0.35f),
            Color.Transparent,
        )
    )

    Column(
        modifier = modifier
            .background(GlassCard, RoundedCornerShape(16.dp))
            .border(1.dp, BorderColor, RoundedCornerShape(16.dp))
            .drawBehind {
                // linha de brilho no topo
                drawRect(
                    brush   = glowBrush,
                    topLeft = Offset(0f, 0f),
                    size    = Size(size.width, 1.dp.toPx()),
                )
            }
            .padding(horizontal = 16.dp, vertical = 11.dp),
        verticalArrangement = Arrangement.spacedBy(9.dp),
    ) {
        // ── Header ────────────────────────────────────────────────────────────
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                "DESDE ÚLTIMA PARTIDA",
                fontSize      = 10.sp,
                fontWeight    = FontWeight.Bold,
                letterSpacing = 1.8.sp,
                color         = TextSecondary,
            )
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Text(
                    "%.1f km".format(snapshot.windowKm),
                    fontSize   = 14.sp,
                    fontWeight = FontWeight.ExtraBold,
                    color      = AuroraTeal,
                    style      = TextStyle(
                        shadow = Shadow(
                            color      = AuroraTeal.copy(alpha = 0.4f),
                            offset     = Offset.Zero,
                            blurRadius = 12f,
                        )
                    ),
                )
                androidx.compose.material3.OutlinedButton(
                    onClick        = onReset,
                    contentPadding = PaddingValues(horizontal = 9.dp, vertical = 2.dp),
                    border         = androidx.compose.foundation.BorderStroke(
                        1.dp,
                        Color.White.copy(alpha = 0.07f),
                    ),
                    shape  = RoundedCornerShape(6.dp),
                    colors = androidx.compose.material3.ButtonDefaults.outlinedButtonColors(
                        contentColor = TextSecondary,
                    ),
                ) {
                    Text("Zerar", fontSize = 10.sp, fontWeight = FontWeight.SemiBold, color = TextSecondary)
                }
            }
        }

        // ── Layout: energia | gauge kWh | gauge combinado | gauge km/L | combustível
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            // ── Energia (esquerda) ────────────────────────────────────────────
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(3.dp),
            ) {
                RMetricSection("⚡ Energia")
                RMetric("Bruto",       "%.2f kWh".format(snapshot.energyKwh),       TextPrimary)
                RMetric("Regen",       "%.2f kWh".format(snapshot.regenKwh),         NeonLime)
                RMetric("Líquido",     "%.2f kWh".format(snapshot.netKwh),           WarnYellow)
                if (snapshot.startSocPct > 0f || snapshot.currentSocPct > 0f)
                    RMetric("SOC", "%.0f%% → %.0f%%".format(snapshot.startSocPct, snapshot.currentSocPct), TextPrimary)
                RMetric("Ef. elétrica", "%.2f kWh/100km".format(snapshot.netKwhPer100km), AuroraTeal)
            }

            // ── Gauge kWh/100km ───────────────────────────────────────────────
            Box(modifier = Modifier.weight(1.2f), contentAlignment = Alignment.Center) {
                RollingGauge(
                    value    = snapshot.netKwhPer100km,
                    maxValue = 40f,
                    label    = "kWh/100km",
                    color    = NeonLime,
                    modifier = Modifier.size(126.dp),
                )
            }

            // ── Gauge km/L combinado (centro) ─────────────────────────────────
            Box(modifier = Modifier.weight(1.2f), contentAlignment = Alignment.Center) {
                RollingGauge(
                    value    = snapshot.combinedKmL,
                    maxValue = 60f,
                    label    = "km/L comb.",
                    color    = AuroraTeal,
                    modifier = Modifier.size(142.dp),
                )
            }

            // ── Gauge km/L combustível ────────────────────────────────────────
            Box(modifier = Modifier.weight(1.2f), contentAlignment = Alignment.Center) {
                RollingGauge(
                    value    = snapshot.kmPerL,
                    maxValue = 50f,
                    label    = "km/L",
                    color    = PlasmaBlue,
                    modifier = Modifier.size(126.dp),
                )
            }

            // ── Combustível (direita) ─────────────────────────────────────────
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(3.dp),
            ) {
                RMetricSection("⛽ Combustível")
                RMetric("km/L",   "%.2f".format(snapshot.kmPerL),   MoltenOrange)
                RMetric("Gastos", "%.2f L".format(snapshot.fuelL),   TextPrimary)
                if (snapshot.startTankL > 0f || snapshot.currentTankL > 0f)
                    RMetric("Tanque", "%.1fL → %.1fL".format(snapshot.startTankL, snapshot.currentTankL), TextPrimary)
            }
        }
    }
}

@Composable
private fun RollingGauge(
    value: Float,
    maxValue: Float,
    label: String,
    color: Color,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier,
        contentAlignment = Alignment.Center,
    ) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            val strokePx   = 7.dp.toPx()
            val inset      = strokePx * 3.2f / 2f   // largest halo determines the inset
            val arcSize    = Size(size.width - inset * 2f, size.height - inset * 2f)
            val arcOffset  = Offset(inset, inset)
            val startAngle = 135f
            val totalSweep = 270f
            val fraction   = (value / maxValue).coerceIn(0f, 1f)

            // Track
            drawArc(
                color      = Color.White.copy(alpha = 0.08f),
                startAngle = startAngle,
                sweepAngle = totalSweep,
                useCenter  = false,
                topLeft    = arcOffset,
                size       = arcSize,
                style      = Stroke(width = strokePx, cap = StrokeCap.Round),
            )

            if (fraction > 0f) {
                val sweep = totalSweep * fraction
                // Camada 1: halo difuso
                drawArc(
                    color      = color.copy(alpha = 0.07f),
                    startAngle = startAngle,
                    sweepAngle = sweep,
                    useCenter  = false,
                    topLeft    = arcOffset,
                    size       = arcSize,
                    style      = Stroke(width = strokePx * 3.2f, cap = StrokeCap.Round),
                )
                // Camada 2: glow médio
                drawArc(
                    color      = color.copy(alpha = 0.20f),
                    startAngle = startAngle,
                    sweepAngle = sweep,
                    useCenter  = false,
                    topLeft    = arcOffset,
                    size       = arcSize,
                    style      = Stroke(width = strokePx * 1.8f, cap = StrokeCap.Round),
                )
                // Camada 3: arco nítido
                drawArc(
                    color      = color,
                    startAngle = startAngle,
                    sweepAngle = sweep,
                    useCenter  = false,
                    topLeft    = arcOffset,
                    size       = arcSize,
                    style      = Stroke(width = strokePx, cap = StrokeCap.Round),
                )
            }
        }

        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Text(
                text       = String.format(java.util.Locale.US, "%.1f", value),
                fontSize   = 24.sp,
                fontWeight = FontWeight.ExtraBold,
                color      = color,
                maxLines   = 1,
                style      = TextStyle(
                    shadow = Shadow(
                        color      = color.copy(alpha = 0.5f),
                        offset     = Offset.Zero,
                        blurRadius = 16f,
                    )
                ),
            )
            Text(
                text      = label,
                fontSize  = 10.sp,
                color     = TextSecondary,
                maxLines  = 1,
                textAlign = TextAlign.Center,
            )
        }
    }
}

@Composable
private fun RMetricSection(title: String) {
    Text(
        text          = title.uppercase(),
        fontSize      = 9.sp,
        fontWeight    = FontWeight.Bold,
        letterSpacing = 1.4.sp,
        color         = TextSecondary.copy(alpha = 0.6f),
        modifier      = Modifier.padding(bottom = 2.dp),
    )
}

@Composable
private fun RMetric(
    label: String,
    value: String,
    valueColor: Color,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text     = label,
            fontSize = 11.sp,
            color    = TextSecondary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        Text(
            text       = value,
            fontSize   = 12.sp,
            fontWeight = FontWeight.Bold,
            color      = valueColor,
            maxLines   = 1,
            overflow   = TextOverflow.Ellipsis,
        )
    }
}
