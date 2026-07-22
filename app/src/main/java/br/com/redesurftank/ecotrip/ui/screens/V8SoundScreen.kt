package br.com.redesurftank.ecotrip.ui.screens

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import br.com.redesurftank.ecotrip.managers.V8SoundEngine
import br.com.redesurftank.ecotrip.models.SharedPreferencesKeys as K
import br.com.redesurftank.ecotrip.ui.theme.*
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import kotlinx.coroutines.delay
import kotlin.math.roundToInt

// Tela dedicada ao Som V8. Ativa o efeito, mostra a rotação simulada ao vivo
// (tacômetro) e expõe todos os parâmetros como sliders pra tunar no carro até o
// ponto ideal. Ligou aqui → começa a sair o som pelas caixas.
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun V8SoundScreen(onBack: () -> Unit) {
    val ctx = LocalContext.current
    val accent = AccentOrange

    LaunchedEffect(Unit) { V8SoundEngine.loadConfig(ctx) }

    var enabled by remember { mutableStateOf(V8SoundEngine.enabled) }

    // Telemetria ao vivo pro tacômetro
    var rpm by remember { mutableStateOf(0) }
    var regen by remember { mutableStateOf(false) }
    var throttle by remember { mutableStateOf(0f) }
    var gearNow by remember { mutableStateOf(1) }
    LaunchedEffect(enabled) {
        while (true) {
            rpm = V8SoundEngine.displayRpm
            regen = V8SoundEngine.displayRegen
            throttle = V8SoundEngine.displayThrottle
            gearNow = V8SoundEngine.displayGear
            delay(70)
        }
    }

    // Estado dos sliders (semente = valor atual do engine)
    var masterVol  by remember { mutableStateOf(V8SoundEngine.masterVol) }
    var idleRpm    by remember { mutableStateOf(V8SoundEngine.idleRpm) }
    var redlineRpm by remember { mutableStateOf(V8SoundEngine.redlineRpm) }
    var powerFull  by remember { mutableStateOf(V8SoundEngine.powerFullKw) }
    var speedToRpm by remember { mutableStateOf(V8SoundEngine.speedToRpm) }
    var revBoost   by remember { mutableStateOf(V8SoundEngine.revBoost) }
    var rumble     by remember { mutableStateOf(V8SoundEngine.rumble) }
    var loadBright by remember { mutableStateOf(V8SoundEngine.loadBright) }
    var regenVol   by remember { mutableStateOf(V8SoundEngine.regenVol) }
    var crackle    by remember { mutableStateOf(V8SoundEngine.crackle) }
    var popAccel   by remember { mutableStateOf(V8SoundEngine.popAccel) }
    var rasp       by remember { mutableStateOf(V8SoundEngine.rasp) }
    var toneHz     by remember { mutableStateOf(V8SoundEngine.toneHz) }
    var gearCount  by remember { mutableStateOf(V8SoundEngine.gearCount) }
    var shiftUpPct by remember { mutableStateOf(V8SoundEngine.shiftUpPct) }
    var kickdown   by remember { mutableStateOf(V8SoundEngine.kickdown) }
    var preset     by remember { mutableStateOf(V8SoundEngine.currentPreset) }

    ClaudeScreen(title = "Som V8", onBack = onBack, accent = accent, spacing = 16.dp) {
        Column(
            modifier = Modifier
                .weight(1f)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            // ── Ativar + tacômetro ────────────────────────────────────────────
            Column(
                modifier = Modifier.fillMaxWidth().claudeCard(accent).padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column {
                        Text("MOTOR V8", fontSize = 15.sp, fontWeight = FontWeight.Bold, color = accent, letterSpacing = 1.sp)
                        Text(
                            if (enabled) "Ligado — som pelas caixas" else "Desligado",
                            fontSize = 11.sp, color = TextSecondary,
                        )
                    }
                    Switch(
                        checked = enabled,
                        onCheckedChange = {
                            enabled = it
                            V8SoundEngine.setEnabled(ctx, it)
                        },
                        colors = SwitchDefaults.colors(
                            checkedThumbColor = accent,
                            checkedTrackColor = accent.copy(alpha = 0.4f),
                        ),
                    )
                }

                // Tacômetro
                Tachometer(rpm = rpm, redline = redlineRpm.toInt(), regen = regen, throttle = throttle, accent = accent)
                // Marcha atual (só mostra se câmbio virtual habilitado)
                if (gearCount > 1) {
                    Text(
                        "Marcha: ${gearNow}ª / $gearCount",
                        color = accent, fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.padding(top = 4.dp),
                    )
                }
            }

            // ── Presets de motor ────────────────────────────────────────────────
            ParamCard(title = "MOTOR (PRESET)") {
                FlowRow(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    V8SoundEngine.PRESETS.forEach { p ->
                        val sel = p.name == preset
                        Box(
                            modifier = Modifier
                                .background(
                                    if (sel) accent else SurfaceDeep,
                                    RoundedCornerShape(20.dp),
                                )
                                .border(
                                    1.dp,
                                    if (sel) accent else accent.copy(alpha = 0.25f),
                                    RoundedCornerShape(20.dp),
                                )
                                .clickable {
                                    V8SoundEngine.applyPreset(ctx, p)
                                    preset = p.name
                                    // re-semeia os sliders com o preset aplicado
                                    idleRpm = V8SoundEngine.idleRpm
                                    redlineRpm = V8SoundEngine.redlineRpm
                                    rumble = V8SoundEngine.rumble
                                    loadBright = V8SoundEngine.loadBright
                                    crackle = V8SoundEngine.crackle
                                    popAccel = V8SoundEngine.popAccel
                                    rasp = V8SoundEngine.rasp
                                    toneHz = V8SoundEngine.toneHz
                                    revBoost = V8SoundEngine.revBoost
                                    regenVol = V8SoundEngine.regenVol
                                }
                                .padding(horizontal = 14.dp, vertical = 8.dp),
                        ) {
                            Text(
                                p.name,
                                fontSize = 12.sp,
                                fontWeight = FontWeight.Bold,
                                color = if (sel) Color.Black else TextSecondary,
                            )
                        }
                    }
                }
                Text(
                    "O preset define o caráter (ordem de disparo, ronco, estalos, timbre). Volume, potência e rotação-por-km/h ficam como você calibrou.",
                    fontSize = 11.sp, color = TextSecondary,
                )
            }

            // ── Ajustes ────────────────────────────────────────────────────────
            ParamCard(title = "MIX") {
                ParamSlider("Volume geral", masterVol, 0f, 1f, accent, { pct(it) }) {
                    masterVol = it; V8SoundEngine.setParam(ctx, K.V8_MASTER_VOL, it)
                }
                ParamSlider("Volume no regen (freio-motor)", regenVol, 0f, 1f, accent, { pct(it) }) {
                    regenVol = it; V8SoundEngine.setParam(ctx, K.V8_REGEN_VOL, it)
                }
                ParamSlider("Timbre (grave ↔ brilhante)", toneHz, 800f, 6000f, accent, { "${it.roundToInt()} Hz" }) {
                    toneHz = it; V8SoundEngine.setParam(ctx, K.V8_TONE_HZ, it)
                }
            }

            ParamCard(title = "ESCAPAMENTO") {
                ParamSlider("Rasp / grit (mexido)", rasp, 0f, 1f, accent, { pct(it) }) {
                    rasp = it; V8SoundEngine.setParam(ctx, K.V8_RASP, it)
                }
                ParamSlider("Ronco / lope", rumble, 0f, 1.5f, accent, { dec(it) }) {
                    rumble = it; V8SoundEngine.setParam(ctx, K.V8_RUMBLE, it)
                }
                ParamSlider("Agressividade sob carga", loadBright, 0f, 1f, accent, { pct(it) }) {
                    loadBright = it; V8SoundEngine.setParam(ctx, K.V8_LOAD_BRIGHT, it)
                }
                ParamSlider("Estalos ao soltar (overrun)", crackle, 0f, 1f, accent, { pct(it) }) {
                    crackle = it; V8SoundEngine.setParam(ctx, K.V8_CRACKLE, it)
                }
                ParamSlider("Estalos ao acelerar forte", popAccel, 0f, 1f, accent, { pct(it) }) {
                    popAccel = it; V8SoundEngine.setParam(ctx, K.V8_POP_ACCEL, it)
                }
            }

            ParamCard(title = "ROTAÇÃO") {
                ParamSlider("Marcha lenta", idleRpm, 400f, 1200f, accent, { "${it.roundToInt()} rpm" }) {
                    idleRpm = it; V8SoundEngine.setParam(ctx, K.V8_IDLE_RPM, it)
                }
                ParamSlider("Corte (redline)", redlineRpm, 4000f, 8000f, accent, { "${it.roundToInt()} rpm" }) {
                    redlineRpm = it; V8SoundEngine.setParam(ctx, K.V8_REDLINE_RPM, it)
                }
                ParamSlider("Rotação por km/h", speedToRpm, 10f, 90f, accent, { "${it.roundToInt()}" }) {
                    speedToRpm = it; V8SoundEngine.setParam(ctx, K.V8_SPEED_TO_RPM, it)
                }
                ParamSlider("Empurrão do acelerador", revBoost, 0f, 5000f, accent, { "${it.roundToInt()} rpm" }) {
                    revBoost = it; V8SoundEngine.setParam(ctx, K.V8_REV_BOOST, it)
                }
                ParamSlider("Potência p/ acelerador no fundo", powerFull, 30f, 200f, accent, { "${it.roundToInt()} kW" }) {
                    powerFull = it; V8SoundEngine.setParam(ctx, K.V8_POWER_FULL_KW, it)
                }
            }

            ParamCard(title = "CÂMBIO VIRTUAL") {
                // Marchas do câmbio automático simulado. 1 = câmbio único linear
                // (comportamento antigo — usa só "Rotação por km/h"). 2..8 =
                // marchas com ratios decrescentes; upshift automático quando
                // rpm cruza o "Ponto de upshift" do redline.
                ParamSlider("Marchas", gearCount.toFloat(), 1f, 8f, accent,
                    { "${it.roundToInt()}" + if (it.roundToInt() == 1) " (linear)" else "" }) {
                    val n = it.roundToInt().coerceIn(1, 8)
                    if (n != gearCount) { gearCount = n; V8SoundEngine.setGearCount(ctx, n) }
                }
                ParamSlider("Ponto de upshift", shiftUpPct, 0.60f, 0.98f, accent, { pct(it) }) {
                    shiftUpPct = it; V8SoundEngine.setParam(ctx, K.V8_SHIFT_UP_PCT, it)
                }
                // Kickdown: switch on/off.
                Row(
                    modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text("Kickdown (desce marcha ao pisar fundo)",
                        color = TextPrimary, fontSize = 13.sp,
                        modifier = Modifier.weight(1f))
                    Switch(checked = kickdown, onCheckedChange = {
                        kickdown = it; V8SoundEngine.setKickdown(ctx, it)
                    })
                }
            }

            Text(
                "Ligue e dirija: acelerar sobe a rotação e abre o ronco; soltar/regenerar cai pra marcha lenta com estalos de freio-motor. Ajuste tudo aqui ao vivo.",
                fontSize = 11.sp, color = TextSecondary, modifier = Modifier.padding(bottom = 8.dp),
            )
        }
    }
}

