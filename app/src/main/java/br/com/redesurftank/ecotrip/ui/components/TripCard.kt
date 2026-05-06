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
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import br.com.redesurftank.ecotrip.managers.TripSnapshot
import br.com.redesurftank.ecotrip.ui.theme.*

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

    val accentColor = if (label.contains("A", ignoreCase = true)) NeonLime else AuroraTeal
    val shape = RoundedCornerShape(16.dp)
    val brush = Brush.linearGradient(
        colors = listOf(accentColor.copy(alpha = 0.07f), GlassCard.copy(alpha = 0.98f)),
        start  = Offset(0f, 0f),
        end    = Offset(Float.POSITIVE_INFINITY, Float.POSITIVE_INFINITY * 0.5f),
    )
    val glowBrush = Brush.horizontalGradient(
        listOf(accentColor.copy(alpha = 0.6f), accentColor.copy(alpha = 0.1f), Color.Transparent)
    )

    Column(
        modifier = modifier
            .background(brush, shape)
            .border(1.dp, accentColor.copy(alpha = 0.14f), shape)
            .drawBehind {
                // linha de brilho no topo
                drawRect(
                    brush   = glowBrush,
                    topLeft = Offset(0f, 0f),
                    size    = Size(size.width, 1.dp.toPx()),
                )
            }
            .padding(horizontal = 14.dp, vertical = 11.dp)
            .fillMaxHeight()
            .verticalScroll(scrollState),
    ) {
        // ── Header ────────────────────────────────────────────────────────────
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text       = label,
                fontSize   = 14.sp,
                fontWeight = FontWeight.ExtraBold,
                color      = accentColor,
                style      = TextStyle(
                    shadow = Shadow(
                        color      = accentColor.copy(alpha = 0.4f),
                        offset     = Offset.Zero,
                        blurRadius = 14f,
                    )
                ),
            )
            Text(
                text     = "%.1f km · %s".format(snapshot.distKm, formatTime(snapshot.timeSec)),
                fontSize = 11.sp,
                color    = TextSecondary,
            )
        }

        Spacer(Modifier.height(6.dp))

        // Gradient divider
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(1.dp)
                .background(
                    Brush.horizontalGradient(
                        listOf(TextSecondary.copy(alpha = 0.15f), Color.Transparent)
                    )
                )
        )

        Spacer(Modifier.height(6.dp))

        // ── Two columns ───────────────────────────────────────────────────────
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            // ── Energia ───────────────────────────────────────────────────────
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                TColTitle("⚡ Energia")
                TMetric("Bruto",       "%.2f kWh".format(snapshot.energyKwh),  TextPrimary)
                TMetric("Regen",       "%.2f kWh".format(snapshot.regenKwh),    NeonLime)
                TMetric("Líquido",     "%.2f kWh".format(snapshot.netKwh),      WarnYellow)
                if (snapshot.startSocPct > 0f || snapshot.currentSocPct > 0f)
                    TMetric("SOC", "%.0f%% → %.0f%%".format(snapshot.startSocPct, snapshot.currentSocPct), TextPrimary)
                TMetric("Ef. elétrica", "%.2f kWh/100km".format(snapshot.kwhPer100km), AuroraTeal)
            }

            // ── Combustível ───────────────────────────────────────────────────
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                TColTitle("⛽ Combustível")
                TMetric("km/L",   "%.2f".format(snapshot.kmPerL),             MoltenOrange)
                TMetric("Gastos", "%.2f L".format(snapshot.fuelL),             TextPrimary)
                if (snapshot.startTankL > 0f || snapshot.currentTankL > 0f)
                    TMetric("Tanque", "%.1fL → %.1fL".format(snapshot.startTankL, snapshot.currentTankL), TextPrimary)
                if (snapshot.combinedKmL > 0f)
                    TMetric("km/L comb.", "%.2f".format(snapshot.combinedKmL), AuroraTeal)
            }
        }

        Spacer(Modifier.height(8.dp))

        // ── Chart ─────────────────────────────────────────────────────────────
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(132.dp)
                .background(
                    Brush.verticalGradient(
                        listOf(GlassCard.copy(alpha = 0.6f), VoidBlack)
                    ),
                    RoundedCornerShape(8.dp),
                )
                .padding(4.dp),
        ) {
            if (snapshot.blocks.isNotEmpty()) {
                BlockChart(blocks = snapshot.blocks)
            }
        }

        Spacer(Modifier.height(4.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            LegendDot(accentColor, "kWh/100km líq.")
            LegendDot(PlasmaBlue, "Combustível (L)")
        }

        Spacer(Modifier.height(4.dp))
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterEnd) {
            androidx.compose.material3.OutlinedButton(
                onClick        = { tripName = ""; confirmReset = true },
                contentPadding = PaddingValues(horizontal = 10.dp, vertical = 2.dp),
                border         = androidx.compose.foundation.BorderStroke(
                    1.dp,
                    Color.White.copy(alpha = 0.07f),
                ),
                shape  = RoundedCornerShape(6.dp),
                colors = androidx.compose.material3.ButtonDefaults.outlinedButtonColors(
                    contentColor = TextSecondary,
                ),
            ) {
                Text("Zerar", fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = TextSecondary)
            }
        }
    }

    if (confirmReset) {
        AlertDialog(
            onDismissRequest = { confirmReset = false },
            containerColor   = GlassCard,
            title = { Text("Zerar $label", fontWeight = FontWeight.Bold, color = TextPrimary) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("Dê um nome para esta viagem (opcional):", fontSize = 14.sp, color = TextSecondary)
                    OutlinedTextField(
                        value         = tripName,
                        onValueChange = { tripName = it },
                        placeholder   = { Text("Ex: Goiânia → Catalão", fontSize = 14.sp, color = TextSecondary) },
                        singleLine    = true,
                        modifier      = Modifier.fillMaxWidth(),
                        colors        = OutlinedTextFieldDefaults.colors(
                            focusedTextColor     = TextPrimary,
                            unfocusedTextColor   = TextPrimary,
                            focusedBorderColor   = NeonLime,
                            unfocusedBorderColor = BorderColor,
                            cursorColor          = NeonLime,
                        ),
                    )
                }
            },
            confirmButton = {
                TextButton(onClick = { confirmReset = false; onReset(tripName) }) {
                    Text("Zerar", color = NeonLime, fontWeight = FontWeight.SemiBold)
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmReset = false }) { Text("Cancelar", color = TextSecondary) }
            },
        )
    }
}

@Composable
private fun TColTitle(title: String) {
    Column {
        Text(
            text          = title.uppercase(),
            fontSize      = 9.sp,
            fontWeight    = FontWeight.Bold,
            letterSpacing = 1.4.sp,
            color         = TextSecondary.copy(alpha = 0.6f),
        )
        Spacer(Modifier.height(3.dp))
        HorizontalDivider(color = Color.White.copy(alpha = 0.05f), thickness = 0.5.dp)
        Spacer(Modifier.height(1.dp))
    }
}

@Composable
private fun TMetric(
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

@Composable
private fun LegendDot(color: Color, label: String) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Box(Modifier.size(8.dp).background(color, RoundedCornerShape(2.dp)))
        Text(label, fontSize = 10.sp, color = TextSecondary)
    }
}

private fun formatTime(sec: Long): String {
    val h = sec / 3600
    val m = (sec % 3600) / 60
    val s = sec % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%d:%02d".format(m, s)
}
