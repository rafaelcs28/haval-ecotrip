package br.com.redesurftank.ecotrip.ui.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import br.com.redesurftank.ecotrip.ui.theme.TextSecondary
import kotlin.math.cos
import kotlin.math.sin

/**
 * Gauge radial principal — 270° de varredura (135°→405° em SVG-coords) com:
 *   - track com "inner shadow" (camada externa escura + track principal)
 *   - 3 camadas de fill: halo (3.2× stroke, 7% alpha) + glow (1.8×, 22%) + arco nítido
 *   - tick marks + tick numbers em volta do arco mostrando a escala
 *   - número grande central com glow na cor de performance
 *
 * Toda a cor de performance (number central, fill 3-layers) vem do parâmetro [color],
 * resolvido pelo chamador via helpers em [PerformanceColors].
 */
@Composable
fun HeroGauge(
    value: Float,
    maxValue: Float,
    label: String,
    color: Color,
    tickValues: List<Int>,
    modifier: Modifier = Modifier,
    diameter: Dp = 260.dp,
    valueFontSize: TextUnit = 56.sp,
    labelFontSize: TextUnit = 13.sp,
) {
    val tickMeasurer = rememberTextMeasurer()
    val tickStyle = remember(color) {
        TextStyle(
            fontSize = 11.sp,
            fontWeight = FontWeight.Bold,
            color = TextSecondary.copy(alpha = 0.70f),
        )
    }

    Box(
        modifier = modifier.size(diameter),
        contentAlignment = Alignment.Center,
    ) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            val strokePx   = 9.dp.toPx()
            val haloPx     = strokePx * 3.2f
            val inset      = haloPx / 2f + 18.dp.toPx()  // extra inset pra tick numbers
            val arcSize    = Size(size.width - inset * 2f, size.height - inset * 2f)
            val arcOffset  = Offset(inset, inset)
            val cx         = size.width / 2f
            val cy         = size.height / 2f
            val radius     = arcSize.width / 2f
            val startAngle = 135f
            val totalSweep = 270f
            val fraction   = (value / maxValue).coerceIn(0f, 1f)

            // ── Inner shadow: camada escura "rebaixada" atrás do track ─────────
            drawArc(
                color      = Color.Black.copy(alpha = 0.45f),
                startAngle = startAngle,
                sweepAngle = totalSweep,
                useCenter  = false,
                topLeft    = arcOffset,
                size       = arcSize,
                style      = Stroke(width = strokePx * 1.55f, cap = StrokeCap.Round),
            )
            // Track principal
            drawArc(
                color      = Color.White.copy(alpha = 0.10f),
                startAngle = startAngle,
                sweepAngle = totalSweep,
                useCenter  = false,
                topLeft    = arcOffset,
                size       = arcSize,
                style      = Stroke(width = strokePx * 1.1f, cap = StrokeCap.Round),
            )

            // ── Tick marks (5 traços curtos nos 25%) ─────────────────────────
            val tickInner = radius - strokePx * 0.45f
            val tickOuter = radius + strokePx * 0.55f
            for (i in 0..4) {
                val angleDeg = startAngle + totalSweep * (i / 4f)
                val rad = Math.toRadians(angleDeg.toDouble())
                val cosA = cos(rad).toFloat()
                val sinA = sin(rad).toFloat()
                drawLine(
                    color = Color.White.copy(alpha = 0.35f),
                    start = Offset(cx + cosA * tickInner, cy + sinA * tickInner),
                    end   = Offset(cx + cosA * tickOuter, cy + sinA * tickOuter),
                    strokeWidth = 2.dp.toPx(),
                    cap = StrokeCap.Round,
                )
            }

            // ── Tick numbers fora do arco ─────────────────────────────────────
            val tickTextRadius = radius + strokePx * 1.4f + 6.dp.toPx()
            for ((i, tickV) in tickValues.withIndex()) {
                val angleDeg = startAngle + totalSweep * (i.toFloat() / (tickValues.size - 1).coerceAtLeast(1).toFloat())
                val rad = Math.toRadians(angleDeg.toDouble())
                val cosA = cos(rad).toFloat()
                val sinA = sin(rad).toFloat()
                val tx = cx + cosA * tickTextRadius
                val ty = cy + sinA * tickTextRadius
                val layout = tickMeasurer.measure(tickV.toString(), tickStyle)
                drawText(
                    textLayoutResult = layout,
                    topLeft = Offset(
                        tx - layout.size.width / 2f,
                        ty - layout.size.height / 2f,
                    ),
                )
            }

            // ── Fill com 3 camadas (cor de performance) ────────────────────────
            if (fraction > 0f) {
                val sweep = totalSweep * fraction
                drawArc(  // halo difuso
                    color      = color.copy(alpha = 0.07f),
                    startAngle = startAngle,
                    sweepAngle = sweep,
                    useCenter  = false,
                    topLeft    = arcOffset,
                    size       = arcSize,
                    style      = Stroke(width = strokePx * 3.2f, cap = StrokeCap.Round),
                )
                drawArc(  // glow médio
                    color      = color.copy(alpha = 0.22f),
                    startAngle = startAngle,
                    sweepAngle = sweep,
                    useCenter  = false,
                    topLeft    = arcOffset,
                    size       = arcSize,
                    style      = Stroke(width = strokePx * 1.8f, cap = StrokeCap.Round),
                )
                drawArc(  // arco nítido
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

        // ── Texto central (valor + label) ──────────────────────────────────────
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Text(
                text       = String.format(java.util.Locale.US, "%.1f", value),
                fontSize   = valueFontSize,
                fontWeight = FontWeight.ExtraBold,
                color      = color,
                maxLines   = 1,
                style      = TextStyle(
                    shadow = Shadow(
                        color      = color.copy(alpha = 0.55f),
                        offset     = Offset.Zero,
                        blurRadius = 18f,
                    ),
                ),
            )
            Text(
                text      = label,
                fontSize  = labelFontSize,
                color     = TextSecondary,
                maxLines  = 1,
                textAlign = TextAlign.Center,
            )
        }
    }
}