private fun pct(v: Float) = "${(v * 100).roundToInt()}%"
private fun dec(v: Float) = String.format("%.2f", v)

@Composable
private fun Tachometer(rpm: Int, redline: Int, regen: Boolean, throttle: Float, accent: Color) {
    val frac = (rpm.toFloat() / redline.coerceAtLeast(1)).coerceIn(0f, 1f)
    val near = frac > 0.85f
    val barColor = when {
        regen -> PlasmaBlue
        near  -> Color(0xFFFF4444)
        else  -> accent
    }
    Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxWidth()) {
        Box(contentAlignment = Alignment.Center, modifier = Modifier.fillMaxWidth().height(150.dp)) {
            Canvas(modifier = Modifier.fillMaxWidth().height(150.dp)) {
                val stroke = 16.dp.toPx()
                val pad = stroke / 2 + 4.dp.toPx()
                val arcSize = Size(size.width - pad * 2, (size.height - pad) * 2)
                val topLeft = Offset(pad, size.height - pad - arcSize.height / 2)
                // trilho
                drawArc(
                    color = accent.copy(alpha = 0.15f), startAngle = 180f, sweepAngle = 180f,
                    useCenter = false, topLeft = topLeft, size = arcSize,
                    style = Stroke(width = stroke, cap = StrokeCap.Round),
                )
                // preenchido
                drawArc(
                    color = barColor, startAngle = 180f, sweepAngle = 180f * frac,
                    useCenter = false, topLeft = topLeft, size = arcSize,
                    style = Stroke(width = stroke, cap = StrokeCap.Round),
                )
            }
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Text("$rpm", fontSize = 46.sp, fontWeight = FontWeight.ExtraBold, color = barColor)
                Text("RPM", fontSize = 12.sp, color = TextSecondary, letterSpacing = 2.sp)
            }
        }
        Text(
            when {
                regen -> "REGEN — freio-motor"
                throttle > 0.03f -> "ACELERANDO ${(throttle * 100).roundToInt()}%"
                else -> "marcha lenta"
            },
            fontSize = 12.sp, fontWeight = FontWeight.Bold, color = barColor,
        )
    }
}

