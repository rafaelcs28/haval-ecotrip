package br.com.redesurftank.ecotrip.ui.screens

import android.app.Activity
import android.content.pm.ActivityInfo
import android.view.WindowManager
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
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import br.com.redesurftank.ecotrip.managers.CarDataManager
import br.com.redesurftank.ecotrip.managers.V8SoundEngine
import br.com.redesurftank.ecotrip.models.CarConstants as CC
import kotlinx.coroutines.delay
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.sin

// Cluster estilo V8 esportivo (muscle car): tacômetro analógico + velocímetro
// digital + marcha + throttle bar + strip inferior. Landscape lock.
// Consome telemetria do V8SoundEngine (rpm, marcha, throttle) e leitura direta
// do CAN (velocidade, SOC, motor kW, temp). Fica cinemático — não é telemetria
// crua do painel de config; é pra "sentir" o V8 na tela do carro.

private val BG_DEEP = Color(0xFF0A0000)
private val BG_MID = Color(0xFF1A0000)
private val RED_HOT = Color(0xFFFF1E1E)
private val RED_GLOW = Color(0xFFFF5252)
private val RED_DIM = Color(0xFF7A0000)
private val TEXT = Color(0xFFF5F5F5)
private val TEXT_DIM = Color(0xFF808080)
private val AMBER = Color(0xFFFFA000)
private val REGEN = Color(0xFF3AB0FF)

@Composable
fun V8ClusterScreen(onBack: () -> Unit) {
    val ctx = LocalContext.current
    // Trava paisagem enquanto na tela; solta ao sair.
    DisposableEffect(Unit) {
        val act = ctx as? Activity
        val prevOrient = act?.requestedOrientation
        act?.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
        act?.window?.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        onDispose {
            act?.requestedOrientation = prevOrient ?: ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
            act?.window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }

    // Telemetria — refresh a 15 Hz. rpm/gear/throttle do V8Engine; resto do CAN.
    var rpm by remember { mutableStateOf(0) }
    var gear by remember { mutableStateOf(1) }
    var gearCount by remember { mutableStateOf(1) }
    var throttle by remember { mutableStateOf(0f) }
    var redline by remember { mutableStateOf(V8SoundEngine.redlineRpm.toInt()) }
    var speed by remember { mutableStateOf(0) }
    var soc by remember { mutableStateOf(0) }
    var motorKw by remember { mutableStateOf(0) }
    var outTemp by remember { mutableStateOf("--") }
    var fuelPct by remember { mutableStateOf(0) }
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
            speed = readFloat(car, CC.CAR_BASIC_VEHICLE_SPEED.value)?.roundToInt() ?: 0
            soc = readFloat(car, CC.CAR_EV_INFO_SOC_OF_BATTERY.value)?.roundToInt() ?: 0
            motorKw = readFloat(car, CC.CAR_EV_INFO_MOTOR_POWER.value)?.roundToInt() ?: 0
            fuelPct = readFloat(car, CC.CAR_BASIC_REMAIN_FUEL_PERCENTAGE.value)?.roundToInt() ?: 0
            outTemp = readFloat(car, CC.CAR_BASIC_OUTSIDE_TEMP.value)?.let { "${it.roundToInt()}°" } ?: "--"
            delay(70)
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Brush.radialGradient(colors = listOf(BG_MID, BG_DEEP), radius = 900f)),
    ) {
        // Header enxuto — só um "V8 CLUSTER" + botão voltar.
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("←", color = TEXT, fontSize = 22.sp, modifier = Modifier.clickable { onBack() }.padding(end = 12.dp))
            Text("V8 CLUSTER", color = RED_HOT, fontSize = 14.sp, fontWeight = FontWeight.Bold,
                letterSpacing = 4.sp)
            Spacer(Modifier.weight(1f))
            Text(if (gearCount > 1) "AUTO $gearCount SPD" else "LINEAR",
                color = TEXT_DIM, fontSize = 10.sp, letterSpacing = 2.sp)
        }

        // Layout principal: tacômetro | marcha central | velocímetro
        Row(
            modifier = Modifier.fillMaxSize().padding(top = 44.dp, bottom = 60.dp, start = 12.dp, end = 12.dp),
            horizontalArrangement = Arrangement.SpaceEvenly,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            // TACÔMETRO ARCO
            Box(modifier = Modifier.weight(1f).fillMaxHeight(), contentAlignment = Alignment.Center) {
                Tachometer(rpm = rpm, redline = redline, throttle = throttle,
                    modifier = Modifier.fillMaxSize())
            }
            // MARCHA CENTRAL (com "flash" de 300ms na troca)
            Box(
                modifier = Modifier.width(140.dp).fillMaxHeight(),
                contentAlignment = Alignment.Center,
            ) {
                val flashActive = System.currentTimeMillis() - gearFlipMs < 300
                GearIndicator(gear = gear, flash = flashActive, moving = speed > 0)
            }
            // VELOCÍMETRO DIGITAL
            Box(modifier = Modifier.weight(1f).fillMaxHeight(), contentAlignment = Alignment.Center) {
                SpeedoDigital(speed = speed)
            }
        }

        // BARRA DE THROTTLE
        Box(modifier = Modifier.align(Alignment.BottomCenter).fillMaxWidth().padding(bottom = 32.dp)) {
            ThrottleBar(throttle = throttle, modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp))
        }

        // STRIP INFERIOR — SOC · kW · combustível · temp
        Row(
            modifier = Modifier.align(Alignment.BottomCenter).fillMaxWidth()
                .background(Color.Black.copy(alpha = 0.6f)).padding(horizontal = 20.dp, vertical = 6.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            MetricPill(label = "BATERIA", value = "$soc", unit = "%", accent = if (soc <= 15) RED_HOT else TEXT)
            MetricPill(label = "MOTOR", value = "$motorKw", unit = "kW", accent = if (motorKw < 0) REGEN else TEXT)
            MetricPill(label = "GASOL.", value = "$fuelPct", unit = "%", accent = TEXT)
            MetricPill(label = "EXT.", value = outTemp, unit = "", accent = TEXT)
        }
    }
}

