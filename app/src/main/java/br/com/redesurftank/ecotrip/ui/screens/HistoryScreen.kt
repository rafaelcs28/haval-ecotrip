package br.com.redesurftank.ecotrip.ui.screens

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import br.com.redesurftank.ecotrip.managers.TripHistoryEntry
import br.com.redesurftank.ecotrip.ui.theme.*
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

@Composable
fun HistoryScreen(
    entries: List<TripHistoryEntry>,
    onClearHistory: () -> Unit,
    onBack: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(SurfaceDeep)
            .systemBarsPadding()
            .padding(horizontal = 10.dp, vertical = 4.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                IconButton(onClick = onBack) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Voltar", tint = TextSecondary)
                }
                Text("Histórico", fontSize = 21.sp, fontWeight = FontWeight.Bold, color = Green)
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Text("${entries.size} viagens", fontSize = 12.sp, color = TextSecondary)
                if (entries.isNotEmpty()) {
                    TextButton(onClick = onClearHistory) {
                        Text("Limpar", fontSize = 13.sp, color = TextSecondary)
                    }
                }
            }
        }

        if (entries.isEmpty()) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text("Nenhuma viagem registrada ainda.", fontSize = 14.sp, color = TextSecondary)
            }
        } else {
            LazyColumn(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                itemsIndexed(entries) { index, entry ->
                    HistoryEntryRow(entry = entry, index = index)
                }
            }
        }
    }
}

@Composable
private fun HistoryEntryRow(entry: TripHistoryEntry, index: Int) {
    var expanded by remember { mutableStateOf(false) }
    val dateFmt  = SimpleDateFormat("dd/MM/yy HH:mm", Locale.getDefault())
    val displayName = entry.name.ifEmpty { entry.label }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(SurfaceCard, RoundedCornerShape(12.dp))
            .border(1.dp, BorderColor, RoundedCornerShape(12.dp))
            .clickable { expanded = !expanded },
    ) {
        // ── Compact row ──────────────────────────────────────────────────────
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 14.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            // Badge Trip A / B
            Box(
                modifier = Modifier
                    .background(SurfaceDeep, RoundedCornerShape(6.dp))
                    .border(1.dp, BorderColor, RoundedCornerShape(6.dp))
                    .padding(horizontal = 6.dp, vertical = 2.dp),
            ) {
                Text(entry.label, fontSize = 10.sp, color = Green, fontWeight = FontWeight.SemiBold)
            }

            // Name + date
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    displayName,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = TextPrimary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(dateFmt.format(Date(entry.timestampMs)), fontSize = 11.sp, color = TextSecondary)
            }

            // Key metrics inline
            CompactMetric("%.1f km".format(entry.distKm),        "dist")
            CompactMetric("%.1f kWh".format(entry.kwhPer100km),  "/100km")
            CompactMetric("%.1f km/L".format(entry.kmPerL),      "comb")

            Icon(
                if (expanded) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                contentDescription = null,
                tint = TextSecondary,
                modifier = Modifier.size(18.dp),
            )
        }

        // ── Expanded details ─────────────────────────────────────────────────
        AnimatedVisibility(visible = expanded) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(start = 14.dp, end = 14.dp, bottom = 12.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                HorizontalDivider(color = Separator, thickness = 0.5.dp)
                Spacer(Modifier.height(2.dp))

                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    DetailMetric("Distância",   "%.1f km".format(entry.distKm),        Modifier.weight(1f))
                    DetailMetric("Tempo",       formatTime(entry.timeSec),              Modifier.weight(1f))
                    DetailMetric("Vel. Média",  "%.1f km/h".format(entry.avgSpeedKmh), Modifier.weight(1f))
                }
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    DetailMetric("kWh/100km",   if (entry.distKm > 0.1f) "%.2f".format(entry.kwhPer100km) else "--", Modifier.weight(1f))
                    DetailMetric("km/L",        if (entry.kmPerL > 0f)   "%.1f".format(entry.kmPerL)      else "--", Modifier.weight(1f))
                    DetailMetric("Combustível", if (entry.fuelL > 0f)    "%.2f L".format(entry.fuelL)     else "--", Modifier.weight(1f))
                }
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    DetailMetric("Energia",    "%.2f kWh".format(entry.energyKwh), Modifier.weight(1f))
                    DetailMetric("Regenerada", "%.2f kWh".format(entry.regenKwh),  Modifier.weight(1f))
                    DetailMetric("Líquido",    "%.2f kWh".format(entry.netKwh),    Modifier.weight(1f), color = Green)
                }
                if (entry.costBrl > 0.01f) {
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        DetailMetric("💰 Custo Total", "R$ %.2f".format(entry.costBrl), Modifier.weight(1f), color = WarnYellow)
                        if (entry.costPerKm > 0f)
                            DetailMetric("R$/km", "%.3f".format(entry.costPerKm), Modifier.weight(1f), color = WarnYellow)
                        else
                            Spacer(Modifier.weight(1f))
                        Spacer(Modifier.weight(1f))
                    }
                }
            }
        }
    }
}

@Composable
private fun CompactMetric(value: String, label: String) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(value, fontSize = 12.sp, fontWeight = FontWeight.Bold, color = TextPrimary)
        Text(label, fontSize = 10.sp, color = TextSecondary)
    }
}

@Composable
private fun DetailMetric(
    label: String,
    value: String,
    modifier: Modifier = Modifier,
    color: androidx.compose.ui.graphics.Color = TextPrimary,
) {
    Column(modifier = modifier) {
        Text(value, fontSize = 15.sp, fontWeight = FontWeight.Bold, color = color)
        Text(label, fontSize = 11.sp, color = TextSecondary)
    }
}

private fun formatTime(sec: Long): String {
    val h = sec / 3600
    val m = (sec % 3600) / 60
    return if (h > 0) "${h}h ${m}min" else "${m}min"
}
