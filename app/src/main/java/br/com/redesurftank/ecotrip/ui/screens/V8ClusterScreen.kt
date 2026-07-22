package br.com.redesurftank.ecotrip.ui.screens

import android.app.Activity
import android.content.pm.ActivityInfo
import android.view.WindowManager
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import br.com.redesurftank.ecotrip.managers.CarDataManager
import br.com.redesurftank.ecotrip.managers.V8SoundEngine
import br.com.redesurftank.ecotrip.models.CarConstants as CC
import kotlinx.coroutines.delay
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.sin

// V8 Cluster — direção 13a "Hellcat" (handoff docs/v8-cluster-13a).
// Landscape only, 1920×720 alvo. Tacômetro hero central + velocímetro dentro
// dele; potência à esquerda (barra bidirecional + chips V8/AWD); marcha à
// direita com "próxima em". Rodapé com SOC/GASOL barras + temp externa.

// ── Paleta 13a ──────────────────────────────────────────────────────────────
private val BG_A = Color(0xFF1A0808)      // centro-baixo do gradient
private val BG_B = Color(0xFF0A0A0A)
private val BG_C = Color(0xFF000000)
private val RED_SPORT = Color(0xFFEF4444)
private val ORANGE = Color(0xFFFB923C)
private val GREEN_ECO = Color(0xFF22C55E)
private val BLUE_REGEN = Color(0xFF38BDF8)
private val TEXT_PRI = Color(0xFFF5F5F5)
private val TEXT_SEC = Color(0xFF94A3B8)
private val TEXT_MUTED = Color(0xFF6B7280)
private val TRACK = Color(0xFF1C1C20)
private val TICK = Color(0xFF3A3A40)
private val TICK_HOT = Color(0xFF7F1D1D)
private val CARD_BG = Color(0xFF121216)
private val CARD_BORDER = Color(0x14FFFFFF)   // rgba(255,255,255,.08)

