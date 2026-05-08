package br.com.redesurftank.ecotrip.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import br.com.redesurftank.ecotrip.managers.ChargeHistoryEntry
import br.com.redesurftank.ecotrip.ui.theme.*
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

@Composable
fun ChargeHistoryScreen(
    entries: List<ChargeHistoryEntry>,
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
                Text("Recargas", fontSize = 21.sp, fontWeight = FontWeight.Bold, color = AuroraTeal)
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Text("${entries.size} sessões", fontSize = 12.sp, color = TextSecondary)
                if (entries.isNotEmpty()) {
                    TextButton(onClick = onClearHistory) {
                        Text("Limpar", fontSize = 13.sp, color = TextSecondary)
                    }
                }
            }
        }

        if (entries.isEmpty()) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text("Nenhuma sessão de recarga registrada ainda.", fontSize = 14.sp, color = TextSecondary)
            }
        } else {
            LazyColumn(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                itemsIndexed(entries) { _, entry ->
                    ChargeEntryRow(entry = entry)
                }
            }
        }
    }
}

@Composable
private fun ChargeEntryRow(entry: ChargeHistoryEntry) {
    val dateFmt = SimpleDateFormat("dd/MM/yy HH:mm", Locale.getDefault())

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(SurfaceCard, RoundedCornerShape(12.dp))
            .border(1.dp, BorderColor, RoundedCornerShape(12.dp))
            .padding(horizontal = 14.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        // ── Linha 1: data/hora  ←→  SOC inicial → SOC final ─────────────────
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                // Badge ⚡
                Box(
                    modifier = Modifier
                        .background(AuroraTeal.copy(alpha = 0.12f), RoundedCornerShape(6.dp))
                        .border(1.dp, AuroraTeal.copy(alpha = 0.3f), RoundedCornerShape(6.dp))
                        .padding(horizontal = 6.dp, vertical = 2.dp),
                ) {
                    Text("⚡", fontSize = 11.sp)
                }
                Text(
                    dateFmt.format(Date(entry.timestampMs)),
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = TextPrimary,
                )
            }
            // SOC start → end
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text(
                    "%.0f%%".format(entry.startSocPct),
                    fontSize = 13.sp,
                    color = TextSecondary,
                )
                Text("→", fontSize = 11.sp, color = TextSecondary)
                Text(
                    "%.0f%%".format(entry.endSocPct),
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Bold,
                    color = AuroraTeal,
                )
            }
        }

        HorizontalDivider(color = Separator, thickness = 0.5.dp)

        // ── Linha 2: métricas ─────────────────────────────────────────────────
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(0.dp),
        ) {
            ChargeMetric(
                value  = formatChargeDuration(entry.durationSec),
                label  = "Duração",
                modifier = Modifier.weight(1f),
            )
            ChargeMetric(
                value  = "%.2f kWh".format(entry.energyKwh),
                label  = "Energia",
                modifier = Modifier.weight(1f),
                color  = AuroraTeal,
            )
            ChargeMetric(
                value  = "%.1f kW".format(entry.avgPowerKw),
                label  = "Pot. Média",
                modifier = Modifier.weight(1f),
            )
        }
    }
}

@Composable
private fun ChargeMetric(
    value: String,
    label: String,
    modifier: Modifier = Modifier,
    color: androidx.compose.ui.graphics.Color = TextPrimary,
) {
    Column(modifier = modifier) {
        Text(value, fontSize = 14.sp, fontWeight = FontWeight.Bold, color = color)
        Text(label, fontSize = 11.sp, color = TextSecondary)
    }
}

private fun formatChargeDuration(sec: Long): String {
    val h = sec / 3600
    val m = (sec % 3600) / 60
    return if (h > 0) "${h}h ${m}min" else "${m}min"
}
