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

data class RoutePlan(
    val destName: String, val destLat: Double, val destLng: Double,
    val distanceKm: Float, val durationMin: Int, val etaClock: String,
    val climbM: Int, val descentM: Int,
    val curSoc: Int, val predictedSoc: Int, val energyKwh: Float, val capacityKwh: Float,
)

private fun etaFromNow(durationMin: Int): String {
    val arrival = java.util.Date(System.currentTimeMillis() + durationMin * 60_000L)
    return java.text.SimpleDateFormat("HH:mm", java.util.Locale.getDefault()).format(arrival)
}

// Minutos de agora até um horário "HH:mm" (ETA do Waze). Se já passou hoje, assume amanhã.
private fun minutesUntilClock(hhmm: String): Int? {
    val m = Regex("""(\d{1,2}):(\d{2})""").find(hhmm) ?: return null
    val h = m.groupValues[1].toInt(); val min = m.groupValues[2].toInt()
    val cal = java.util.Calendar.getInstance().apply {
        set(java.util.Calendar.HOUR_OF_DAY, h); set(java.util.Calendar.MINUTE, min)
        set(java.util.Calendar.SECOND, 0); set(java.util.Calendar.MILLISECOND, 0)
    }
    var diff = (cal.timeInMillis - System.currentTimeMillis()) / 60_000L
    if (diff < -60) diff += 24 * 60   // virou o dia
    return diff.toInt().coerceAtLeast(0)
}

// Previsão de SOC na chegada (compartilhada pela tela Chegada e pelo banner da home).
// Destino por coordenada (toLat/toLng) ou por texto (query). etaClockOverride: ETA do
// Waze ("HH:mm") — quando presente, manda no tempo (mais fiel); distância/altimetria/SOC
// sempre calculados aqui (o Waze não fornece). Roda em IO; retorna null em falha.
suspend fun fetchArrivalPlan(
    tripManager: TripManager,
    toLat: Double?, toLng: Double?, query: String?,
    etaClockOverride: String? = null,
): RoutePlan? = withContext(Dispatchers.IO) {
    val (lat, lng) = tripManager.getLastGps()
    if (lat == 0.0 && lng == 0.0) return@withContext null
    val base = tripManager.bridgeUrlPublic()
    if (base.isBlank()) return@withContext null
    val urlStr = if (toLat != null && toLng != null) {
        val nm = URLEncoder.encode(query ?: "", "UTF-8")
        "$base/api/route-plan?from_lat=$lat&from_lng=$lng&to_lat=$toLat&to_lng=$toLng&q=$nm"
    } else {
        val q = URLEncoder.encode((query ?: "").trim(), "UTF-8")
        "$base/api/route-plan?from_lat=$lat&from_lng=$lng&q=$q"
    }
    val c = (URL(urlStr).openConnection() as HttpURLConnection).apply {
        requestMethod = "GET"
        setRequestProperty("Authorization", "Bearer " + tripManager.bridgeTokenPublic())
        connectTimeout = 12000; readTimeout = 12000
    }
    val code = c.responseCode
    val body = (if (code in 200..299) c.inputStream else c.errorStream)?.bufferedReader()?.readText() ?: ""
    c.disconnect()
    if (code !in 200..299) return@withContext null
    val json = JSONObject(body)
    val distKm = json.optDouble("distanceKm", 0.0).toFloat()
    val climb  = json.optInt("climbM", 0)
    val desc   = json.optInt("descentM", 0)
    val routeMin = json.optInt("durationMin", 0)
    val name   = json.optString("destName", "").ifBlank { query ?: "" }
    // ETA: usa a do Waze quando veio; senão a duração da rota (Mapbox c/ trânsito).
    val wazeMin = etaClockOverride?.let { minutesUntilClock(it) }
    val durMin  = wazeMin ?: routeMin
    val etaClock = if (!etaClockOverride.isNullOrBlank() && wazeMin != null) etaClockOverride else etaFromNow(durMin)
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
    val dLat = json.optDouble("destLat", 0.0)
    val dLng = json.optDouble("destLng", 0.0)
    RoutePlan(name, dLat, dLng, distKm, durMin, etaClock, climb, desc, cur, pred, energy, cap)
}

