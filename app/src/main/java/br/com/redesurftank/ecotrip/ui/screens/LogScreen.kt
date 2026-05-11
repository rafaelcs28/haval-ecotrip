package br.com.redesurftank.ecotrip.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import br.com.redesurftank.ecotrip.managers.AppLogger
import br.com.redesurftank.ecotrip.managers.CarDataManager
import br.com.redesurftank.ecotrip.managers.LogLevel
import br.com.redesurftank.ecotrip.ui.theme.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/** Chaves candidatas para potência elétrica — testadas pelo botão "Probe". */
/** Chaves a sondar com o botão ⚡ Probe.
 *  IMPORTANTE: rode este probe ANDANDO (não parado/carregando) para ver os valores de motor. */
private val BATTERY_PROBE_KEYS = listOf(
    // ── REFERÊNCIA (sabemos que funcionam) ────────────────────────────────────
    "car.ev_info.cur_charge_current",       // A — corrente AC de carga (funciona carregando)
    "car.ev_info.power_battery_voltage",    // V — tensão do pack      (funciona sempre)

    // ── ALVO PRINCIPAL: potência do motor elétrico (testar ANDANDO) ──────────
    "car.ev_info.motor_power",              // kW direto do HCU — ouro se funcionar
    "car.ev_info.power_battery_current",    // A — corrente DC do pack (sem prefixo cur.)
    "car.ev_info.cur_battery_power_percentage", // % potência da bateria

    // ── MOTOR / TREM DE FORÇA (testar ANDANDO) ────────────────────────────────
    "car.ev_info.drive_motor_power",
    "car.ev_info.motor_torque",
    "car.ev_info.motor_speed",
    "car.ev_info.motor_rpm",
    "car.ev_info.drive_motor_speed",
    "car.ev_info.rear_motor_speed",
    "car.ev_info.hcu_power_train_state",
    "car.ev_info.energy_drive_state",

    // ── VARIANTES DC do pack (testar ANDANDO) ────────────────────────────────
    "car.ev_info.cur_battery_current",
    "car.ev_info.cur_battery_voltage",
    "car.ev_info.discharge_current",
    "car.ev_info.battery_current",
    "car.ev_info.battery_voltage",
    "car.ev_info.battery_power",
    "car.ev_info.bms_current",
    "car.ev_info.bms_voltage",
    "car.ev_info.total_battery_current",
    "car.ev_info.total_battery_voltage",
    "car.ev_info.phev_ahd_voltage",

    // ── CONSUMO INSTANTÂNEO ────────────────────────────────────────────────
    "car.ev_info.Instant_energy_consumption",
    "car.ev_info.instant_energy_consumption",
    "car.ev_info.energy_output_percentage",
)

@Composable
fun LogScreen(onBack: () -> Unit) {
    val entries by AppLogger.entries.collectAsState()
    val listState = rememberLazyListState()
    val scope = rememberCoroutineScope()
    var probing by remember { mutableStateOf(false) }

    LaunchedEffect(entries.size) {
        if (entries.isNotEmpty()) listState.animateScrollToItem(entries.size - 1)
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(SurfaceDeep)
            .systemBarsPadding()
            .padding(horizontal = 10.dp, vertical = 4.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                IconButton(onClick = onBack) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Voltar", tint = TextSecondary)
                }
                Text("Log do App", fontSize = 18.sp, fontWeight = FontWeight.Bold, color = Green)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                TextButton(
                    onClick = {
                        if (probing) return@TextButton
                        probing = true
                        scope.launch(Dispatchers.IO) {
                            val car = CarDataManager.getInstance()
                            AppLogger.i("PROBE", "=== Iniciando probe de ${BATTERY_PROBE_KEYS.size} chaves ===")
                            for (key in BATTERY_PROBE_KEYS) {
                                val v = try { car.fetchCurrent(key) } catch (_: Exception) { null }
                                val label = if (v != null) "→ \"$v\"" else "→ null (chave inexistente ou sem valor)"
                                AppLogger.i("PROBE", "$key $label")
                            }
                            AppLogger.i("PROBE", "=== Probe concluído ===")
                            probing = false
                        }
                    },
                    enabled = !probing,
                ) {
                    Text(if (probing) "⏳" else "⚡ Probe", fontSize = 13.sp, color = Cyan)
                }
                TextButton(onClick = { AppLogger.clear() }) {
                    Text("Limpar", fontSize = 13.sp, color = TextSecondary)
                }
            }
        }

        HorizontalDivider(color = Separator, thickness = 0.5.dp)
        Spacer(Modifier.height(4.dp))

        if (entries.isEmpty()) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text("Nenhum log ainda.", fontSize = 13.sp, color = TextSecondary)
            }
        } else {
            LazyColumn(
                state = listState,
                modifier = Modifier.fillMaxSize(),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                items(entries) { entry ->
                    val (levelColor, levelLabel) = when (entry.level) {
                        LogLevel.ERROR -> Color(0xFFFF4444) to "E"
                        LogLevel.WARN  -> Color(0xFFFFD60A) to "W"
                        LogLevel.INFO  -> TextPrimary        to "I"
                        LogLevel.DEBUG -> TextSecondary      to "D"
                    }
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Text(
                            entry.time,
                            fontSize = 10.sp,
                            fontFamily = FontFamily.Monospace,
                            color = TextSecondary,
                            modifier = Modifier.width(54.dp),
                        )
                        Text(
                            levelLabel,
                            fontSize = 10.sp,
                            fontFamily = FontFamily.Monospace,
                            fontWeight = FontWeight.Bold,
                            color = levelColor,
                            modifier = Modifier.width(10.dp),
                        )
                        Text(
                            "[${entry.tag}] ${entry.msg}",
                            fontSize = 10.sp,
                            fontFamily = FontFamily.Monospace,
                            color = levelColor,
                            modifier = Modifier.weight(1f),
                        )
                    }
                }
            }
        }
    }
}