@Composable
fun V8ClusterScreen(onBack: () -> Unit) {
    val ctx = LocalContext.current
    // Landscape lock + tela ligada
    DisposableEffect(Unit) {
        val act = ctx as? Activity
        val prev = act?.requestedOrientation
        act?.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
        act?.window?.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        onDispose {
            act?.requestedOrientation = prev ?: ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
            act?.window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }

    // Telemetria — refresh 15Hz
    var rpm by remember { mutableStateOf(0) }
    var gear by remember { mutableStateOf(1) }
    var gearCount by remember { mutableStateOf(1) }
    var throttle by remember { mutableStateOf(0f) }
    var redline by remember { mutableStateOf(V8SoundEngine.redlineRpm.toInt()) }
    var shiftUpPct by remember { mutableStateOf(V8SoundEngine.shiftUpPct) }
    var speed by remember { mutableStateOf(0) }
    var soc by remember { mutableStateOf(0) }
    var motorKw by remember { mutableStateOf(0) }
    var outTemp by remember { mutableStateOf<Int?>(null) }
    var fuelPct by remember { mutableStateOf(0) }
    var iceOn by remember { mutableStateOf(false) }
    var awdActive by remember { mutableStateOf(false) }
    var gearFlipMs by remember { mutableStateOf(0L) }
    var lastGear by remember { mutableStateOf(1) }

    LaunchedEffect(Unit) {
        val car = CarDataManager.getInstance()
        while (true) {
            rpm = V8SoundEngine.displayRpm
            val g = V8SoundEngine.displayGear
            if (g != lastGear) { gearFlipMs = System.currentTimeMillis(); lastGear = g }
            gear = g
            gearCount = V8SoundEngine.gearCount
            throttle = V8SoundEngine.displayThrottle
            redline = V8SoundEngine.redlineRpm.toInt()
            shiftUpPct = V8SoundEngine.shiftUpPct
            speed = readFloat(car, CC.CAR_BASIC_VEHICLE_SPEED.value)?.roundToInt() ?: 0
            soc = readFloat(car, CC.CAR_EV_INFO_SOC_OF_BATTERY.value)?.roundToInt() ?: 0
            motorKw = readFloat(car, CC.CAR_EV_INFO_MOTOR_POWER.value)?.roundToInt() ?: 0
            fuelPct = readFloat(car, CC.CAR_BASIC_REMAIN_FUEL_PERCENTAGE.value)?.roundToInt() ?: 0
            outTemp = readFloat(car, CC.CAR_BASIC_OUTSIDE_TEMP.value)?.roundToInt()
            iceOn = (readFloat(car, CC.CAR_BASIC_ENGINE_SPEED.value) ?: 0f) > 100f
            val rear = readFloat(car, CC.CAR_EV_INFO_REAR_MOTOR_SPEED.value) ?: 0f
            awdActive = kotlin.math.abs(rear) > 50f
            delay(70)
        }
    }

    val regen = throttle < -0.02f
    val redlineStart = (redline * shiftUpPct).toInt()
    val inRedZone = rpm >= redlineStart && !regen
    val socCritical = soc in 1..15

    // Pulse para SOC crítico + glow redline
    val pulseTrans = rememberInfiniteTransition(label = "pulse")
    val pulse by pulseTrans.animateFloat(
        initialValue = 0.35f, targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(1600), RepeatMode.Reverse), label = "p",
    )
    val redlinePulse by pulseTrans.animateFloat(
        initialValue = 0.15f, targetValue = 0.35f,
        animationSpec = infiniteRepeatable(tween(1000), RepeatMode.Reverse), label = "rp",
    )
    val glowAlpha = if (inRedZone) redlinePulse else 0.0f

    // Root: gradient radial de fundo
    val bgBrush = Brush.radialGradient(
        colorStops = arrayOf(0.0f to BG_A, 0.55f to BG_B, 1.0f to BG_C),
        radius = 900f,
    )
    Box(modifier = Modifier.fillMaxSize().background(bgBrush)) {
        // Topo enxuto: só voltar + tag
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("←", color = TEXT_PRI, fontSize = 22.sp,
                modifier = Modifier.clickable { onBack() }.padding(end = 16.dp))
            Text("V8 CLUSTER", color = RED_SPORT, fontSize = 12.sp,
                letterSpacing = 4.sp, fontWeight = FontWeight.Bold)
        }

        // Painel esquerdo — POTÊNCIA (x: 70-470 / do handoff)
        LeftPanel(
            motorKw = motorKw,
            regen = regen,
            iceOn = iceOn,
            awdActive = awdActive,
            modifier = Modifier
                .align(Alignment.CenterStart)
                .padding(start = 44.dp)
                .width(340.dp),
        )

        // Tacômetro central hero
        Box(
            modifier = Modifier.align(Alignment.Center).size(560.dp),
            contentAlignment = Alignment.Center,
        ) {
            Tacho(
                rpm = rpm, redline = redline, redStartRatio = shiftUpPct,
                regen = regen, glowAlpha = glowAlpha,
                modifier = Modifier.fillMaxSize(),
            )
            // Cluster digital central (velocímetro + rpm)
            CenterDigital(speed = speed, rpm = rpm, inRedZone = inRedZone, regen = regen)
        }

        // Painel direito — MARCHA (x: 1450+ / handoff)
        RightPanel(
            gear = gear, gearCount = gearCount, rpm = rpm, redline = redline,
            shiftUpPct = shiftUpPct,
            gearFlipMs = gearFlipMs, moving = speed > 0,
            modifier = Modifier
                .align(Alignment.CenterEnd)
                .padding(end = 44.dp)
                .width(280.dp),
        )

        // Rodapé direito — SOC + GASOL.
        Column(
            modifier = Modifier.align(Alignment.BottomEnd).padding(end = 44.dp, bottom = 24.dp).width(340.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            LinearRow(
                label = "SOC",
                value = "$soc%",
                pct = soc / 100f,
                color = if (socCritical) RED_SPORT else GREEN_ECO,
                textColor = if (socCritical) RED_SPORT else TEXT_PRI,
                pulse = if (socCritical) pulse else 1f,
            )
            LinearRow(
                label = "GASOL.",
                value = "$fuelPct%",
                pct = fuelPct / 100f,
                color = ORANGE,
                textColor = TEXT_PRI,
                pulse = 1f,
            )
        }

        // Rodapé esquerdo — temperatura externa
        Row(
            modifier = Modifier.align(Alignment.BottomStart).padding(start = 44.dp, bottom = 24.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                outTemp?.let { "${it}°" } ?: "--°",
                color = TEXT_SEC, fontSize = 26.sp,
                fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Medium,
            )
            Spacer(Modifier.width(10.dp))
            Text("EXTERNA", color = TEXT_MUTED, fontSize = 11.sp, letterSpacing = 2.sp,
                fontWeight = FontWeight.Bold)
        }
    }
}