// Previsão de SOC na chegada: destino → bridge (/api/route-plan: OSRM + elevação) →
// energia = dist × consumo + subida×K − descida×regen; SOC previsto = atual − energia/capacidade.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SocArrivalScreen(
    tripManager: TripManager,
    onBack: () -> Unit,
    initialDest: br.com.redesurftank.ecotrip.managers.MqttManager.NavDest? = null,
) {
    var dest    by remember { mutableStateOf("") }
    var loading by remember { mutableStateOf(false) }
    var error   by remember { mutableStateOf<String?>(null) }
    var plan    by remember { mutableStateOf<RoutePlan?>(null) }
    var sent    by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    // coordDest != null → destino veio do celular (lat/lng prontos); senão usa o texto digitado.
    fun calcular(coordDest: br.com.redesurftank.ecotrip.managers.MqttManager.NavDest? = null) {
        if (coordDest == null && dest.isBlank()) return
        if (loading) return
        loading = true; error = null; plan = null; sent = null
        scope.launch {
            try {
                val (lat, lng) = tripManager.getLastGps()
                if (lat == 0.0 && lng == 0.0) { error = "Sem sinal de GPS ainda."; loading = false; return@launch }
                if (tripManager.bridgeUrlPublic().isBlank()) { error = "Bridge não configurado."; loading = false; return@launch }
                val p = if (coordDest != null)
                    fetchArrivalPlan(tripManager, coordDest.lat, coordDest.lng, coordDest.name, coordDest.etaClock)
                else
                    fetchArrivalPlan(tripManager, null, null, dest.trim(), null)
                if (p == null) error = "Falha ao calcular a rota." else plan = p
            } catch (e: Exception) {
                error = "Falha ao calcular (${e.message})"
            }
            loading = false
        }
    }

    // Destino chegou do celular → preenche o campo e calcula automaticamente.
    LaunchedEffect(initialDest?.ts) {
        if (initialDest != null) {
            dest = initialDest.name.ifBlank { "${initialDest.lat}, ${initialDest.lng}" }
            calcular(initialDest)
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
                    SocStat("Subida", "↑ ${fi(p.climbM)} m", NeonLime)
                    SocStat("Descida", "↓ ${fi(p.descentM)} m", PlasmaBlue)
                    SocStat("Energia", "${f1c(p.energyKwh)} kWh", MoltenOrange)
                }
                Text("Estimativa: consumo recente ${f1c(tripManager.getRecentKwhPerKm()*100f)} kWh/100km · bateria ~${p.capacityKwh.toInt()} kWh (auto-calibrada). Altitude por GPS/mapa.",
                    color = TextSecondary, fontSize = 12.sp)
                // Enviar o destino pro celular navegar (Maps ou Waze) via Android Auto.
                if (p.destLat != 0.0 || p.destLng != 0.0) {
                    HorizontalDivider(color = Separator, thickness = 0.5.dp)
                    Text("Enviar pro celular navegar:", color = TextSecondary, fontSize = 14.sp)
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        val send: (String, String) -> Unit = { app, label ->
                            br.com.redesurftank.ecotrip.managers.MqttManager.getInstance()
                                .publishNavTo(p.destLat, p.destLng, p.destName, app)
                            sent = label
                        }
                        Button(onClick = { send("maps", "Maps") }, modifier = Modifier.weight(1f).height(52.dp),
                            colors = ButtonDefaults.buttonColors(containerColor = AccentBlue)) {
                            Text("📍 Google Maps", fontWeight = FontWeight.Bold, color = VoidBlack)
                        }
                        Button(onClick = { send("waze", "Waze") }, modifier = Modifier.weight(1f).height(52.dp),
                            colors = ButtonDefaults.buttonColors(containerColor = AuroraTeal)) {
                            Text("🚗 Waze", fontWeight = FontWeight.Bold, color = VoidBlack)
                        }
                    }
                    sent?.let { Text("✓ Enviado pro celular ($it) — abrindo navegação.", color = NeonLime, fontSize = 14.sp) }
                }
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

private val PTBR = java.util.Locale("pt", "BR")
private fun f1c(v: Float): String = String.format(PTBR, "%,.1f", v)
private fun fi(v: Int): String = String.format(PTBR, "%,d", v)   // inteiro com milhares (ex.: 1.234)
