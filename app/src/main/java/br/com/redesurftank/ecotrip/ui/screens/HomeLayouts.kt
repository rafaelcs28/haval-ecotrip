package br.com.redesurftank.ecotrip.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.runtime.getValue
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.RowScope
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.style.TextAlign
import br.com.redesurftank.ecotrip.R
import br.com.redesurftank.ecotrip.managers.AutoTripEntry
import br.com.redesurftank.ecotrip.ui.theme.*

// ── Dados da tela inicial (viagem atual + bateria + estado do carro) ──────────
data class HomeData(
    val distKm: Float,
    val timeStr: String,
    val avgSpeedKmh: Int,
    val maxSpeedKmh: Int,
    val kwh100: Float,
    val effPct: Float,          // 0..1 preenchimento do anel de eficiência
    val netKwh: Float,
    val regenKwh: Float,
    val regenPct: Int,
    val fuelL: Float,
    val costBrl: Float,
    val costPerKm: Float,
    val socPct: Int,
    val startSocPct: Int,
    val rangeEvKm: Int,
    val outsideTempC: Int,
    val modeEv: Boolean,
    // estado do carro (pro desenho interativo)
    val doorFL: Boolean, val doorFR: Boolean, val doorRL: Boolean, val doorRR: Boolean,
    val trunk: Boolean, val sunroof: Boolean, val locked: Boolean,
    val winFL: Boolean, val winFR: Boolean, val winRL: Boolean, val winRR: Boolean,
    val frontLight: Boolean = false,
    // Setas: cada lado pisca independente; os dois juntos = pisca-alerta (4 setas).
    val turnLeft: Boolean = false,
    val turnRight: Boolean = false,
    // Navegação ativa (destino vindo do celular/tela Chegada): mostra um banner de
    // "viagem em andamento" com destino, ETA, km restantes e SOC previsto na chegada.
    val navActive: Boolean = false,
    val navName: String = "",
    val navDistKm: Float = 0f,
    val navEtaMin: Int = 0,
    val navEtaClock: String = "",
    val navArrivalSoc: Int = 0,
) {
    companion object {
        val sample = HomeData(
            distKm = 23.4f, timeStr = "38 min", avgSpeedKmh = 37, maxSpeedKmh = 82,
            kwh100 = 14.2f, effPct = 0.74f, netKwh = 3.3f, regenKwh = 0.8f, regenPct = 20,
            fuelL = 0.0f, costBrl = 1.92f, costPerKm = 0.082f,
            socPct = 62, startSocPct = 78, rangeEvKm = 95, outsideTempC = 27, modeEv = true,
            doorFL = false, doorFR = false, doorRL = false, doorRR = false,
            trunk = false, sunroof = true, locked = false,
            winFL = false, winFR = false, winRL = false, winRR = false,
            frontLight = true,
            turnLeft = false, turnRight = false,
            navActive = true, navName = "Trindade", navDistKm = 18.3f,
            navEtaMin = 27, navEtaClock = "14:32", navArrivalSoc = 47,
        )
    }
}

// Valor do índice idx numa CSV do carro (limpa chaves/lixo: "{0,1,0}" → 0,1,0).
private fun csvVal(csv: String, idx: Int): Int {
    val clean = csv.replace(Regex("[^0-9,\\-]"), "")
    return clean.split(",").getOrNull(idx)?.trim()?.toIntOrNull() ?: 0
}
// Semântica confirmada via barramento + dashboard HA (havaleiros):
private fun doorOpen(csv: String, idx: Int): Boolean = csvVal(csv, idx) == 1          // porta: 1=aberta, 0=fechada
private fun winOpen(csv: String, idx: Int): Boolean = csvVal(csv, idx).let { it == 2 || it == 3 } // vidro: 2=aberto, 3=entreaberto, 1=fechado