// ─── Tacômetro (arco central hero) ──────────────────────────────────────────

@Composable
private fun Tacho(
    rpm: Int, redline: Int, redStartRatio: Float, regen: Boolean, glowAlpha: Float,
    modifier: Modifier = Modifier,
) {
    // Escala fixa 0..(redline + 800) arredondado pro próximo múltiplo de 1000 (headroom).
    val scaleMax = (((redline + 800) / 1000) * 1000).coerceAtLeast(redline)

    Canvas(modifier = modifier) {
        val cx = size.width / 2f
        val cy = size.height / 2f
        val r = minOf(size.width, size.height) / 2f - 20f
        val strokeArc = r * 0.056f       // ~16px equivalente
        val startDeg = 150f
        val sweepDeg = 240f

        // Glow atrás do centro (redline pulse)
        if (glowAlpha > 0f) {
            drawCircle(color = RED_SPORT.copy(alpha = glowAlpha), radius = r * 0.55f, center = Offset(cx, cy))
        }

        // 1) Track completo
        drawArc(
            color = TRACK,
            startAngle = startDeg, sweepAngle = sweepDeg, useCenter = false,
            style = Stroke(width = strokeArc, cap = StrokeCap.Round),
            topLeft = Offset(cx - r, cy - r),
            size = Size(r * 2, r * 2),
        )
        // 2) Zona vermelha (redStartRatio * scaleMax .. scaleMax)
        val redStartRpm = (scaleMax * redStartRatio).toInt()
        val redSweep = sweepDeg * (1f - redStartRpm / scaleMax.toFloat())
        drawArc(
            color = RED_SPORT.copy(alpha = 0.85f),
            startAngle = startDeg + sweepDeg - redSweep,
            sweepAngle = redSweep, useCenter = false,
            style = Stroke(width = strokeArc, cap = StrokeCap.Butt),
            topLeft = Offset(cx - r, cy - r),
            size = Size(r * 2, r * 2),
        )
        // 3) Fill do rpm ao vivo — gradient laranja→vermelho no sentido do arco
        val fillRatio = (rpm.toFloat() / scaleMax.toFloat()).coerceIn(0f, 1f)
        val fillSweep = sweepDeg * fillRatio
        if (fillSweep > 0.5f) {
            val brush = if (regen) {
                Brush.linearGradient(colors = listOf(BLUE_REGEN, BLUE_REGEN))
            } else {
                Brush.sweepGradient(
                    colors = listOf(ORANGE, ORANGE, RED_SPORT, RED_SPORT),
                    center = Offset(cx, cy),
                )
            }
            drawArc(
                brush = brush,
                startAngle = startDeg, sweepAngle = fillSweep, useCenter = false,
                style = Stroke(width = strokeArc, cap = StrokeCap.Round),
                topLeft = Offset(cx - r, cy - r),
                size = Size(r * 2, r * 2),
            )
        }
        // 4) Ticks a cada 1000 rpm (linha r-28→r do stroke)
        val ticks = scaleMax / 1000
        val tickInner = r - strokeArc - 6f
        val tickOuter = r - 6f
        for (i in 0..ticks) {
            val t = i.toFloat() / ticks
            val ang = Math.toRadians((startDeg + sweepDeg * t).toDouble())
            val x1 = cx + cos(ang) * tickInner; val y1 = cy + sin(ang) * tickInner
            val x2 = cx + cos(ang) * tickOuter; val y2 = cy + sin(ang) * tickOuter
            val col = if (i >= (ticks * redStartRatio).toInt()) TICK_HOT else TICK
            drawLine(
                color = col,
                start = Offset(x1.toFloat(), y1.toFloat()),
                end = Offset(x2.toFloat(), y2.toFloat()),
                strokeWidth = 4f,
            )
        }
        // 5) Agulha flutuante (sem hub) — segmento radial de r175→r258 no ângulo do rpm
        val needleAng = Math.toRadians((startDeg + sweepDeg * fillRatio).toDouble())
        val innerN = r * 0.61f   // ~175/290
        val outerN = r * 0.90f   // ~258/290
        val ncol = if (regen) BLUE_REGEN else TEXT_PRI
        val nx1 = cx + cos(needleAng) * innerN
        val ny1 = cy + sin(needleAng) * innerN
        val nx2 = cx + cos(needleAng) * outerN
        val ny2 = cy + sin(needleAng) * outerN
        drawLine(
            color = ncol,
            start = Offset(nx1.toFloat(), ny1.toFloat()),
            end = Offset(nx2.toFloat(), ny2.toFloat()),
            strokeWidth = 8f, cap = StrokeCap.Round,
        )
    }
    // Labels da escala (0..N) por cima do canvas
    ScaleLabels(scaleMax = scaleMax, redStartRatio = redStartRatio)
}

