package br.com.redesurftank.ecotrip.ui.components

import androidx.compose.foundation.border
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import br.com.redesurftank.ecotrip.ui.theme.*

data class RealtimeData(
    val instantFuelKmL: Float,
    val instantFuelLh: Float,
    val isMoving: Boolean,
    val instantEnergyKw: Float,
    val batterySoc: Float,
)

@Composable
fun RealtimeSection(data: RealtimeData, modifier: Modifier = Modifier) {
    Row(
        modifier = modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(7.dp),
    ) {
        val fuelLabel = if (data.isMoving) "km/L" else "L/h"
        val fuelValue = if (data.isMoving) data.instantFuelKmL else data.instantFuelLh
        RealtimeCard(
            icon   = "⛽",
            label  = "Combustível",
            value  = "%.1f".format(fuelValue),
            unit   = fuelLabel,
            accent = MoltenOrange,
            modifier = Modifier.weight(1f),
        )
        RealtimeCard(
            icon   = "⚡",
            label  = "Energia",
            value  = "%.1f".format(data.instantEnergyKw),
            unit   = "kW",
            accent = AuroraTeal,
            modifier = Modifier.weight(1f),
        )
        RealtimeCard(
            icon   = "🔋",
            label  = "Bateria",
            value  = "%.0f".format(data.batterySoc),
            unit   = "%",
            accent = PlasmaBlue,
            modifier = Modifier.weight(1f),
        )
    }
}

@Composable
private fun RealtimeCard(
    icon: String,
    label: String,
    value: String,
    unit: String,
    accent: Color,
    modifier: Modifier = Modifier,
) {
    val shape = RoundedCornerShape(14.dp)
    val brush = Brush.linearGradient(
        colors = listOf(accent.copy(alpha = 0.10f), GlassCard.copy(alpha = 0.97f)),
        start  = Offset(0f, 0f),
        end    = Offset(Float.POSITIVE_INFINITY, Float.POSITIVE_INFINITY),
    )

    Row(
        modifier = modifier
            .height(72.dp)
            .background(brush, shape)
            .border(1.dp, accent.copy(alpha = 0.22f), shape)
            .clip(shape),
    ) {
        // Faixa lateral esquerda 3dp
        Box(
            modifier = Modifier
                .width(3.dp)
                .fillMaxHeight()
                .background(
                    Brush.verticalGradient(listOf(accent, accent.copy(alpha = 0.4f))),
                    RoundedCornerShape(topStart = 14.dp, bottomStart = 14.dp),
                )
        )
        // Ícone + conteúdo
        Row(
            modifier = Modifier
                .fillMaxSize()
                .padding(horizontal = 18.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text(
                text     = icon,
                fontSize = 20.sp,
                modifier = Modifier.alpha(0.75f),
            )
            Column {
                Text(
                    text          = label.uppercase(),
                    fontSize      = 9.sp,
                    fontWeight    = FontWeight.Bold,
                    letterSpacing = 1.5.sp,
                    color         = TextSecondary,
                )
                Row(
                    verticalAlignment = Alignment.Bottom,
                    horizontalArrangement = Arrangement.spacedBy(5.dp),
                ) {
                    Text(
                        text       = value,
                        fontSize   = 32.sp,
                        fontWeight = FontWeight.ExtraBold,
                        color      = accent,
                        style      = TextStyle(
                            shadow = Shadow(
                                color      = accent.copy(alpha = 0.5f),
                                offset     = Offset.Zero,
                                blurRadius = 20f,
                            )
                        ),
                    )
                    Text(
                        text     = unit,
                        fontSize = 12.sp,
                        color    = TextSecondary,
                        modifier = Modifier.padding(bottom = 4.dp),
                    )
                }
            }
        }
    }
}