// ─── Componentes ────────────────────────────────────────────────────────────

@Composable
private fun Tachometer(rpm: Int, redline: Int, throttle: Float, modifier: Modifier = Modifier) {
    val redStartRatio = 0.85f
    val redStart = (redline * redStartRatio).toInt()
    // Cor da agulha por carga (verde → amarelo → vermelho)
    val load = throttle.coerceIn(-1f, 1f)
    val needleColor = when {
        load < -0.02f -> REGEN
        load < 0.35f -> Color(0xFF66DD66)
        load < 0.75f -> AMBER
        else -> RED_HOT
    }

    Canvas(modifier = modifier) {
        val cx = size.width / 2f
        val cy = size.height / 2f + size.height * 0.10f
        val radius = minOf(size.width, size.height) * 0.42f
        // Arco de 240° indo de -210° (esquerda-baixo) a +30° (direita-baixo).
        val startAngle = 150f       // Compose: 0° = 3h, cresce horário
        val sweep = 240f
        // Trilho principal escuro
        drawArc(
            color = Color(0xFF200000),
            startAngle = startAngle, sweepAngle = sweep, useCenter = false,
            style = Stroke(width = 22f, cap = StrokeCap.Round),
            topLeft = Offset(cx - radius, cy - radius),
            size = Size(radius * 2, radius * 2),
        )
        // Zona vermelha (redline)
        val redSweep = sweep * (1f - redStartRatio)
        drawArc(
            color = RED_DIM,
            startAngle = startAngle + sweep - redSweep, sweepAngle = redSweep, useCenter = false,
            style = Stroke(width = 22f, cap = StrokeCap.Butt),
            topLeft = Offset(cx - radius, cy - radius),
            size = Size(radius * 2, radius * 2),
        )
        // Preenchimento até o RPM atual (agulha viva)
        val fillRatio = (rpm.toFloat() / redline.toFloat()).coerceIn(0f, 1f)
        drawArc(
            color = needleColor.copy(alpha = 0.9f),
            startAngle = startAngle, sweepAngle = sweep * fillRatio, useCenter = false,
            style = Stroke(width = 22f, cap = StrokeCap.Round),
            topLeft = Offset(cx - radius, cy - radius),
            size = Size(radius * 2, radius * 2),
        )
        // Ticks a cada 1000rpm
        val ticks = redline / 1000
        for (i in 0..ticks) {
            val t = i.toFloat() / ticks
            val ang = Math.toRadians((startAngle + sweep * t).toDouble())
            val isMajor = i % 2 == 0
            val inner = radius - (if (isMajor) 34f else 22f)
            val outer = radius - 8f
            val x1 = cx + cos(ang) * inner; val y1 = cy + sin(ang) * inner
            val x2 = cx + cos(ang) * outer; val y2 = cy + sin(ang) * outer
            drawLine(
                color = if (i >= (ticks * redStartRatio).toInt()) RED_HOT else TEXT_DIM,
                start = Offset(x1.toFloat(), y1.toFloat()),
                end = Offset(x2.toFloat(), y2.toFloat()),
                strokeWidth = if (isMajor) 3.5f else 1.8f,
            )
        }
        // Agulha
        val needleAng = Math.toRadians((startAngle + sweep * fillRatio).toDouble())
        val nx = cx + cos(needleAng) * (radius - 12f)
        val ny = cy + sin(needleAng) * (radius - 12f)
        val bx = cx - cos(needleAng) * 22f
        val by = cy - sin(needleAng) * 22f
        drawLine(
            color = needleColor,
            start = Offset(bx.toFloat(), by.toFloat()),
            end = Offset(nx.toFloat(), ny.toFloat()),
            strokeWidth = 6f, cap = StrokeCap.Round,
        )
        // Cubo central
        drawCircle(color = Color(0xFF1A1A1A), radius = 16f, center = Offset(cx, cy))
        drawCircle(color = needleColor, radius = 5f, center = Offset(cx, cy))
    }
    // Overlay: número de RPM no centro-baixo
    Column(
        modifier = Modifier.fillMaxSize().padding(bottom = 24.dp),
        verticalArrangement = Arrangement.Bottom,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text("${rpm}", color = TEXT, fontSize = 34.sp, fontWeight = FontWeight.Bold,
            fontFamily = FontFamily.Monospace)
        Text("RPM × ${redline / 1000}k", color = TEXT_DIM, fontSize = 10.sp, letterSpacing = 2.sp)
    }
}

