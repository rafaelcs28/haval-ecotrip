package br.com.redesurftank.ecotrip.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import br.com.redesurftank.ecotrip.ui.theme.GlassCard
import br.com.redesurftank.ecotrip.ui.theme.TextPrimary
import br.com.redesurftank.ecotrip.ui.theme.TextSecondary
import br.com.redesurftank.ecotrip.ui.theme.VoidBlack

/**
 * Medidor linear estilo "fuel gauge" automotivo.
 *
 *   ┌─ [icon] LABEL ········ máx N ─┐
 *   │  34.2 km/L                    │
 *   │  ━━━━━━●─────────────         │
 *   │  0  25  50  75  100           │
 *   └───────────────────────────────┘
 *
 * - [categoryIconColor]: cor fixa identifica a categoria (teal pra km/L eq, orange pra km/L)
 * - [perfColor]: cor de performance vinda do threshold helper — pinta valor, fill e dot
 */
@Composable
fun LinearMeter(
    value: Float,
    maxValue: Float,
    label: String,
    unitLabel: String,
    icon: Painter,
    categoryIconColor: Color,
    perfColor: Color,
    tickValues: List<Int>,
    modifier: Modifier = Modifier,
) {
    val fraction = (value / maxValue).coerceIn(0f, 1f)
    val perfGradTo = lighten(perfColor, 0.45f)

    Column(
        modifier = modifier
            .background(Color(0xFF0C1019).copy(alpha = 0.55f), RoundedCornerShape(14.dp))
            .border(1.dp, Color.White.copy(alpha = 0.06f), RoundedCornerShape(14.dp))
            .padding(horizontal = 20.dp, vertical = 14.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        // Header: icon + label, max à direita
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(5.dp),
            ) {
                Icon(
                    painter = icon,
                    contentDescription = null,
                    tint = categoryIconColor.copy(alpha = 0.85f),
                    modifier = Modifier.size(13.dp),
                )
                Text(
                    text = label.uppercase(),
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Bold,
                    letterSpacing = 1.6.sp,
                    color = TextSecondary,
                )
            }
            Text(
                text = "máx ${maxValue.toInt()}",
                fontSize = 10.sp,
                color = TextSecondary.copy(alpha = 0.55f),
                fontWeight = FontWeight.Medium,
            )
        }

        // Valor grande + unidade
        Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(
                text = String.format(java.util.Locale.US, "%.1f", value),
                fontSize = 48.sp,
                fontWeight = FontWeight.ExtraBold,
                color = perfColor,
                letterSpacing = (-1.8).sp,
                style = TextStyle(
                    shadow = Shadow(
                        color = perfColor.copy(alpha = 0.45f),
                        offset = Offset.Zero,
                        blurRadius = 14f,
                    ),
                ),
                maxLines = 1,
            )
            Text(
                text = unitLabel,
                fontSize = 17.sp,
                fontWeight = FontWeight.SemiBold,
                color = TextSecondary,
                modifier = Modifier.padding(bottom = 5.dp),
                maxLines = 1,
            )
        }

        // Bar com inner shadow + fill + dot indicator
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(9.dp)
                .background(Color.White.copy(alpha = 0.04f), RoundedCornerShape(5.dp))
                .border(0.5.dp, Color.Black.copy(alpha = 0.4f), RoundedCornerShape(5.dp)),
        ) {
            // Fill com gradient
            Box(
                modifier = Modifier
                    .fillMaxWidth(fraction)
                    .fillMaxHeight()
                    .background(
                        brush = Brush.horizontalGradient(listOf(perfColor, perfGradTo)),
                        shape = RoundedCornerShape(4.dp),
                    ),
            )
            // Dot indicator na ponta direita do fill
            if (fraction > 0.01f) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth(fraction)
                        .fillMaxHeight()
                        .wrapContentSize(Alignment.CenterEnd),
                ) {
                    Box(
                        modifier = Modifier
                            .size(12.dp)
                            .offset(x = 4.dp)
                            .background(perfColor, CircleShape)
                            .border(2.dp, VoidBlack, CircleShape),
                    )
                }
            }
        }

        // Ticks (escala) abaixo da bar
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            for (t in tickValues) {
                Text(
                    text = t.toString(),
                    fontSize = 9.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = TextSecondary.copy(alpha = 0.45f),
                    letterSpacing = 0.3.sp,
                )
            }
        }
    }
}

/** Clareia uma cor misturando com branco (factor 0..1). */
private fun lighten(c: Color, factor: Float): Color {
    val f = factor.coerceIn(0f, 1f)
    return Color(
        red = c.red + (1f - c.red) * f,
        green = c.green + (1f - c.green) * f,
        blue = c.blue + (1f - c.blue) * f,
        alpha = c.alpha,
    )
}