@Composable
private fun ScaleLabels(scaleMax: Int, redStartRatio: Float) {
    val ticks = scaleMax / 1000
    val startDeg = 150f
    val sweepDeg = 240f
    // Colocamos labels usando Canvas (mais simples que posicionar Text absolutamente).
    Canvas(modifier = Modifier.fillMaxSize()) {
        val cx = size.width / 2f
        val cy = size.height / 2f
        val r = minOf(size.width, size.height) / 2f - 20f
        val labelR = r * 0.79f   // ~228/290
        val paint = android.graphics.Paint().apply {
            color = 0xFF6B7280.toInt()
            textSize = 26f
            textAlign = android.graphics.Paint.Align.CENTER
            typeface = android.graphics.Typeface.create(android.graphics.Typeface.MONOSPACE,
                android.graphics.Typeface.BOLD)
            isAntiAlias = true
        }
        val paintHot = android.graphics.Paint(paint).apply { color = 0xFFEF4444.toInt() }
        val nc = drawContext.canvas.nativeCanvas
        for (i in 0..ticks) {
            val t = i.toFloat() / ticks
            val ang = Math.toRadians((startDeg + sweepDeg * t).toDouble())
            val x = cx + cos(ang) * labelR
            val y = cy + sin(ang) * labelR + 9f   // baseline offset
            val p = if (i >= (ticks * redStartRatio).toInt()) paintHot else paint
            nc.drawText("$i", x.toFloat(), y.toFloat(), p)
        }
    }
}

@Composable
private fun CenterDigital(speed: Int, rpm: Int, inRedZone: Boolean, regen: Boolean) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier.offset(y = 20.dp),
    ) {
        // Velocidade — 118px equivalente (~92sp na tela do carro)
        Text(
            "%d".format(speed), color = TEXT_PRI,
            fontSize = 96.sp, fontWeight = FontWeight.Bold,
            fontFamily = FontFamily.Monospace,
            letterSpacing = (-4).sp,
        )
        Text("KM/H", color = TEXT_MUTED, fontSize = 14.sp, letterSpacing = 5.sp,
            fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(8.dp))
        // RPM num
        Row(verticalAlignment = Alignment.Bottom) {
            Text(
                "%,d".format(rpm).replace(",", "."), // 5.100 formatado pt
                color = if (regen) BLUE_REGEN else if (inRedZone) RED_SPORT else TEXT_PRI,
                fontSize = 22.sp, fontWeight = FontWeight.SemiBold,
                fontFamily = FontFamily.Monospace,
            )
            Spacer(Modifier.width(6.dp))
            Text("RPM", color = TEXT_MUTED, fontSize = 12.sp, letterSpacing = 2.sp,
                fontWeight = FontWeight.Bold, modifier = Modifier.padding(bottom = 3.dp))
        }
    }
}

// ─── Painel esquerdo — POTÊNCIA + chips V8/AWD ───────────────────────────────