@Composable
private fun GearIndicator(gear: Int, flash: Boolean, moving: Boolean) {
    val bg = if (flash) RED_HOT else Color(0xFF120000)
    val fg = if (flash) Color.White else RED_GLOW
    val label = if (!moving && gear == 1) "N" else "$gear"
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text("MARCHA", color = TEXT_DIM, fontSize = 10.sp, letterSpacing = 3.sp)
        Spacer(Modifier.height(8.dp))
        Box(
            modifier = Modifier.size(120.dp)
                .clip(RoundedCornerShape(20.dp))
                .background(bg),
            contentAlignment = Alignment.Center,
        ) {
            Text(label, color = fg, fontSize = 84.sp, fontWeight = FontWeight.Black,
                fontFamily = FontFamily.Monospace)
        }
    }
}

@Composable
private fun SpeedoDigital(speed: Int) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            "%3d".format(speed), color = TEXT, fontSize = 96.sp, fontWeight = FontWeight.Black,
            fontFamily = FontFamily.Monospace,
        )
        Text("km/h", color = RED_HOT, fontSize = 14.sp, letterSpacing = 4.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun ThrottleBar(throttle: Float, modifier: Modifier = Modifier) {
    val absVal = kotlin.math.abs(throttle).coerceIn(0f, 1f)
    val isRegen = throttle < -0.02f
    val label = if (isRegen) "REGEN" else "ACELERADOR"
    val color = if (isRegen) REGEN else RED_HOT
    Column(modifier = modifier, horizontalAlignment = Alignment.Start) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(label, color = TEXT_DIM, fontSize = 10.sp, letterSpacing = 3.sp)
            Spacer(Modifier.weight(1f))
            Text("${(absVal * 100).roundToInt()}%", color = color, fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
        }
        Spacer(Modifier.height(4.dp))
        Box(modifier = Modifier.fillMaxWidth().height(10.dp).clip(RoundedCornerShape(4.dp))
            .background(Color(0xFF1A0000))) {
            Box(modifier = Modifier.fillMaxWidth(absVal).fillMaxHeight().background(color))
        }
    }
}

@Composable
private fun MetricPill(label: String, value: String, unit: String, accent: Color) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(label, color = TEXT_DIM, fontSize = 9.sp, letterSpacing = 2.sp)
        Row(verticalAlignment = Alignment.Bottom) {
            Text(value, color = accent, fontSize = 20.sp, fontWeight = FontWeight.Bold,
                fontFamily = FontFamily.Monospace)
            if (unit.isNotEmpty()) Text(" $unit", color = accent.copy(alpha = 0.7f), fontSize = 10.sp)
        }
    }
}

private fun readFloat(car: CarDataManager, key: String): Float? = try {
    car.fetchCurrent(key)?.trim()?.toFloatOrNull()
} catch (_: Exception) { null }
