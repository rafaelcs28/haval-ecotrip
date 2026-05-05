package br.com.redesurftank.ecotrip.ui.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import br.com.redesurftank.ecotrip.ui.theme.*

@Composable
fun CircularGauge(
    value: Float,
    maxValue: Float = 20f,
    unit: String = "kWh/100km",
    distKm: Float = 0f,
    colorFn: (Float) -> Color = { v -> when {
        v <= 17f -> Green
        v <= 20f -> Color(0xFFFFD60A)
        v <= 25f -> AccentOrange
        else     -> Color(0xFFFF4444)
    }},
    modifier: Modifier = Modifier,
) {
    val fraction  = (value / maxValue).coerceIn(0f, 1f)
    val arcColor  = colorFn(value)

    Box(modifier = modifier, contentAlignment = Alignment.Center) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            val strokeW  = 11.dp.toPx()
            val padding  = strokeW / 2f + 6.dp.toPx()
            val diameter = minOf(size.width, size.height) - 2f * padding
            val topLeft  = Offset((size.width - diameter) / 2f, (size.height - diameter) / 2f)
            val arcSize  = Size(diameter, diameter)

            // Background track
            drawArc(
                color      = Color.White.copy(alpha = 0.08f),
                startAngle = 150f,
                sweepAngle = 240f,
                useCenter  = false,
                topLeft    = topLeft,
                size       = arcSize,
                style      = Stroke(width = strokeW, cap = StrokeCap.Round),
            )

            // Filled arc
            if (fraction > 0.01f) {
                drawArc(
                    color      = arcColor,
                    startAngle = 150f,
                    sweepAngle = 240f * fraction,
                    useCenter  = false,
                    topLeft    = topLeft,
                    size       = arcSize,
                    style      = Stroke(width = strokeW, cap = StrokeCap.Round),
                )
            }
        }

        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier.padding(horizontal = 12.dp),
        ) {
            Text(
                if (value > 0f) "%.1f".format(value) else "--",
                fontSize   = 24.sp,
                fontWeight = FontWeight.Bold,
                color      = TextPrimary,
                maxLines   = 1,
            )
            Text(unit, fontSize = 10.sp, color = TextSecondary, maxLines = 1)
            Spacer(Modifier.height(3.dp))
            Text(
                if (distKm > 0f) "%.1f km".format(distKm) else "0.0 km",
                fontSize   = 13.sp,
                fontWeight = FontWeight.Medium,
                color      = Cyan,
                maxLines   = 1,
            )
        }
    }
}
