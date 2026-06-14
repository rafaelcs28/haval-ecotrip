package br.com.redesurftank.ecotrip.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
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
import kotlinx.coroutines.delay
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
    val alts: List<RouteAltCar> = emptyList(),   // rotas alternativas (vazio = só 1)
)

// Rota alternativa pra comparar/escolher. SOC/energia calculados com o MESMO modelo
// do cliente (consumo recente + altimetria + clima), igual à rota primária.
data class RouteAltCar(
    val idx: Int, val distanceKm: Float, val durationMin: Int,
    val climbM: Int, val descentM: Int,
    val predictedSoc: Int, val energyKwh: Float, val etaClock: String,
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
        "$base/api/route-plan?from_lat=$lat&from_lng=$lng&to_lat=$toLat&to_lng=$toLng&q=$nm&alt=1"
    } else {
        val q = URLEncoder.encode((query ?: "").trim(), "UTF-8")
        "$base/api/route-plan?from_lat=$lat&from_lng=$lng&q=$q&alt=1"
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
    val cap      = tripManager.getBatteryCapacityKwh()
    val acOn     = br.com.redesurftank.ecotrip.managers.MqttManager.getInstance().latestHvacAcEnable == 1
    val tempOut  = tripManager.getOutsideTempC()
    val cur      = tripManager.getCurrentSocPct().toInt()
    // Energia + SOC previsto pra um trecho qualquer (rota primária ou alternativa):
    // consumo por faixa (velocidade média) + altimetria + carga do clima.
    fun energyPred(dKm: Float, dMin: Int, cl: Int, de: Int): Pair<Float, Int> {
        val vm  = if (dMin > 0) dKm / (dMin / 60f) else 40f
        val kpk = tripManager.predictKwhPerKm(vm)
        val eC  = tripManager.acKwhPerHour(tempOut, acOn) * (dMin / 60f)
        val e   = (dKm * kpk + (cl * 0.0064f - de * 0.0035f) + eC).coerceAtLeast(0f)
        val p   = (cur - (e / cap * 100f)).toInt().coerceIn(0, 100)
        return e to p
    }
    val (energy, pred) = energyPred(distKm, durMin, climb, desc)
    // Alternativas (só expõe se vier >1): mesmo modelo de energia por rota.
    val altsArr = json.optJSONArray("routes")
    val alts = if (altsArr != null && altsArr.length() > 1) {
        (0 until altsArr.length()).mapNotNull { i ->
            val o = altsArr.optJSONObject(i) ?: return@mapNotNull null
            val aD = o.optDouble("distanceKm", 0.0).toFloat()
            val aMin = o.optInt("durationMin", 0)
            val aCl = o.optInt("climbM", 0); val aDe = o.optInt("descentM", 0)
            val (aE, aP) = energyPred(aD, aMin, aCl, aDe)
            RouteAltCar(o.optInt("idx", i), aD, aMin, aCl, aDe, aP, aE, etaFromNow(aMin))
        }
    } else emptyList()
    val dLat = json.optDouble("destLat", 0.0)
    val dLng = json.optDouble("destLng", 0.0)
    RoutePlan(name, dLat, dLng, distKm, durMin, etaClock, climb, desc, cur, pred, energy, cap, alts)
}

// Desfaz o avanço automático da última parada (janela de 5 min) → POST /api/route-undo.
suspend fun postRouteUndo(tripManager: TripManager): Boolean = withContext(Dispatchers.IO) {
    val base = tripManager.bridgeUrlPublic()
    if (base.isBlank()) return@withContext false
    try {
        val c = (URL("$base/api/route-undo").openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            setRequestProperty("Authorization", "Bearer " + tripManager.bridgeTokenPublic())
            setRequestProperty("Content-Type", "application/json")
            doOutput = true
            connectTimeout = 8000; readTimeout = 8000
        }
        c.outputStream.use { it.write("{}".toByteArray()) }
        val ok = c.responseCode in 200..299
        c.disconnect()
        ok
    } catch (e: Exception) { false }
}

// Pula a próxima parada (não-final) da rota ativa → POST /api/route/skip-stop.
// idx null = a próxima parada (default do bridge). Avança por cima dela e abre a
// janela de desfazer (5 min, skipped=true).
suspend fun postRouteSkip(tripManager: TripManager, idx: Int? = null): Boolean = withContext(Dispatchers.IO) {
    val base = tripManager.bridgeUrlPublic()
    if (base.isBlank()) return@withContext false
    try {
        val c = (URL("$base/api/route/skip-stop").openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            setRequestProperty("Authorization", "Bearer " + tripManager.bridgeTokenPublic())
            setRequestProperty("Content-Type", "application/json")
            doOutput = true
            connectTimeout = 8000; readTimeout = 8000
        }
        val body = if (idx != null) "{\"idx\":$idx}" else "{}"
        c.outputStream.use { it.write(body.toByteArray()) }
        val ok = c.responseCode in 200..299
        c.disconnect()
        ok
    } catch (e: Exception) { false }
}

data class GeoSuggestion(val name: String, val detail: String, val lat: Double, val lng: Double)