// Monta o HomeData a partir da viagem atual/última + estado real do corpo do carro.
fun buildHomeData(
    trip: AutoTripEntry?,
    isLive: Boolean,
    nowMs: Long,
    priceGasL: Float,
    priceKwh: Float,
    socNowPct: Float,
    tempC: Int,
    rangeEvKm: Int,
    doorCsv: String,
    windowCsv: String,
    sunroof: Int,
    locked: Boolean,
    frontLight: Boolean,
    turnLeft: Boolean = false,
    turnRight: Boolean = false,
): HomeData {
    val timeSec = when {
        trip == null -> 0L
        isLive -> ((nowMs - trip.startMs) / 1000L).coerceAtLeast(0L)
        else -> ((trip.endMs - trip.startMs) / 1000L).coerceAtLeast(trip.timeSec)
    }
    val timeStr = when {
        timeSec >= 3600 -> "${timeSec / 3600}h ${(timeSec % 3600) / 60}min"
        timeSec >= 60   -> "${timeSec / 60} min"
        else            -> "${timeSec}s"
    }
    val dist = trip?.distKm ?: 0f
    val netKwh = trip?.netKwh ?: 0f
    val energyKwh = trip?.energyKwh ?: 0f
    val regenKwh = trip?.regenKwh ?: 0f
    val fuelL = trip?.fuelL ?: 0f
    val kwh100 = if (dist > 0.5f) netKwh / dist * 100f else 0f
    val avg = if (timeSec > 0 && dist > 0f) (dist / (timeSec / 3600f)).toInt() else 0
    val regenPct = if (energyKwh > 0.01f) (regenKwh / energyKwh * 100f).toInt() else 0
    val netPos = netKwh.coerceAtLeast(0f)
    val cost = fuelL * priceGasL + netPos * priceKwh
    val costPerKm = if (dist > 0.1f) cost / dist else 0f
    val modeEv = fuelL < 0.05f
    val soc = (if (socNowPct > 0f) socNowPct else trip?.endSocPct ?: 0f).toInt()
    return HomeData(
        distKm = dist, timeStr = timeStr, avgSpeedKmh = avg, maxSpeedKmh = (trip?.maxSpeedKmh ?: 0f).toInt(),
        kwh100 = kwh100, effPct = (kwh100 / 40f).coerceIn(0f, 1f),
        netKwh = netKwh, regenKwh = regenKwh, regenPct = regenPct,
        fuelL = fuelL, costBrl = cost, costPerKm = costPerKm,
        socPct = soc, startSocPct = (trip?.startSocPct ?: 0f).toInt(),
        rangeEvKm = rangeEvKm, outsideTempC = trip?.outsideTempC?.toInt() ?: tempC, modeEv = modeEv,
        doorFL = doorOpen(doorCsv, 0), doorFR = doorOpen(doorCsv, 1),
        doorRL = doorOpen(doorCsv, 2), doorRR = doorOpen(doorCsv, 3),
        trunk = doorOpen(doorCsv, 4), sunroof = sunroof > 0, locked = locked,
        winFL = winOpen(windowCsv, 0), winFR = winOpen(windowCsv, 1),
        winRL = winOpen(windowCsv, 2), winRR = winOpen(windowCsv, 3),
        frontLight = frontLight,
        turnLeft = turnLeft, turnRight = turnRight,
    )
}

private fun f1(v: Float): String = String.format("%.1f", v).replace(".", ",")
private fun f2(v: Float): String = String.format("%.2f", v).replace(".", ",")
private fun f3(v: Float): String = String.format("%.3f", v).replace(".", ",")

private fun socColor(soc: Int): Color = when {
    soc < 30 -> Color(0xFFFF5F1F)   // vermelho/laranja: chegada crítica
    soc < 50 -> Color(0xFFFFB648)   // amarelo: chegada apertada
    else     -> Color(0xFF28C98A)   // verde: chegada confortável
}

