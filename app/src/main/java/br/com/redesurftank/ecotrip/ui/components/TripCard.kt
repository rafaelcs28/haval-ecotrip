package br.com.redesurftank.ecotrip.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import br.com.redesurftank.ecotrip.managers.TripSnapshot
import br.com.redesurftank.ecotrip.ui.theme.*

private val Yellow = Color(0xFFFFD60A)

@Composable
fun TripCard(
    label: String,
    snapshot: TripSnapshot,
    onReset: (name: String) -> Unit,
    modifier: Modifier = Modifier,
) {
    var confirmReset by remember { mutableStateOf(false) }
    var tripName     by remember { mutableStateOf("") }
    val scrollState  = rememberScrollState()

    Column(
        modifier = modifier
            .background(SurfaceCard, RoundedCornerShape(12.dp))
            .border(1.dp, BorderColor, RoundedCornerShape(12.dp))
            .padding(16.dp)
            .fillMaxHeight()
            .verticalScroll(scrollState),
    ) {
        // ── Header ────────────────────────────────────────────────────────────
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(label, fontSize = 19.sp, fontWeight = FontWeight.SemiBold, color = TextSecondary)
            Text(
                "%.1f km · %s".format(snapshot.distKm, formatTime(snapshot.timeSec)),
                fontSize = 15.sp,
                color = TextSecondary,
            )
        }
        Spacer(Modifier.height(6.dp))
        HorizontalDivider(color = Separator, thickness = 0.5.dp)
        Spacer(Modifier.height(6.dp))

        // ── Two columns ───────────────────────────────────────────────────────
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            // ── Energia ───────────────────────────────────────────────────────
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                TMetric("⚡ Energia", TextSecondary, FontWeight.SemiBold, 14.sp)
                TMetric("%.2f kWh bruto".format(snapshot.energyKwh), TextPrimary)
                TMetric("%.2f kWh regen".format(snapshot.regenKwh), Green)
                TMetric("%.2f kWh líquido".format(snapshot.netKwh), Yellow)
                if (snapshot.startSocPct > 0f || snapshot.currentSocPct > 0f)
                    TMetric("SOC: %.0f%% → %.0f%%".format(snapshot.startSocPct, snapshot.currentSocPct), TextPrimary)
                TMetric("%.2f kWh/100km".format(snapshot.kwhPer100km), TextPrimary)
            }

            // ── Combustível ───────────────────────────────────────────────────
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                TMetric("⛽ Combustível", TextSecondary, FontWeight.SemiBold, 14.sp)
                TMetric("%.2f km/L".format(snapshot.kmPerL), TextPrimary)
                TMetric("%.2f L gastos".format(snapshot.fuelL), TextPrimary)
                if (snapshot.startTankL > 0f || snapshot.currentTankL > 0f)
                    TMetric("Tanque: %.1fL → %.1fL".format(snapshot.startTankL, snapshot.currentTankL), TextPrimary)
                if (snapshot.combinedKmL > 0f)
                    TMetric("%.2f km/L comb.".format(snapshot.combinedKmL), Cyan)
            }
        }

        Spacer(Modifier.height(8.dp))

        // ── Chart ─────────────────────────────────────────────────────────────
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(132.dp)
                .background(SurfaceDeep, RoundedCornerShape(8.dp))
                .padding(4.dp),
        ) {
            if (snapshot.blocks.isNotEmpty()) {
                BlockChart(blocks = snapshot.blocks)
            }
        }

        Spacer(Modifier.height(4.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            LegendDot(Green, "kWh/100km líq.")
            LegendDot(Blue,  "Combustível (L)")
        }

        Spacer(Modifier.height(4.dp))
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterEnd) {
            TextButton(onClick = { tripName = ""; confirmReset = true }) {
                Text("Zerar", fontSize = 15.sp, color = TextSecondary)
            }
        }
    }

    if (confirmReset) {
        AlertDialog(
            onDismissRequest = { confirmReset = false },
            containerColor = SurfaceCard,
            title = { Text("Zerar $label", fontWeight = FontWeight.Bold, color = TextPrimary) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("Dê um nome para esta viagem (opcional):", fontSize = 14.sp, color = TextSecondary)
                    OutlinedTextField(
                        value = tripName,
                        onValueChange = { tripName = it },
                        placeholder = { Text("Ex: Goiânia → Catalão", fontSize = 14.sp, color = TextSecondary) },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                        colors = OutlinedTextFieldDefaults.colors(
                            focusedTextColor     = TextPrimary,
                            unfocusedTextColor   = TextPrimary,
                            focusedBorderColor   = Green,
                            unfocusedBorderColor = BorderColor,
                            cursorColor          = Green,
                        ),
                    )
                }
            },
            confirmButton = {
                TextButton(onClick = { confirmReset = false; onReset(tripName) }) {
                    Text("Zerar", color = Green, fontWeight = FontWeight.SemiBold)
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmReset = false }) { Text("Cancelar", color = TextSecondary) }
            },
        )
    }
}

@Composable
private fun TMetric(
    text: String,
    color: Color,
    fontWeight: FontWeight = FontWeight.Bold,
    fontSize: TextUnit = 17.sp,
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

@Composable
private fun LegendDot(color: Color, label: String) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Box(Modifier.size(8.dp).background(color, RoundedCornerShape(2.dp)))
        Text(label, fontSize = 13.sp, color = TextSecondary)
    }
}

private fun formatTime(sec: Long): String {
    val h = sec / 3600
    val m = (sec % 3600) / 60
    val s = sec % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%d:%02d".format(m, s)
}