@Composable
private fun ParamCard(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(
        modifier = Modifier.fillMaxWidth().claudeCard(AccentOrange).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(title, fontSize = 13.sp, fontWeight = FontWeight.Bold, color = AccentOrange, letterSpacing = 1.sp)
        HorizontalDivider(color = Separator, thickness = 0.5.dp)
        content()
    }
}

@Composable
private fun ParamSlider(
    label: String,
    value: Float,
    min: Float,
    max: Float,
    accent: Color,
    fmt: (Float) -> String,
    onChange: (Float) -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(SurfaceDeep, RoundedCornerShape(10.dp))
            .border(1.dp, accent.copy(alpha = 0.18f), RoundedCornerShape(10.dp))
            .padding(horizontal = 14.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(label, fontSize = 12.sp, color = TextSecondary, fontWeight = FontWeight.Medium)
            Text(fmt(value), fontSize = 18.sp, fontWeight = FontWeight.ExtraBold, color = accent)
        }
        Slider(
            value = value.coerceIn(min, max),
            onValueChange = onChange,
            valueRange = min..max,
            modifier = Modifier.fillMaxWidth(),
            colors = SliderDefaults.colors(
                thumbColor = accent,
                activeTrackColor = accent,
                inactiveTrackColor = accent.copy(alpha = 0.2f),
            ),
        )
    }
}