// ── Banner "viagem em andamento" — By Claude (glass/neon) ─────────────────────
@Composable
private fun ClaudeNavBanner(d: HomeData) {
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(GlassCard)
            .border(1.5.dp, AuroraTeal.copy(alpha = 0.35f), RoundedCornerShape(16.dp))
            .padding(horizontal = 22.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text("📍", fontSize = 22.sp)
        Spacer(Modifier.width(12.dp))
        Column {
            Text("VIAGEM EM ANDAMENTO", color = AuroraTeal, fontSize = 13.sp, fontWeight = FontWeight.Bold, letterSpacing = 2.sp)
            Text(d.navName, color = TextPrimary, fontSize = 22.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
        }
        Spacer(Modifier.weight(1f))
        NavStat("chegada", d.navEtaClock, "${d.navEtaMin} min", TextPrimary)
        NavDivider()
        NavStat("restante", "${f1(d.navDistKm)} km", "", TextPrimary)
        NavDivider()
        NavStat("SOC chegada", "${d.navArrivalSoc}%", "", socColor(d.navArrivalSoc))
    }
}

@Composable
private fun NavStat(label: String, value: String, sub: String, color: Color) {
    Column(horizontalAlignment = Alignment.End) {
        Text(label, color = TextSecondary, fontSize = 13.sp)
        Text(value, color = color, fontSize = 28.sp, fontWeight = FontWeight.ExtraBold, maxLines = 1)
        if (sub.isNotBlank()) Text(sub, color = TextSecondary, fontSize = 13.sp)
    }
}

@Composable
private fun NavDivider() {
    Box(Modifier.padding(horizontal = 22.dp).width(1.dp).height(44.dp).background(Color(0xFF2A3240)))
}

// ── Banner "viagem em andamento" — Tesla (minimalista) ────────────────────────
@Composable
private fun TeslaNavBanner(d: HomeData) {
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(Color(0xFF161618))
            .padding(horizontal = 24.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text("➜", color = Color(0xFF28C98A), fontSize = 30.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.width(16.dp))
        Text(d.navName, color = Color.White, fontSize = 28.sp, fontWeight = FontWeight.Medium, maxLines = 1)
        Spacer(Modifier.weight(1f))
        TeslaNavCell("Chegada", d.navEtaClock, "${d.navEtaMin} min", Color.White)
        Spacer(Modifier.width(40.dp))
        TeslaNavCell("Faltam", "${f1(d.navDistKm)} km", "", Color.White)
        Spacer(Modifier.width(40.dp))
        TeslaNavCell("SOC na chegada", "${d.navArrivalSoc}%", "", socColor(d.navArrivalSoc))
    }
}

@Composable
private fun TeslaNavCell(label: String, value: String, sub: String, color: Color) {
    Column(horizontalAlignment = Alignment.End) {
        Text(label, color = Color(0xFF8E8E93), fontSize = 17.sp)
        Text(value, color = color, fontSize = 30.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
        if (sub.isNotBlank()) Text(sub, color = Color(0xFF8E8E93), fontSize = 16.sp)
    }
}

// ── Banner "viagem em andamento" — Europeu (cockpit, pílula central) ──────────
@Composable
private fun EuroNavBanner(d: HomeData) {
    Row(
        Modifier.clip(RoundedCornerShape(24.dp))
            .background(Color(0xFF11202B))
            .border(1.dp, Color(0xFF2D7DFF).copy(alpha = 0.4f), RoundedCornerShape(24.dp))
            .padding(horizontal = 26.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text("📍 ${d.navName}", color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
        Spacer(Modifier.width(28.dp))
        Text("${d.navEtaClock} · ${d.navEtaMin} min", color = Color(0xFF5EC8FF), fontSize = 22.sp, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.width(20.dp))
        Text("${f1(d.navDistKm)} km", color = Color(0xFF9AA6B4), fontSize = 22.sp)
        Spacer(Modifier.width(20.dp))
        Text("SOC ${d.navArrivalSoc}%", color = socColor(d.navArrivalSoc), fontSize = 24.sp, fontWeight = FontWeight.Bold)
    }
}

// ════════════════════════════════════════════════════════════════════════════
//  LAYOUT 3 — "BY CLAUDE": tema neon, carro + anel de eficiência + cards
// ════════════════════════════════════════════════════════════════════════════
@Composable
fun HomeClaudeLayout(d: HomeData, actions: @Composable RowScope.() -> Unit = {}, car: @Composable (Modifier) -> Unit = {}) {
    Box(
        Modifier
            .fillMaxSize()
            .background(
                Brush.radialGradient(
                    colors = listOf(Color(0xFF0D1320), VoidBlack),
                    center = Offset(800f, 300f), radius = 1400f
                )
            )
            .padding(horizontal = 40.dp, vertical = 8.dp)
    ) {
        Column(Modifier.fillMaxSize()) {
            // Header
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text("ECOTRIP", color = NeonLime, fontSize = 26.sp, fontWeight = FontWeight.ExtraBold, letterSpacing = 3.sp)
                Spacer(Modifier.width(14.dp))
                Text("Haval H6 PHEV", color = TextSecondary, fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.weight(1f))
                Text(if (d.modeEv) "EV · ${d.outsideTempC}°" else "${d.outsideTempC}°", color = Color(0xFF8DA0BD), fontSize = 20.sp)
                actions()
            }
            if (d.navActive) { Spacer(Modifier.height(8.dp)); ClaudeNavBanner(d) }
            Spacer(Modifier.height(10.dp))
            Row(Modifier.fillMaxSize(), horizontalArrangement = Arrangement.spacedBy(28.dp)) {
                // ESQUERDA: carro + bateria
                Column(Modifier.weight(1.1f).fillMaxHeight(), horizontalAlignment = Alignment.CenterHorizontally) {
                    car(Modifier.weight(1f).fillMaxWidth())
                    Spacer(Modifier.height(6.dp))
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom) {
                        Text("${d.socPct}", color = TextPrimary, fontSize = 40.sp, fontWeight = FontWeight.ExtraBold)
                        Text("%", color = TextSecondary, fontSize = 22.sp, modifier = Modifier.padding(bottom = 4.dp))
                        if (d.rangeEvKm > 0) {
                            Spacer(Modifier.width(12.dp))
                            Text("${d.rangeEvKm} km EV", color = AuroraTeal, fontSize = 22.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(bottom = 6.dp))
                        }
                    }
                    Box(Modifier.fillMaxWidth().height(16.dp).clip(RoundedCornerShape(8.dp)).background(Color(0xFF141B28))) {
                        Box(Modifier.fillMaxWidth(d.socPct / 100f).fillMaxHeight().clip(RoundedCornerShape(8.dp))
                            .background(Brush.horizontalGradient(listOf(NeonLime, AuroraTeal))))
                    }
                }
                // CENTRO: anel de eficiência + resumo da viagem
                Column(Modifier.weight(1.2f).fillMaxHeight(), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("VIAGEM ATUAL", color = TextSecondary, fontSize = 17.sp, fontWeight = FontWeight.Bold, letterSpacing = 3.sp)
                    Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                        EfficiencyRing(d.effPct, Modifier.fillMaxHeight().aspectRatio(1f))
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Text(f1(d.kwh100), color = Color.White, fontSize = 88.sp, fontWeight = FontWeight.ExtraBold)
                            Text("kWh / 100 km", color = Color(0xFF8DA0BD), fontSize = 20.sp)
                            Text("EFICIÊNCIA", color = NeonLime, fontSize = 16.sp, fontWeight = FontWeight.Bold, letterSpacing = 2.sp)
                        }
                    }
                    Row(verticalAlignment = Alignment.Bottom) {
                        Text("${f1(d.distKm)} km", color = TextPrimary, fontSize = 30.sp, fontWeight = FontWeight.Bold)
                        Text("   ·   ${d.timeStr}   ·   ${d.avgSpeedKmh} km/h", color = TextSecondary, fontSize = 20.sp, modifier = Modifier.padding(bottom = 2.dp))
                    }
                }
                // DIREITA: cards
                Column(Modifier.weight(1.3f).fillMaxHeight(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Row(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        MetricCard(Modifier.weight(1f), "Energia líquida", "${f1(d.netKwh)} kWh", AuroraTeal)
                        MetricCard(Modifier.weight(1f), "Regeneração", "${f1(d.regenKwh)} · ${d.regenPct}%", PlasmaBlue)
                    }
                    Row(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        MetricCard(Modifier.weight(1f), "Velocidade média", "${d.avgSpeedKmh} km/h", TextPrimary)
                        MetricCard(Modifier.weight(1f), if (d.modeEv) "Combustível" else "Combustível", "${f1(d.fuelL)} L", MoltenOrange)
                    }
                    Row(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        MetricCard(Modifier.weight(1f), "Custo", "R$ ${f2(d.costBrl)}", TextPrimary)
                        MetricCard(Modifier.weight(1f), "Por km", "${f3(d.costPerKm)} ✓", NeonLime)
                    }
                }
            }
        }
    }
}

@Composable
private fun EfficiencyRing(pct: Float, modifier: Modifier = Modifier) {
    Canvas(modifier) {
        val sw = 26.dp.toPx()
        val inset = sw / 2 + 4.dp.toPx()
        val arcSize = Size(size.width - inset * 2, size.height - inset * 2)
        val topLeft = Offset(inset, inset)
        drawArc(Color(0xFF141B28), 0f, 360f, false, topLeft, arcSize, style = Stroke(sw, cap = StrokeCap.Round))
        drawArc(
            brush = Brush.linearGradient(listOf(NeonLime, AuroraTeal)),
            startAngle = -90f, sweepAngle = 360f * pct.coerceIn(0f, 1f), useCenter = false,
            topLeft = topLeft, size = arcSize, style = Stroke(sw, cap = StrokeCap.Round)
        )
    }
}

@Composable
private fun MetricCard(modifier: Modifier, label: String, value: String, accent: Color) {
    Column(
        modifier
            .fillMaxHeight()
            .clip(RoundedCornerShape(18.dp))
            .background(GlassCard)
            .border(1.5.dp, accent.copy(alpha = 0.25f), RoundedCornerShape(18.dp))
            .padding(horizontal = 20.dp, vertical = 14.dp),
        verticalArrangement = Arrangement.Center,
    ) {
        Text(label, color = TextSecondary, fontSize = 16.sp)
        Spacer(Modifier.height(6.dp))
        Text(value, color = accent, fontSize = 38.sp, fontWeight = FontWeight.ExtraBold, maxLines = 1)
    }
}

// ── Carro interativo: render real do H6 (vista de cima) com camadas de estado ──
@Composable
fun InteractiveCar(d: HomeData, modifier: Modifier = Modifier) {
    Box(modifier, contentAlignment = Alignment.Center) {
        val layer: @Composable (Int) -> Unit = { res ->
            Image(painterResource(res), null, Modifier.fillMaxSize(), contentScale = ContentScale.Fit)
        }
        layer(R.drawable.h6)
        if (d.frontLight) layer(R.drawable.farol)
        // Retrovisor/seta no MESMO arco curvo (coluna A): cinza = retrovisor (porta fechada);
        // âmbar piscando = seta ligada (substitui o retrovisor). Mesma forma/posição.
        val tr = rememberInfiniteTransition(label = "turn")
        val phase by tr.animateFloat(
            initialValue = 0f, targetValue = 1f,
            animationSpec = infiniteRepeatable(tween(900, easing = LinearEasing), RepeatMode.Restart),
            label = "blink",
        )
        val blink = if (phase < 0.5f) 1f else 0f
        val amber = Color(0xFFFFC107)
        val mirrorGray = Color(0xFF3C424B)
        val arc: @Composable (Int, Color, Float) -> Unit = { res, tint, alpha ->
            Image(painterResource(res), null, Modifier.fillMaxSize(), contentScale = ContentScale.Fit,
                alpha = alpha, colorFilter = androidx.compose.ui.graphics.ColorFilter.tint(tint))
        }
        when {                                   // ESQUERDA
            d.turnLeft -> arc(R.drawable.retrovisor_esquerdo, amber, blink)
            !d.doorFL  -> arc(R.drawable.retrovisor_esquerdo, mirrorGray, 1f)
        }
        when {                                   // DIREITA
            d.turnRight -> arc(R.drawable.retrovisor_direito, amber, blink)
            !d.doorFR   -> arc(R.drawable.retrovisor_direito, mirrorGray, 1f)
        }
        if (d.doorFL) layer(R.drawable.porta_dianteira_esquerda_aberta)
        if (d.doorFR) layer(R.drawable.porta_dianteira_direita_aberta)
        if (d.doorRL) layer(R.drawable.porta_traseira_esquerda_aberta)
        if (d.doorRR) layer(R.drawable.porta_traseira_direita_aberta)
        if (d.trunk) layer(R.drawable.porta_malas)
        if (d.sunroof) layer(R.drawable.teto_solar_aberto)
        if (d.winFL) layer(R.drawable.vidro_dianteiro_esquerdo_aberto)
        if (d.winFR) layer(R.drawable.vidro_dianteiro_direito_aberto)
        if (d.winRL) layer(R.drawable.vidro_traseiro_esquerdo_aberto)
        if (d.winRR) layer(R.drawable.vidro_traseiro_direito_aberto)
        if (d.locked) layer(R.drawable.trava) // trava.png = veículo TRANCADO (ondas de confirmação)
    }
}

// ── Gauge de arco 270° (estilo cockpit europeu) ───────────────────────────────
@Composable
private fun GaugeArc(pct: Float, colors: List<Color>, modifier: Modifier = Modifier) {
    Canvas(modifier) {
        val sw = 24.dp.toPx()
        val inset = sw / 2 + 4.dp.toPx()
        val arcSize = Size(size.width - inset * 2, size.height - inset * 2)
        val topLeft = Offset(inset, inset)
        val start = 135f
        val total = 270f
        drawArc(Color(0xFF23272F), start, total, false, topLeft, arcSize, style = Stroke(sw, cap = StrokeCap.Round))
        drawArc(
            brush = Brush.linearGradient(colors),
            startAngle = start, sweepAngle = total * pct.coerceIn(0f, 1f), useCenter = false,
            topLeft = topLeft, size = arcSize, style = Stroke(sw, cap = StrokeCap.Round)
        )
    }
}

// ════════════════════════════════════════════════════════════════════════════
//  LAYOUT 1 — "TESLA": minimalista, carro à esquerda + bateria + grid de viagem
// ════════════════════════════════════════════════════════════════════════════
@Composable
fun HomeTeslaLayout(d: HomeData, actions: @Composable RowScope.() -> Unit = {}, car: @Composable (Modifier) -> Unit = {}) {
    Box(
        Modifier
            .fillMaxSize()
            .background(Brush.verticalGradient(listOf(Color(0xFF101012), Color(0xFF000000))))
            .padding(horizontal = 40.dp, vertical = 8.dp)
    ) {
        Column(Modifier.fillMaxSize()) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text("HAVAL H6 PHEV", color = Color(0xFF8E8E93), fontSize = 22.sp, fontWeight = FontWeight.Medium, letterSpacing = 3.sp)
                Spacer(Modifier.weight(1f))
                Text("${d.outsideTempC}°", color = Color(0xFF8E8E93), fontSize = 24.sp)
                actions()
            }
            Spacer(Modifier.height(8.dp))
            Box(Modifier.fillMaxWidth().height(1.dp).background(Color(0xFF222226)))
            if (d.navActive) { Spacer(Modifier.height(10.dp)); TeslaNavBanner(d) }
            Spacer(Modifier.height(8.dp))
            Row(Modifier.fillMaxSize(), horizontalArrangement = Arrangement.spacedBy(36.dp)) {
                // ESQUERDA: carro + bateria
                Column(Modifier.weight(1f).fillMaxHeight()) {
                    car(Modifier.weight(1f).fillMaxWidth())
                    Row(verticalAlignment = Alignment.Bottom) {
                        Text("${d.socPct}%", color = Color.White, fontSize = 44.sp, fontWeight = FontWeight.SemiBold)
                        val sub = if (d.rangeEvKm > 0) "  · ${d.rangeEvKm} km autonomia EV" else if (d.modeEv) "  · modo EV" else ""
                        Text(sub, color = Color(0xFF8E8E93), fontSize = 24.sp, modifier = Modifier.padding(bottom = 6.dp))
                    }
                    Spacer(Modifier.height(8.dp))
                    Box(Modifier.fillMaxWidth().height(22.dp).clip(RoundedCornerShape(11.dp)).background(Color(0xFF2A2A2E))) {
                        Box(Modifier.fillMaxWidth(d.socPct / 100f).fillMaxHeight().clip(RoundedCornerShape(11.dp))
                            .background(Brush.horizontalGradient(listOf(Color(0xFF1EA672), Color(0xFF28C98A)))))
                    }
                }
                // DIREITA: viagem atual. Fontes encolhem um pouco quando há banner de
                // navegação (pra não espremer a grade de baixo).
                val nav = d.navActive
                Column(Modifier.weight(1.25f).fillMaxHeight()) {
                    Text("VIAGEM ATUAL", color = Color(0xFF8E8E93), fontSize = if (nav) 20.sp else 24.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 5.sp)
                    Spacer(Modifier.height(2.dp))
                    Row(verticalAlignment = Alignment.Bottom) {
                        Text(f1(d.distKm), color = Color.White, fontSize = if (nav) 66.sp else 96.sp, fontWeight = FontWeight.Bold)
                        Text(" km", color = Color(0xFF6B6B70), fontSize = if (nav) 32.sp else 44.sp, modifier = Modifier.padding(bottom = if (nav) 8.dp else 12.dp))
                    }
                    Spacer(Modifier.height(6.dp))
                    Row(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(24.dp)) {
                        TeslaCell(Modifier.weight(1f), "Tempo", d.timeStr, Color.White, null, nav = nav)
                        TeslaCell(Modifier.weight(1f), "Velocidade média", "${d.avgSpeedKmh} km/h", Color.White, null, nav = nav)
                        TeslaCell(Modifier.weight(1f), "Consumo", "${f1(d.kwh100)} kWh/100", Color(0xFF28C98A), null, nav = nav)
                    }
                    Row(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(24.dp)) {
                        TeslaCell(Modifier.weight(1f), "Energia usada", "${f1(d.netKwh)} kWh", Color.White, "regen ${f1(d.regenKwh)} kWh", Color(0xFF4DBBFF), nav = nav)
                        TeslaCell(Modifier.weight(1f), "Custo", "R$ ${f2(d.costBrl)}", Color.White, "R$ ${f3(d.costPerKm)} / km", Color(0xFF28C98A), nav = nav)
                        TeslaCell(Modifier.weight(1f), "Combustível", "${f1(d.fuelL)} L · EV", Color(0xFFFF5F1F), "SOC ${d.startSocPct}% → ${d.socPct}%", nav = nav)
                    }
                }
            }
        }
    }
}