@Composable
private fun LeftPanel(motorKw: Int, regen: Boolean, iceOn: Boolean, awdActive: Boolean,
                     modifier: Modifier = Modifier) {
    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Text("POTÊNCIA", color = TEXT_MUTED, fontSize = 12.sp, letterSpacing = 3.sp,
            fontWeight = FontWeight.Bold)
        Row(verticalAlignment = Alignment.Bottom) {
            Text(
                (if (motorKw >= 0) "+$motorKw" else "$motorKw"),
                color = TEXT_PRI, fontSize = 60.sp, fontWeight = FontWeight.Light,
                fontFamily = FontFamily.Monospace, letterSpacing = (-2).sp,
            )
            Spacer(Modifier.width(6.dp))
            Text("kW", color = TEXT_MUTED, fontSize = 20.sp, modifier = Modifier.padding(bottom = 8.dp),
                fontWeight = FontWeight.Medium)
        }
        // Barra bidirecional — zero em 33% do width (range -80..+160)
        PowerBar(motorKw = motorKw, regen = regen)
        // Sub-labels
        Row(modifier = Modifier.fillMaxWidth()) {
            Text("REGEN −80", color = BLUE_REGEN, fontSize = 11.sp, letterSpacing = 1.sp,
                fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.weight(1f))
            Text("+160", color = TEXT_MUTED, fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
        }
        Spacer(Modifier.height(4.dp))
        // Chips V8/EV + AWD
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            IceChip(iceOn = iceOn)
            AwdChip(awdActive = awdActive)
        }
    }
}

@Composable
private fun PowerBar(motorKw: Int, regen: Boolean) {
    val minKw = -80f
    val maxKw = 160f
    val zeroPct = -minKw / (maxKw - minKw)    // = 0.333
    val curPct = ((motorKw - minKw) / (maxKw - minKw)).coerceIn(0f, 1f)
    Canvas(modifier = Modifier.fillMaxWidth().height(14.dp)) {
        val w = size.width; val h = size.height; val rad = h / 2f
        // Track
        drawRoundRect(
            color = Color(0xFF16161A),
            size = Size(w, h),
            cornerRadius = androidx.compose.ui.geometry.CornerRadius(rad, rad),
        )
        val zeroX = w * zeroPct
        val curX = w * curPct
        if (curPct >= zeroPct) {
            // Positivo: gradient laranja→vermelho, do zero pra direita
            val fillW = curX - zeroX
            if (fillW > 0.5f) {
                val brush = Brush.horizontalGradient(
                    colors = listOf(ORANGE, RED_SPORT), startX = zeroX, endX = zeroX + fillW,
                )
                drawRoundRect(
                    brush = brush,
                    topLeft = Offset(zeroX, 0f),
                    size = Size(fillW, h),
                    cornerRadius = androidx.compose.ui.geometry.CornerRadius(rad, rad),
                )
            }
        } else {
            // Negativo (regen): azul, do zero pra esquerda
            val fillW = zeroX - curX
            drawRoundRect(
                color = BLUE_REGEN,
                topLeft = Offset(curX, 0f),
                size = Size(fillW, h),
                cornerRadius = androidx.compose.ui.geometry.CornerRadius(rad, rad),
            )
        }
        // Marcador do zero
        drawLine(
            color = Color.White.copy(alpha = 0.3f),
            start = Offset(zeroX, -2f),
            end = Offset(zeroX, h + 2f),
            strokeWidth = 3f,
        )
    }
}

@Composable
private fun IceChip(iceOn: Boolean) {
    val label = if (iceOn) "V8 ATIVO" else "EV"
    val sub = if (iceOn) "combustão ligada" else "combustão desligada"
    val accent = if (iceOn) RED_SPORT else GREEN_ECO
    val bg = if (iceOn) RED_SPORT.copy(alpha = 0.1f) else CARD_BG
    val border = if (iceOn) RED_SPORT.copy(alpha = 0.4f) else CARD_BORDER
    ChipBox(label = label, sub = sub, accent = accent, bg = bg, border = border, dim = false)
}

@Composable
private fun AwdChip(awdActive: Boolean) {
    val sub = if (awdActive) "eixo traseiro on" else "eixo traseiro off"
    ChipBox(label = "AWD", sub = sub, accent = TEXT_PRI, bg = CARD_BG,
        border = CARD_BORDER, dim = !awdActive)
}

