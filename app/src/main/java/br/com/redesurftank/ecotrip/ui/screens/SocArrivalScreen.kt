package br.com.redesurftank.ecotrip.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import br.com.redesurftank.ecotrip.managers.TripManager
import br.com.redesurftank.ecotrip.ui.theme.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

private data class RoutePlan(
    val destName: String, val distanceKm: Float, val durationMin: Int, val etaClock: String,
    val climbM: Int, val descentM: Int,
    val curSoc: Int, val predictedSoc: Int, val energyKwh: Float, val capacityKwh: Float,
)

private fun etaFromNow(durationMin: Int): String {
    val arrival = java.util.Date(System.currentTimeMillis() + durationMin * 60_000L)
    return java.text.SimpleDateFormat("HH:mm", java.util.Locale.getDefault()).format(arrival)
}

// Previsão de SOC na chegada: destino → bridge (/api/route-plan: OSRM + elevação) →
// energia = dist × consumo + subida×K − descida×regen; SOC previsto = atual − energia/capacidade.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SocArrivalScreen(tripManager: TripManager, onBack: () -> Unit) {
    var dest    by remember { mutableStateOf("") }
    var loading by remember { mutableStateOf(false) }
    var error   by remember { mutableStateOf<String?>(null) }
    var plan    by remember { mutableStateOf<RoutePlan?>(null) }
    val scope = rememberCoroutineScope()

    fun calcular() {
        if (dest.isBlank() || loading) return
        loading = true; error = null; plan = null
        scope.launch {
            try {
                val (lat, lng) = tripManager.getLastGps()
                if (lat == 0.0 && lng == 0.0) { error = "Sem sinal de GPS ainda."; loading = false; return@launch }
                val base = tripManager.bridgeUrlPublic()
                if (base.isBlank()) { error = "Bridge não configurado."; loading = false; return@launch }
                val q = URLEncoder.encode(dest.trim(), "UTF-8")
                val urlStr = "$base/api/route-plan?from_lat=$lat&from_lng=$lng&q=$q"
                val json = withContext(Dispatchers.IO) {
                    val c = (URL(urlStr).openConnection() as HttpURLConnection).apply {
                        requestMethod = "GET"
                        setRequestProperty("Authorization", "Bearer " + tripManager.bridgeTokenPublic())
                        connectTimeout = 12000; readTimeout = 12000
                    }
                    val code = c.responseCode
                    val body = (if (code in 200..299) c.inputStream else c.errorStream)?.bufferedReader()?.readText() ?: ""
                    c.disconnect()
                    if (code !in 200..299) throw Exception("HTTP $code")
                    JSONObject(body)
                }
                val distKm = json.optDouble("distanceKm", 0.0).toFloat()
                val climb  = json.optInt("climbM", 0)
                val desc   = json.optInt("descentM", 0)
                val durMin = json.optInt("durationMin", 0)
                val name   = json.optString("destName", dest.trim())
                // Tração pela VELOCIDADE média (modelo aprendido das viagens EV) + elevação
                // + climatização (AC + temperatura ATUAIS × tempo da rota).
                val vMed     = if (durMin > 0) distKm / (durMin / 60f) else 40f
                val kwhPerKm = tripManager.predictKwhPerKm(vMed)
                val cap      = tripManager.getBatteryCapacityKwh()
                val acOn     = br.com.redesurftank.ecotrip.managers.MqttManager.getInstance().latestHvacAcEnable == 1
                val tempOut  = tripManager.getOutsideTempC()
                val eClimate = tripManager.acKwhPerHour(tempOut, acOn) * (durMin / 60f)
                val eDrive   = distKm * kwhPerKm
                val eElev    = climb * 0.0064f - desc * 0.0035f
                val energy   = (eDrive + eElev + eClimate).coerceAtLeast(0f)
                val cur      = tripManager.getCurrentSocPct().toInt()
                val pred     = (cur - (energy / cap * 100f)).toInt().coerceIn(0, 100)
                plan = RoutePlan(name, distKm, durMin, etaFromNow(durMin), climb, desc, cur, pred, energy, cap)
            } catch (e: Exception) {
                error = "Falha ao calcular (${e.message})"
            }
            loading = false
        }
    }

    ClaudeScreen(title = "Chegada", onBack = onBack, accent = AuroraTeal) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(
                value = dest, onValueChange = { dest = it },
                label = { Text("Destino (endereço ou local)") },
                singleLine = true,
                modifier = Modifier.weight(1f),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                keyboardActions = KeyboardActions(onSearch = { calcular() }),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedTextColor = TextPrimary, unfocusedTextColor = TextPrimary,
                    focusedBorderColor = AuroraTeal, unfocusedBorderColor = BorderColor,
                    focusedLabelColor = AuroraTeal, unfocusedLabelColor = TextSecondary, cursorColor = AuroraTeal,
                ),
            )
            Button(
                onClick = { calcular() }, enabled = dest.isNotBlank() && !loading,
                colors = ButtonDefaults.buttonColors(containerColor = AuroraTeal),
                modifier = Modifier.height(56.dp),
            ) {
                if (loading) CircularProgressIndicator(Modifier.size(20.dp), color = VoidBlack, strokeWidth = 2.dp)
                else Text("Calcular", fontWeight = FontWeight.Bold, color = VoidBlack)
            }
        }

        error?.let { Text(it, color = DangerRed, fontSize = 15.sp, modifier = Modifier.padding(top = 8.dp)) }

        plan?.let { p ->
            Column(
                Modifier.fillMaxWidth().padding(top = 6.dp).claudeCard(AuroraTeal).padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                Text(p.destName, color = TextSecondary, fontSize = 16.sp, maxLines = 2)
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text("Chegada", color = TextSecondary, fontSize = 16.sp)
                    Text(p.etaClock, color = AuroraTeal, fontSize = 24.sp, fontWeight = FontWeight.ExtraBold)
                    Text("· ${p.durationMin} min", color = TextSecondary, fontSize = 16.sp)
                }
                Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                    Text("SOC na chegada", color = TextSecondary, fontSize = 18.sp, modifier = Modifier.padding(bottom = 12.dp))
                    Text("${p.predictedSoc}", color = if (p.predictedSoc < 15) MoltenOrange else NeonLime,
                        fontSize = 72.sp, fontWeight = FontWeight.ExtraBold)
                    Text("%", color = TextSecondary, fontSize = 28.sp, modifier = Modifier.padding(bottom = 14.dp))
                    Spacer(Modifier.weight(1f))
                    Text("agora ${p.curSoc}%", color = TextSecondary, fontSize = 18.sp, modifier = Modifier.padding(bottom = 14.dp))
                }
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    SocStat("Distância", "${f1c(p.distanceKm)} km", AccentBlue)
                    SocStat("Subida", "↑ ${p.climbM} m", NeonLime)
                    SocStat("Descida", "↓ ${p.descentM} m", PlasmaBlue)
                    SocStat("Energia", "${f1c(p.energyKwh)} kWh", MoltenOrange)
                }
                Text("Estimativa: consumo recente ${f1c(tripManager.getRecentKwhPerKm()*100f)} kWh/100km · bateria ~${p.capacityKwh.toInt()} kWh (auto-calibrada). Altitude por GPS/mapa.",
                    color = TextSecondary, fontSize = 12.sp)
            }
        }
    }
}

@Composable
private fun SocStat(label: String, value: String, color: androidx.compose.ui.graphics.Color) {
    Column {
        Text(value, color = color, fontSize = 22.sp, fontWeight = FontWeight.Bold)
        Text(label, color = TextSecondary, fontSize = 12.sp)
    }
}

private fun f1c(v: Float): String = String.format("%.1f", v).replace(".", ",")
