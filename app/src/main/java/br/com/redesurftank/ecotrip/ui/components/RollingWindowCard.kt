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
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import br.com.redesurftank.ecotrip.managers.RollingSnapshot
import br.com.redesurftank.ecotrip.ui.theme.*

private val Yellow = Color(0xFFFFD60A)

@Composable
fun RollingWindowCard(
    snapshot: RollingSnapshot,
    onReset: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .background(SurfaceCard, RoundedCornerShape(12.dp))
            .border(1.dp, BorderColor, RoundedCornerShape(12.dp))
            .padding(horizontal = 14.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        // ── Header ────────────────────────────────────────────────────────────
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                "Desde Última Partida",
                fontSize   = 16.sp,
                fontWeight = FontWeight.SemiBold,
                color      = TextSecondary,
            )
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    "%.1f km".format(snapshot.windowKm),
                    fontSize   = 16.sp,
                    fontWeight = FontWeight.SemiBold,
                    color      = TextSecondary,
                )
                TextButton(
                    onClick = onReset,
                    contentPadding = PaddingValues(horizontal = 4.dp, vertical = 0.dp),
                ) {
                    Text("Zerar", fontSize = 15.sp, color = TextSecondary)
                }
            }
        }

        // ── Layout: energia | gauge kWh | gauge combinado | gauge km/L | combustível
        // Três gauges simétricos ao centro; dados preenchem o restante (weight 1f cada).
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            // ── Energia (esquerda) ────────────────────────────────────────────
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                RMetric("⚡ Energia", TextSecondary, FontWeight.SemiBold, 14.sp)
                RMetric("%.2f kWh bruto".format(snapshot.energyKwh), TextPrimary)
                RMetric("%.2f kWh regen".format(snapshot.regenKwh), Green)
                RMetric("%.2f kWh líquido".format(snapshot.netKwh), Yellow)
                if (snapshot.startSocPct > 0f || snapshot.currentSocPct > 0f)
                    RMetric("SOC: %.0f%% → %.0f%%".format(snapshot.startSocPct, snapshot.currentSocPct), TextPrimary)
                RMetric("%.2f kWh/100km".format(snapshot.netKwhPer100km), TextPrimary)
            }

            // ── Gauge kWh/100km ───────────────────────────────────────────────
            Box(modifier = Modifier.weight(1.2f), contentAlignment = Alignment.Center) {
                RollingGauge(
                    value    = snapshot.netKwhPer100km,
                    maxValue = 40f,
                    label    = "kWh/100km",
                    color    = Green,
                    modifier = Modifier.size(146.dp),
                )
            }

            // ── Gauge km/L combinado (centro) ─────────────────────────────────
            Box(modifier = Modifier.weight(1.2f), contentAlignment = Alignment.Center) {
                RollingGauge(
                    value    = snapshot.combinedKmL,
                    maxValue = 60f,
                    label    = "km/L comb.",
                    color    = Cyan,
                    modifier = Modifier.size(146.dp),
                )
            }

            // ── Gauge km/L combustível ────────────────────────────────────────
            Box(modifier = Modifier.weight(1.2f), contentAlignment = Alignment.Center) {
                RollingGauge(
                    value    = snapshot.kmPerL,
                    maxValue = 50f,
                    label    = "km/L",
                    color    = Blue,
                    modifier = Modifier.size(146.dp),
                )
            }

            // ── Combustível (direita) ─────────────────────────────────────────
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                RMetric("⛽ Combustível", TextSecondary, FontWeight.SemiBold, 14.sp)
                RMetric("%.2f km/L".format(snapshot.kmPerL), TextPrimary)
                RMetric("%.2f L gastos".format(snapshot.fuelL), TextPrimary)
                if (snapshot.startTankL > 0f || snapshot.currentTankL > 0f)
                    RMetric("Tanque: %.1fL → %.1fL".format(snapshot.startTankL, snapshot.currentTankL), TextPrimary)
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
            val strokePx    = 12.dp.toPx()
            val inset       = strokePx / 2f
            val arcSize     = Size(size.width - strokePx, size.height - strokePx)
            val arcOffset   = Offset(inset, inset)
            val startAngle  = 135f
            val totalSweep  = 270f
            val fraction    = (value / maxValue).coerceIn(0f, 1f)

            drawArc(
                color       = Color.White.copy(alpha = 0.08f),
                startAngle  = startAngle,
                sweepAngle  = totalSweep,
                useCenter   = false,
                topLeft     = arcOffset,
                size        = arcSize,
                style       = Stroke(width = strokePx, cap = StrokeCap.Round),
            )
            if (fraction > 0f) {
                drawArc(
                    color      = color,
                    startAngle = startAngle,
                    sweepAngle = totalSweep * fraction,
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
                fontSize   = 30.sp,
                fontWeight = FontWeight.Bold,
                color      = TextPrimary,
                maxLines   = 1,
            )
            Text(
                text      = label,
                fontSize  = 17.sp,
                color     = TextSecondary,
                maxLines  = 1,
                textAlign = TextAlign.Center,
            )
        }
    }
}

@Composable
private fun RMetric(
    text: String,
    color: Color,
    fontWeight: FontWeight = FontWeight.Bold,
    fontSize: androidx.compose.ui.unit.TextUnit = 17.sp,
) {
    Text(
        text,
        fontSize   = fontSize,
        fontWeight = fontWeight,
        color      = color,
        maxLines   = 1,
        overflow   = TextOverflow.Ellipsis,
    )
}