@Composable
private fun ChipBox(label: String, sub: String, accent: Color, bg: Color, border: Color,
                   dim: Boolean) {
    val alpha = if (dim) 0.55f else 1f
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(14.dp))
            .background(bg)
            .padding(1.dp)                        // "borda" simulada via padding
            .background(border, RoundedCornerShape(14.dp))
            .padding(1.dp)
            .background(bg, RoundedCornerShape(13.dp))
            .padding(horizontal = 14.dp, vertical = 10.dp),
    ) {
        Column {
            Text(label, color = accent.copy(alpha = alpha),
                fontSize = 11.sp, letterSpacing = 2.5.sp, fontWeight = FontWeight.Bold)
            Text(sub, color = TEXT_SEC.copy(alpha = alpha), fontSize = 12.sp,
                fontWeight = FontWeight.Medium)
        }
    }
}

// ─── Painel direito — MARCHA + próxima ───────────────────────────────────────

@Composable
private fun RightPanel(gear: Int, gearCount: Int, rpm: Int, redline: Int,
                       shiftUpPct: Float, gearFlipMs: Long, moving: Boolean,
                       modifier: Modifier = Modifier) {
    val flashActive = System.currentTimeMillis() - gearFlipMs < 300
    val label = when {
        gearCount <= 1 -> "D"
        !moving && gear == 1 -> "N"
        else -> "$gear"
    }
    val nextHint = when {
        gearCount <= 1 -> null
        gear >= gearCount -> null   // última: sem próxima
        else -> gear + 1
    }
    // "Próxima em X" — velocidade a que o upshift acontecerá, calculada de ratio×speedToRpm
    val nextInRpm = (redline * shiftUpPct).toInt()

    Column(modifier = modifier, horizontalAlignment = Alignment.End) {
        Text("MARCHA", color = TEXT_MUTED, fontSize = 12.sp, letterSpacing = 3.sp,
            fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(8.dp))
        Row(verticalAlignment = Alignment.Bottom) {
            Text(
                label,
                color = if (flashActive) Color.White else TEXT_PRI,
                fontSize = 168.sp, fontWeight = FontWeight.Bold,
                fontFamily = FontFamily.Monospace,
                letterSpacing = (-6).sp,
            )
            if (nextHint != null) {
                Spacer(Modifier.width(6.dp))
                Text(
                    "$nextHint",
                    color = TICK, fontSize = 46.sp, fontWeight = FontWeight.Normal,
                    fontFamily = FontFamily.Monospace,
                    modifier = Modifier.padding(bottom = 12.dp),
                )
            }
        }
        if (nextHint != null) {
            Text("PRÓXIMA EM ${formatRpm(nextInRpm)}",
                color = TEXT_MUTED, fontSize = 11.sp, letterSpacing = 1.5.sp,
                fontWeight = FontWeight.SemiBold, textAlign = TextAlign.End)
        }
    }
}

// ─── Rodapé: linhas SOC / GASOL. ─────────────────────────────────────────────

@Composable
private fun LinearRow(label: String, value: String, pct: Float, color: Color,
                     textColor: Color, pulse: Float) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Text(label, color = TEXT_MUTED, fontSize = 12.sp, letterSpacing = 2.sp,
            fontWeight = FontWeight.Bold, modifier = Modifier.width(80.dp))
        Box(
            modifier = Modifier.weight(1f).height(10.dp).clip(RoundedCornerShape(5.dp))
                .background(TRACK),
        ) {
            Box(modifier = Modifier.fillMaxWidth(pct.coerceIn(0f, 1f))
                .fillMaxHeight().background(color.copy(alpha = pulse)))
        }
        Spacer(Modifier.width(12.dp))
        Text(value, color = textColor.copy(alpha = pulse),
            fontSize = 22.sp, fontFamily = FontFamily.Monospace,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.width(80.dp), textAlign = TextAlign.End)
    }
}

private fun formatRpm(v: Int) = "%,d".format(v).replace(",", ".")

private fun readFloat(car: CarDataManager, key: String): Float? = try {
    car.fetchCurrent(key)?.trim()?.toFloatOrNull()
} catch (_: Exception) { null }
