package br.com.redesurftank.ecotrip.ui.components

import androidx.compose.foundation.border
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
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
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        val fuelLabel = if (data.isMoving) "km/L" else "L/h"
        val fuelValue = if (data.isMoving) data.instantFuelKmL else data.instantFuelLh
        RealtimeCard(
            label = "Combustível",
            value = "%.1f".format(fuelValue),
            unit = fuelLabel,
            accent = AccentOrange,
            modifier = Modifier.weight(1f),
        )
        RealtimeCard(
            label = "Energia",
            value = "%.1f".format(data.instantEnergyKw),
            unit = "kW",
            accent = Green,
            modifier = Modifier.weight(1f),
        )
        RealtimeCard(
            label = "Bateria",
            value = "%.0f".format(data.batterySoc),
            unit = "%",
            accent = AccentBlue,
            modifier = Modifier.weight(1f),
        )
    }
}

@Composable
private fun RealtimeCard(
    label: String,
    value: String,
    unit: String,
    accent: Color,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .background(SurfaceCard, RoundedCornerShape(12.dp))
            .border(1.dp, BorderColor, RoundedCornerShape(12.dp))
            .padding(horizontal = 12.dp, vertical = 10.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(label, fontSize = 13.sp, color = TextSecondary)
        Spacer(Modifier.height(4.dp))
        Row(verticalAlignment = Alignment.Bottom) {
            Text(value, fontSize = 28.sp, fontWeight = FontWeight.Bold, color = accent)
            Spacer(Modifier.width(4.dp))
            Text(unit, fontSize = 14.sp, color = TextSecondary, modifier = Modifier.padding(bottom = 4.dp))
        }
    }
}
