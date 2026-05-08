package br.com.redesurftank.ecotrip.ui.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import br.com.redesurftank.ecotrip.managers.BlockSample
import br.com.redesurftank.ecotrip.ui.theme.Blue
import br.com.redesurftank.ecotrip.ui.theme.Green
import br.com.redesurftank.ecotrip.ui.theme.PlasmaBlue
import br.com.redesurftank.ecotrip.ui.theme.TextSecondary

@Composable
fun BlockChart(
    blocks: List<BlockSample>,
    modifier: Modifier = Modifier,
) {
    val measurer = rememberTextMeasurer()
    Canvas(modifier = modifier.fillMaxSize()) {
        if (blocks.isEmpty()) {
            drawEmptyState(measurer)
            return@Canvas
        }

        val paddingLeft   = 38.dp.toPx()
        val paddingRight  =  6.dp.toPx()
        val paddingTop    =  8.dp.toPx()
        val paddingBottom = 20.dp.toPx()
        val chartW = size.width  - paddingLeft - paddingRight
        val chartH = size.height - paddingTop  - paddingBottom

        val slotCount = blocks.size  // up to 50 (1 km each)
        val slotW     = chartW / slotCount
        val barGap    = (slotW * 0.10f).coerceAtLeast(0.5.dp.toPx())
        val barBodyW  = slotW - barGap

        val maxEff  = 40f   // eixo Y fixo: máximo 40 kWh/100km; barras acima ficam travadas no topo
        val maxFuel = blocks.maxOf { it.fuelL }.takeIf { it > 0f } ?: 1f

        // Baseline X axis
        drawLine(
            color = Color.White.copy(alpha = 0.07f),
            start = Offset(paddingLeft, paddingTop + chartH),
            end   = Offset(paddingLeft + chartW, paddingTop + chartH),
            strokeWidth = 1.dp.toPx(),
        )

        // Y grid + left labels (kWh/100km scale)
        drawYGrid(paddingLeft, paddingTop, chartW, chartH, maxEff, measurer)

        // Green bars with vertical gradient
        blocks.forEachIndexed { i, block ->
            if (block.netKwhPer100km > 0f) {
                val x    = paddingLeft + i * slotW + barGap / 2f
                val barH = (block.netKwhPer100km.coerceAtMost(maxEff) / maxEff) * chartH
                val y    = paddingTop + chartH - barH
                drawRoundRect(
                    brush        = Brush.verticalGradient(
                        colors = listOf(Green.copy(alpha = 0.9f), Green.copy(alpha = 0.2f)),
                        startY = y,
                        endY   = y + barH,
                    ),
                    topLeft      = Offset(x, y),
                    size         = Size(barBodyW, barH),
                    cornerRadius = CornerRadius(1.dp.toPx()),
                )
            }
        }

        // Blue fuel line — only between non-empty slots
        val fuelPoints = blocks.mapIndexedNotNull { i, block ->
            if (block.fuelL > 0f) {
                val cx = paddingLeft + i * slotW + slotW / 2f
                val cy = paddingTop + chartH - (block.fuelL / maxFuel) * chartH
                Offset(cx, cy)
            } else null
        }

        if (fuelPoints.size >= 2) {
            val path = Path()
            fuelPoints.forEachIndexed { i, pt ->
                if (i == 0) path.moveTo(pt.x, pt.y) else path.lineTo(pt.x, pt.y)
            }
            drawPath(path, PlasmaBlue, style = Stroke(width = 2.dp.toPx(), cap = StrokeCap.Round))
            // Small dots only at every 10th point to avoid clutter with 50 slots
            fuelPoints.forEachIndexed { i, pt ->
                if (i % 10 == 0) drawCircle(PlasmaBlue, radius = 2.5.dp.toPx(), center = pt)
            }
        }

        // X axis labels every 10 slots (= 10 km)
        blocks.forEachIndexed { i, block ->
            if (i % 10 == 0) {
                val cx     = paddingLeft + i * slotW + slotW / 2f
                val label  = "${block.kmStart.toInt()}km"
                val layout = measurer.measure(
                    label,
                    TextStyle(fontSize = 12.sp, color = TextSecondary.copy(alpha = 0.6f))
                )
                drawText(layout, topLeft = Offset(cx - layout.size.width / 2f, paddingTop + chartH + 3.dp.toPx()))
            }
        }
    }
}

private fun DrawScope.drawYGrid(
    paddingLeft: Float,
    paddingTop: Float,
    chartW: Float,
    chartH: Float,
    maxVal: Float,
    measurer: TextMeasurer,
) {
    val steps = 4  // 0 / 10 / 20 / 30 / 40 com maxVal=40
    val dashEffect = PathEffect.dashPathEffect(floatArrayOf(4f, 5f))
    for (i in 0..steps) {
        val y = paddingTop + chartH * (1f - i.toFloat() / steps)
        if (i == 0) {
            // baseline — solid, slightly brighter
            drawLine(
                color       = Color.White.copy(alpha = 0.07f),
                start       = Offset(paddingLeft, y),
                end         = Offset(paddingLeft + chartW, y),
                strokeWidth = 1.dp.toPx(),
            )
        } else {
            drawLine(
                color       = Color.White.copy(alpha = 0.05f),
                start       = Offset(paddingLeft, y),
                end         = Offset(paddingLeft + chartW, y),
                strokeWidth = 1.dp.toPx(),
                pathEffect  = dashEffect,
            )
        }
        val label  = String.format("%.0f", maxVal * i / steps)
        val layout = measurer.measure(
            label,
            TextStyle(fontSize = 11.sp, color = TextSecondary.copy(alpha = 0.6f), fontWeight = FontWeight.Normal)
        )
        drawText(layout, topLeft = Offset(paddingLeft - layout.size.width - 3.dp.toPx(), y - layout.size.height / 2f))
    }
}

private fun DrawScope.drawEmptyState(measurer: TextMeasurer) {
    val layout = measurer.measure(
        "Sem dados",
        TextStyle(fontSize = 12.sp, color = TextSecondary.copy(alpha = 0.6f))
    )
    drawText(layout, topLeft = Offset(
        (size.width  - layout.size.width)  / 2f,
        (size.height - layout.size.height) / 2f,
    ))
}
