package br.com.redesurftank.ecotrip.ui.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
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
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
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
                drawRect(
                    brush   = glowBrush,
                    topLeft = Offset(0f, 0f),
                    size    = Size(size.width, 1.dp.toPx()),
                )
            }
            .padding(horizontal = 13.dp, vertical = 9.dp)
            .fillMaxHeight(),   // sem verticalScroll — tudo visível de uma vez
    ) {
        // ── Header ────────────────────────────────────────────────────────────
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text       = label,
                fontSize   = 19.sp,
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
                fontSize = 14.sp,
                color    = TextSecondary,
            )
        }

        Spacer(Modifier.height(4.dp))

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

        Spacer(Modifier.height(4.dp))

        // ── Métricas (cresce para ocupar espaço disponível) ───────────────────
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            // ── Energia ───────────────────────────────────────────────────────
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(3.dp),
            ) {
                TColTitle("⚡ Energia")
                TMetric("Bruto",   "%.2f kWh".format(snapshot.energyKwh), TextPrimary)
                TRegenMetric(snapshot.regenKwh, snapshot.energyKwh)
                TMetric("Líquido", "%.2f kWh".format(snapshot.netKwh),     WarnYellow)
                if (snapshot.startSocPct > 0f || snapshot.currentSocPct > 0f)
                    TMetric("SOC", "%.0f%% → %.0f%%".format(snapshot.startSocPct, snapshot.currentSocPct), TextPrimary)
            }

            // ── Gauge kWh/100km ───────────────────────────────────────────────
            Box(modifier = Modifier.weight(1.2f), contentAlignment = Alignment.Center) {
                TripGauge(
                    value    = snapshot.kwhPer100km,
                    maxValue = 40f,
                    label    = "kWh/100km",
                    color    = accentColor,
                    modifier = Modifier.size(118.dp),
                )
            }

            // ── Combustível ───────────────────────────────────────────────────
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(3.dp),
            ) {
                TColTitle("⛽ Combustível")
                TMetric("km/L",   "%.2f".format(snapshot.kmPerL),   MoltenOrange)
                TMetric("Gastos", "%.2f L".format(snapshot.fuelL),   TextPrimary)
                if (snapshot.startTankL > 0f || snapshot.currentTankL > 0f)
                    TMetric("Tanque", "%.1fL→%.1fL".format(snapshot.startTankL, snapshot.currentTankL), TextPrimary)
                if (snapshot.combinedKmL > 0f)
                    TMetric("km/L comb.", "%.2f".format(snapshot.combinedKmL), AuroraTeal)
            }
        }

        // ── Custo total ───────────────────────────────────────────────────────
        if (snapshot.costBrl > 0.01f) {
            HorizontalDivider(color = WarnYellow.copy(alpha = 0.18f), thickness = 0.5.dp)
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 3.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment     = Alignment.CenterVertically,
            ) {
                Text(
                    "💰 Custo total",
                    fontSize  = 12.sp,
                    color     = TextSecondary,
                )
                Row(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment     = Alignment.CenterVertically,
                ) {
                    Text(
                        "R$ %.2f".format(snapshot.costBrl),
                        fontSize   = 15.sp,
                        fontWeight = FontWeight.Bold,
                        color      = WarnYellow,
                    )
                    if (snapshot.costPerKm > 0f) {
                        Text(
                            "R$ %.2f/km".format(snapshot.costPerKm),
                            fontSize = 11.sp,
                            color    = WarnYellow.copy(alpha = 0.65f),
                        )
                    }
                }
            }
        }

        Spacer(Modifier.height(3.dp))

        // ── Gráfico (altura fixa — sempre visível) ────────────────────────────
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(88.dp)
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

        Spacer(Modifier.height(3.dp))

        // ── Legenda + botão Zerar ─────────────────────────────────────────────
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                LegendDot(accentColor, "kWh/100km", 13.sp)
                LegendDot(PlasmaBlue, "Comb. (L)", 13.sp)
            }
            androidx.compose.material3.OutlinedButton(
                onClick        = { tripName = ""; confirmReset = true },
                contentPadding = PaddingValues(horizontal = 10.dp, vertical = 2.dp),
                border         = androidx.compose.foundation.BorderStroke(
                    1.dp, Color.White.copy(alpha = 0.07f),
                ),
                shape  = RoundedCornerShape(6.dp),
                colors = androidx.compose.material3.ButtonDefaults.outlinedButtonColors(
                    contentColor = TextSecondary,
                ),
            ) {
                Text("Zerar", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = TextSecondary)
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
            fontSize      = 12.sp,
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
            fontSize = 14.sp,
            color    = TextSecondary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        Text(
            text       = value,
            fontSize   = 17.sp,
            fontWeight = FontWeight.Bold,
            color      = valueColor,
            maxLines   = 1,
            overflow   = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun TRegenMetric(regenKwh: Float, energyKwh: Float) {
    val pct = if (energyKwh <= 0.01f) 0f else (regenKwh / energyKwh * 100f).coerceIn(0f, 100f)
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text     = "Regen",
            fontSize = 14.sp,
            color    = TextSecondary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        Row(
            horizontalArrangement = Arrangement.spacedBy(4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text       = "%.2f kWh".format(regenKwh),
                fontSize   = 17.sp,
                fontWeight = FontWeight.Bold,
                color      = NeonLime,
                maxLines   = 1,
                overflow   = TextOverflow.Ellipsis,
            )
            if (pct > 0f) {
                Text(
                    text     = "(%.0f%%)".format(pct),
                    fontSize = 12.sp,
                    color    = NeonLime.copy(alpha = 0.7f),
                    maxLines = 1,
                )
            }
        }
    }
}

@Composable
private fun LegendDot(color: Color, label: String, fontSize: TextUnit = 12.sp) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Box(Modifier.size(8.dp).background(color, RoundedCornerShape(2.dp)))
        Text(label, fontSize = fontSize, color = TextSecondary)
    }
}

@Composable
private fun TripGauge(
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
            val strokePx   = 8.dp.toPx()
            val inset      = strokePx * 3.2f / 2f
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
                // Halo difuso
                drawArc(
                    color      = color.copy(alpha = 0.07f),
                    startAngle = startAngle,
                    sweepAngle = sweep,
                    useCenter  = false,
                    topLeft    = arcOffset,
                    size       = arcSize,
                    style      = Stroke(width = strokePx * 3.2f, cap = StrokeCap.Round),
                )
                // Glow médio
                drawArc(
                    color      = color.copy(alpha = 0.20f),
                    startAngle = startAngle,
                    sweepAngle = sweep,
                    useCenter  = false,
                    topLeft    = arcOffset,
                    size       = arcSize,
                    style      = Stroke(width = strokePx * 1.8f, cap = StrokeCap.Round),
                )
                // Arco nítido
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
                fontSize   = 26.sp,
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
                fontSize  = 11.sp,
                color     = TextSecondary,
                maxLines  = 1,
                textAlign = TextAlign.Center,
            )
        }
    }
}

private fun formatTime(sec: Long): String {
    val h = sec / 3600
    val m = (sec % 3600) / 60
    val s = sec % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%d:%02d".format(m, s)
}