// Autocomplete de endereço: /api/geocode-suggest (Mapbox Search Box, viés na GPS do carro).
suspend fun fetchSuggestions(tripManager: TripManager, q: String): List<GeoSuggestion> = withContext(Dispatchers.IO) {
    val query = q.trim()
    if (query.length < 3) return@withContext emptyList()
    val base = tripManager.bridgeUrlPublic()
    if (base.isBlank()) return@withContext emptyList()
    val (lat, lng) = tripManager.getLastGps()
    var urlStr = "$base/api/geocode-suggest?q=${URLEncoder.encode(query, "UTF-8")}"
    if (lat != 0.0 || lng != 0.0) urlStr += "&lat=$lat&lng=$lng"
    try {
        val c = (URL(urlStr).openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            setRequestProperty("Authorization", "Bearer " + tripManager.bridgeTokenPublic())
            connectTimeout = 8000; readTimeout = 8000
        }
        val code = c.responseCode
        val body = (if (code in 200..299) c.inputStream else c.errorStream)?.bufferedReader()?.readText() ?: ""
        c.disconnect()
        if (code !in 200..299) return@withContext emptyList()
        val arr = JSONObject(body).optJSONArray("suggestions") ?: return@withContext emptyList()
        (0 until arr.length()).mapNotNull { i ->
            val o = arr.optJSONObject(i) ?: return@mapNotNull null
            val la = o.optDouble("lat", 0.0); val lo = o.optDouble("lng", 0.0)
            if (la == 0.0 && lo == 0.0) null else GeoSuggestion(o.optString("name"), o.optString("detail"), la, lo)
        }
    } catch (e: Exception) { emptyList() }
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
    var suggestions by remember { mutableStateOf<List<GeoSuggestion>>(emptyList()) }
    var suppressSuggest by remember { mutableStateOf(false) }
    var selectedAltIdx by remember { mutableStateOf(0) }   // rota escolhida (0 = recomendada)
    val scope = rememberCoroutineScope()

    // Troca a previsão mostrada pela rota alternativa escolhida (reescreve as métricas
    // de topo; mantém a lista de alternativas e o destino).
    fun selectAlt(a: RouteAltCar) {
        val p = plan ?: return
        selectedAltIdx = a.idx
        plan = p.copy(distanceKm = a.distanceKm, durationMin = a.durationMin, etaClock = a.etaClock,
                      climbM = a.climbM, descentM = a.descentM, predictedSoc = a.predictedSoc, energyKwh = a.energyKwh)
    }

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
                if (p == null) error = "Falha ao calcular a rota." else { plan = p; selectedAltIdx = 0 }
            } catch (e: Exception) {
                error = "Falha ao calcular (${e.message})"
            }
            loading = false
        }
    }

    fun pick(s: GeoSuggestion) {
        suppressSuggest = true
        dest = s.name
        suggestions = emptyList()
        calcular(br.com.redesurftank.ecotrip.managers.MqttManager.NavDest(s.lat, s.lng, s.name, System.currentTimeMillis(), ""))
    }

    // Destino chegou do celular → preenche o campo e calcula automaticamente.
    LaunchedEffect(initialDest?.ts) {
        if (initialDest != null) {
            suppressSuggest = true
            dest = initialDest.name.ifBlank { "${initialDest.lat}, ${initialDest.lng}" }
            calcular(initialDest)
        }
    }

    // Autocomplete: busca sugestões enquanto digita (debounce 350ms).
    LaunchedEffect(dest) {
        if (suppressSuggest) { suppressSuggest = false; return@LaunchedEffect }
        if (dest.trim().length < 3) { suggestions = emptyList(); return@LaunchedEffect }
        plan = null
        delay(350)
        suggestions = fetchSuggestions(tripManager, dest)
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

        // Sugestões de endereço (autocomplete) enquanto digita.
        if (suggestions.isNotEmpty() && plan == null) {
            Column(Modifier.fillMaxWidth().padding(top = 6.dp).claudeCard(AuroraTeal).padding(vertical = 4.dp)) {
                suggestions.take(6).forEach { s ->
                    Column(
                        Modifier.fillMaxWidth().clickable { pick(s) }.padding(horizontal = 16.dp, vertical = 10.dp),
                    ) {
                        Text(s.name, color = TextPrimary, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
                        if (s.detail.isNotBlank())
                            Text(s.detail, color = TextSecondary, fontSize = 12.sp, maxLines = 1)
                    }
                }
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

                // Escolha de rota: compara alternativas (tempo/dist/SOC) e escolhe — a
                // previsão acima passa a refletir a rota selecionada.
                if (p.alts.size > 1) {
                    HorizontalDivider(color = Separator, thickness = 0.5.dp)
                    Text("Rotas", color = TextSecondary, fontSize = 14.sp)
                    p.alts.forEach { a ->
                        val sel = a.idx == selectedAltIdx
                        Surface(
                            onClick = { selectAlt(a) },
                            color = if (sel) AuroraTeal.copy(alpha = 0.12f) else SurfaceCard,
                            shape = RoundedCornerShape(10.dp),
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Row(
                                Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 10.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(12.dp),
                            ) {
                                Text(if (sel) "◉" else "○", color = if (sel) AuroraTeal else TextSecondary, fontSize = 18.sp)
                                Column(Modifier.weight(1f)) {
                                    Text(if (a.idx == 0) "Rota recomendada" else "Alternativa ${a.idx}",
                                        color = TextPrimary, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                                    Text("${a.durationMin} min · ${f1c(a.distanceKm)} km", color = TextSecondary, fontSize = 12.sp)
                                }
                                Text("${a.predictedSoc}%", color = if (a.predictedSoc < 15) MoltenOrange else NeonLime,
                                    fontSize = 20.sp, fontWeight = FontWeight.Bold)
                            }
                        }
                    }
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