@Composable
private fun TeslaCell(modifier: Modifier, label: String, value: String, valueColor: Color, sub: String?, subColor: Color = Color(0xFF8E8E93), nav: Boolean = false) {
    Column(modifier, verticalArrangement = Arrangement.Center) {
        Text(label, color = Color(0xFF8E8E93), fontSize = if (nav) 18.sp else 21.sp)
        Spacer(Modifier.height(if (nav) 2.dp else 4.dp))
        Text(value, color = valueColor, fontSize = if (nav) 32.sp else 40.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
        if (sub != null) {
            Spacer(Modifier.height(2.dp))
            Text(sub, color = subColor, fontSize = if (nav) 17.sp else 20.sp)
        }
    }
}

// ════════════════════════════════════════════════════════════════════════════
//  LAYOUT 2 — "EUROPEU": virtual cockpit, 2 gauges (eficiência | bateria)
// ════════════════════════════════════════════════════════════════════════════
@Composable
fun HomeEuropeanLayout(d: HomeData, actions: @Composable RowScope.() -> Unit = {}) {
    Box(
        Modifier
            .fillMaxSize()
            .background(Brush.linearGradient(listOf(Color(0xFF161A21), Color(0xFF080A0E))))
            .padding(horizontal = 40.dp, vertical = 8.dp)
    ) {
        Column(Modifier.fillMaxSize()) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text("HAVAL H6 PHEV  ·  ${if (d.modeEv) "MODO EV" else "HEV"}", color = Color(0xFF7D8794), fontSize = 22.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 3.sp)
                Spacer(Modifier.weight(1f))
                Text("${d.outsideTempC}°", color = Color(0xFF9AA6B4), fontSize = 24.sp)
                actions()
            }
            if (d.navActive) {
                Spacer(Modifier.height(6.dp))
                Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) { EuroNavBanner(d) }
            }
            Row(Modifier.fillMaxSize(), verticalAlignment = Alignment.CenterVertically) {
                // ESQUERDA: gauge eficiência
                Box(Modifier.weight(1f).fillMaxHeight(), contentAlignment = Alignment.Center) {
                    GaugeArc(d.effPct, listOf(Color(0xFF5EC8FF), Color(0xFF2D7DFF)), Modifier.fillMaxHeight(0.92f).aspectRatio(1f))
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(f1(d.kwh100), color = Color.White, fontSize = 108.sp, fontWeight = FontWeight.Bold)
                        Text("kWh / 100 km", color = Color(0xFF8D99A8), fontSize = 24.sp)
                        Spacer(Modifier.height(10.dp))
                        Text("EFICIÊNCIA", color = Color(0xFF5EC8FF), fontSize = 21.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 3.sp)
                    }
                }
                // CENTRO: viagem atual
                Column(Modifier.weight(1.1f).fillMaxHeight(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                    Text("VIAGEM ATUAL", color = Color(0xFF7D8794), fontSize = 20.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 4.sp)
                    Spacer(Modifier.height(6.dp))
                    Row(verticalAlignment = Alignment.Bottom) {
                        Text(f1(d.distKm), color = Color.White, fontSize = 68.sp, fontWeight = FontWeight.Bold)
                        Text(" km", color = Color(0xFF7D8794), fontSize = 30.sp, modifier = Modifier.padding(bottom = 8.dp))
                    }
                    Box(Modifier.fillMaxWidth(0.7f).height(1.dp).background(Color(0xFF2A2F38)))
                    Spacer(Modifier.height(16.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(40.dp)) {
                        EuroCell("Tempo", d.timeStr)
                        EuroCell("Vel. média", "${d.avgSpeedKmh}")
                    }
                    Spacer(Modifier.height(16.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(40.dp)) {
                        EuroCell("Energia líq.", "${f1(d.netKwh)} kWh")
                        EuroCell("Custo", "R$ ${f2(d.costBrl)}")
                    }
                    Spacer(Modifier.height(16.dp))
                    Text("R$ ${f3(d.costPerKm)} / km  ✓", color = Color(0xFF34D399), fontSize = 26.sp, fontWeight = FontWeight.SemiBold)
                    Spacer(Modifier.height(6.dp))
                    Text("SOC ${d.startSocPct}% → ${d.socPct}%   ·   regen ${f1(d.regenKwh)} kWh   ·   máx ${d.maxSpeedKmh} km/h",
                        color = Color(0xFF8D99A8), fontSize = 18.sp, textAlign = TextAlign.Center)
                }
                // DIREITA: gauge bateria
                Box(Modifier.weight(1f).fillMaxHeight(), contentAlignment = Alignment.Center) {
                    GaugeArc(d.socPct / 100f, listOf(Color(0xFF34D399), Color(0xFFFFB648)), Modifier.fillMaxHeight(0.92f).aspectRatio(1f))
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Row(verticalAlignment = Alignment.Bottom) {
                            Text("${d.socPct}", color = Color.White, fontSize = 116.sp, fontWeight = FontWeight.Bold)
                            Text("%", color = Color(0xFF8D99A8), fontSize = 50.sp, modifier = Modifier.padding(bottom = 10.dp))
                        }
                        Text(if (d.rangeEvKm > 0) "${d.rangeEvKm} km autonomia" else if (d.modeEv) "modo EV" else "híbrido", color = Color(0xFF8D99A8), fontSize = 24.sp)
                        Spacer(Modifier.height(10.dp))
                        Text("BATERIA", color = Color(0xFF34D399), fontSize = 21.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 3.sp)
                    }
                }
            }
        }
    }
}

@Composable
private fun EuroCell(label: String, value: String) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(label, color = Color(0xFF8D99A8), fontSize = 20.sp)
        Spacer(Modifier.height(4.dp))
        Text(value, color = Color.White, fontSize = 38.sp, fontWeight = FontWeight.SemiBold)
    }
}
