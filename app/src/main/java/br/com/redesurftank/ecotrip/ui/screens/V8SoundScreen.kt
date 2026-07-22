package br.com.redesurftank.ecotrip.ui.screens

import android.app.Activity
import android.content.pm.ActivityInfo
import android.view.WindowManager
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import br.com.redesurftank.ecotrip.managers.CarDataManager
import br.com.redesurftank.ecotrip.managers.V8SoundEngine
import br.com.redesurftank.ecotrip.models.CarConstants as CC
import br.com.redesurftank.ecotrip.models.SharedPreferencesKeys as K
import kotlinx.coroutines.delay
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.sin

// V8 Sound Config — direção 14a "master-detail" (docs/v8-sound-config-14a).
// Layout 3 colunas landscape: rail esquerdo (on/off + volume + presets) ·
// detail central (tabs de seção + sliders + avançado) · rail direito
// (mini-tacô + testar WOT + resumo preset).

// ── Paleta (igual à do V8 Cluster 13a) ──────────────────────────────────────
private val BG_A = Color(0xFF0C0C0F)
private val BG_B = Color(0xFF000000)
private val RED_SPORT = Color(0xFFEF4444)
private val ORANGE = Color(0xFFFB923C)
private val AMBER = Color(0xFFFBBF24)
private val GREEN_ECO = Color(0xFF22C55E)
private val BLUE_REGEN = Color(0xFF38BDF8)
private val TEXT_PRI = Color(0xFFF5F5F5)
private val TEXT_SEC = Color(0xFF94A3B8)
private val TEXT_MUTED = Color(0xFF6B7280)
private val TRACK = Color(0xFF1C1C20)
private val CARD_BG = Color(0xFF121216)
private val CARD_BG2 = Color(0xFF101014)
private val CARD_BORDER = Color(0x14FFFFFF)

private enum class Section { MIX, ESCAPAMENTO, ROTACAO, CAMBIO }

@Composable
fun V8SoundScreen(onBack: () -> Unit) {
    val ctx = LocalContext.current
    LaunchedEffect(Unit) { V8SoundEngine.loadConfig(ctx) }

    // Trava paisagem enquanto na tela
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

    // Estado — sliders + engine
    var enabled by remember { mutableStateOf(V8SoundEngine.enabled) }
    var masterVol by remember { mutableStateOf(V8SoundEngine.masterVol) }
    var regenVol by remember { mutableStateOf(V8SoundEngine.regenVol) }
    var toneHz by remember { mutableStateOf(V8SoundEngine.toneHz) }
    var rasp by remember { mutableStateOf(V8SoundEngine.rasp) }
    var rumble by remember { mutableStateOf(V8SoundEngine.rumble) }
    var loadBright by remember { mutableStateOf(V8SoundEngine.loadBright) }
    var crackle by remember { mutableStateOf(V8SoundEngine.crackle) }
    var popAccel by remember { mutableStateOf(V8SoundEngine.popAccel) }
    var idleRpm by remember { mutableStateOf(V8SoundEngine.idleRpm) }
    var redlineRpm by remember { mutableStateOf(V8SoundEngine.redlineRpm) }
    var speedToRpm by remember { mutableStateOf(V8SoundEngine.speedToRpm) }
    var revBoost by remember { mutableStateOf(V8SoundEngine.revBoost) }
    var powerFull by remember { mutableStateOf(V8SoundEngine.powerFullKw) }
    var gearCount by remember { mutableStateOf(V8SoundEngine.gearCount) }
    var shiftUpPct by remember { mutableStateOf(V8SoundEngine.shiftUpPct) }
    var kickdown by remember { mutableStateOf(V8SoundEngine.kickdown) }
    var preset by remember { mutableStateOf(V8SoundEngine.currentPreset) }

    // Telemetria ao vivo pro mini-tacô + trava "dirigindo"
    var rpm by remember { mutableStateOf(0) }
    var throttle by remember { mutableStateOf(0f) }
    var regen by remember { mutableStateOf(false) }
    var gearNow by remember { mutableStateOf(1) }
    var carSpeed by remember { mutableStateOf(0) }
    var testProgress by remember { mutableStateOf(0f) }

    LaunchedEffect(enabled) {
        val car = CarDataManager.getInstance()
        while (true) {
            rpm = V8SoundEngine.displayRpm
            throttle = V8SoundEngine.displayThrottle
            regen = V8SoundEngine.displayRegen
            gearNow = V8SoundEngine.displayGear
            carSpeed = readFloat(car, CC.CAR_BASIC_VEHICLE_SPEED.value)?.roundToInt() ?: 0
            testProgress = V8SoundEngine.wotTestProgress()
            delay(70)
        }
    }

    val section = remember { mutableStateOf(Section.ESCAPAMENTO) }
    val moving = carSpeed > 0
    val bgBrush = Brush.verticalGradient(colors = listOf(BG_A, BG_B))

    // Header topo minúsculo (voltar)
    Box(modifier = Modifier.fillMaxSize().background(bgBrush)) {

        Column(modifier = Modifier.fillMaxSize().padding(horizontal = 20.dp, vertical = 8.dp)) {
            // Top bar
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("←", color = TEXT_PRI, fontSize = 22.sp,
                    modifier = Modifier.clickable { onBack() }.padding(end = 14.dp))
                Text("V8 SOUND", color = RED_SPORT, fontSize = 12.sp,
                    letterSpacing = 4.sp, fontWeight = FontWeight.Bold)
            }

            // Banner "DIRIGINDO" — trava parcial
            if (moving) {
                Spacer(Modifier.height(8.dp))
                Row(
                    modifier = Modifier.fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .background(AMBER.copy(alpha = 0.12f))
                        .padding(horizontal = 14.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text("⚠", color = AMBER, fontSize = 16.sp,
                        modifier = Modifier.padding(end = 8.dp))
                    Text("DIRIGINDO · afinação bloqueada",
                        color = AMBER, fontSize = 12.sp, letterSpacing = 2.sp,
                        fontWeight = FontWeight.Bold)
                }
            }

            Spacer(Modifier.height(12.dp))

            Row(modifier = Modifier.fillMaxSize(),
                horizontalArrangement = Arrangement.spacedBy(20.dp)) {

                // ── RAIL ESQUERDO (Nível 1) ───────────────────────────────────
                Column(modifier = Modifier.width(400.dp).fillMaxHeight()
                    .verticalScroll(rememberScrollState()),
                    verticalArrangement = Arrangement.spacedBy(12.dp)) {

                    // Card Motor V8 on/off
                    MotorCard(enabled = enabled, onToggle = {
                        enabled = it; V8SoundEngine.setEnabled(ctx, it)
                    })

                    // Card Volume (fora das seções — Nível 1)
                    val level1Alpha = if (moving) 1f else 1f     // sempre editável (mesmo dirigindo)
                    VolumeCard(volume = masterVol, alpha = 1f, onChange = {
                        masterVol = it; V8SoundEngine.setParam(ctx, K.V8_MASTER_VOL, it)
                    })

                    // Lista de presets (Nível 1)
                    PresetsCard(current = preset, alpha = 1f, onSelect = { p ->
                        preset = p.name
                        V8SoundEngine.applyPreset(ctx, p)
                        // re-semeia sliders com o preset aplicado
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
                    })
                }

                // ── DETAIL CENTRAL (Nível 2/3) ────────────────────────────────
                Column(modifier = Modifier.weight(1f).fillMaxHeight()
                    .verticalScroll(rememberScrollState())
                    .alpha(if (!enabled) 0.4f else if (moving) 0.35f else 1f),
                    verticalArrangement = Arrangement.spacedBy(14.dp)) {

                    SectionTabs(current = section.value, onSelect = { section.value = it },
                        enabled = enabled && !moving)

                    when (section.value) {
                        Section.MIX -> SectionMix(
                            regenVol = regenVol, onRegenVol = { regenVol = it; V8SoundEngine.setParam(ctx, K.V8_REGEN_VOL, it) },
                            toneHz = toneHz, onToneHz = { toneHz = it; V8SoundEngine.setParam(ctx, K.V8_TONE_HZ, it) },
                        )
                        Section.ESCAPAMENTO -> SectionEscape(
                            rasp = rasp, onRasp = { rasp = it; V8SoundEngine.setParam(ctx, K.V8_RASP, it) },
                            rumble = rumble, onRumble = { rumble = it; V8SoundEngine.setParam(ctx, K.V8_RUMBLE, it) },
                            loadBright = loadBright, onBright = { loadBright = it; V8SoundEngine.setParam(ctx, K.V8_LOAD_BRIGHT, it) },
                            crackle = crackle, onCrackle = { crackle = it; V8SoundEngine.setParam(ctx, K.V8_CRACKLE, it) },
                            popAccel = popAccel, onPop = { popAccel = it; V8SoundEngine.setParam(ctx, K.V8_POP_ACCEL, it) },
                        )
                        Section.ROTACAO -> SectionRotation(
                            idleRpm = idleRpm, onIdle = { idleRpm = it; V8SoundEngine.setParam(ctx, K.V8_IDLE_RPM, it) },
                            redlineRpm = redlineRpm, onRedline = { redlineRpm = it; V8SoundEngine.setParam(ctx, K.V8_REDLINE_RPM, it) },
                            speedToRpm = speedToRpm, onS2R = { speedToRpm = it; V8SoundEngine.setParam(ctx, K.V8_SPEED_TO_RPM, it) },
                            revBoost = revBoost, onBoost = { revBoost = it; V8SoundEngine.setParam(ctx, K.V8_REV_BOOST, it) },
                            powerFull = powerFull, onPowerFull = { powerFull = it; V8SoundEngine.setParam(ctx, K.V8_POWER_FULL_KW, it) },
                        )
                        Section.CAMBIO -> SectionCambio(
                            gearCount = gearCount, onGear = { gearCount = it; V8SoundEngine.setGearCount(ctx, it) },
                            shiftUpPct = shiftUpPct, onShiftUp = { shiftUpPct = it; V8SoundEngine.setParam(ctx, K.V8_SHIFT_UP_PCT, it) },
                            kickdown = kickdown, onKickdown = { kickdown = it; V8SoundEngine.setKickdown(ctx, it) },
                        )
                    }
                }

                // ── RAIL DIREITO (feedback + testar WOT + resumo) ─────────────
                Column(modifier = Modifier.width(360.dp).fillMaxHeight()
                    .alpha(if (!enabled) 0.4f else 1f),
                    verticalArrangement = Arrangement.spacedBy(12.dp)) {

                    MiniTacho(rpm = rpm, redline = redlineRpm.toInt(), regen = regen,
                        throttle = throttle, gearNow = gearNow, gearCount = gearCount,
                        speed = carSpeed)

                    WotTestButton(
                        progress = testProgress, enabled = enabled && !moving,
                        onClick = { V8SoundEngine.startWotTest(3000L) },
                    )

                    PresetSummaryCard(preset = preset)
                }
            }
        }
    }
}

// ── RAIL ESQUERDO — Cards Nível 1 ───────────────────────────────────────────

@Composable
private fun MotorCard(enabled: Boolean, onToggle: (Boolean) -> Unit) {
    val bg = if (enabled) RED_SPORT.copy(alpha = 0.10f) else CARD_BG
    val border = if (enabled) RED_SPORT.copy(alpha = 0.45f) else CARD_BORDER
    Box(modifier = Modifier.fillMaxWidth()
        .clip(RoundedCornerShape(18.dp))
        .background(border, RoundedCornerShape(18.dp)).padding(1.dp)
        .background(bg, RoundedCornerShape(17.dp))
        .padding(horizontal = 20.dp, vertical = 18.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text("Motor V8", color = TEXT_PRI, fontSize = 22.sp, fontWeight = FontWeight.Bold)
                Text(
                    if (enabled) "tocando nas caixas" else "desligado",
                    color = if (enabled) RED_SPORT else TEXT_MUTED,
                    fontSize = 13.sp, fontWeight = FontWeight.Medium,
                )
            }
            Switch(
                checked = enabled, onCheckedChange = onToggle,
                colors = SwitchDefaults.colors(
                    checkedThumbColor = Color.White,
                    checkedTrackColor = RED_SPORT,
                    uncheckedThumbColor = Color.White,
                    uncheckedTrackColor = Color(0xFF2A2A2A),
                ),
            )
        }
    }
}

@Composable
private fun VolumeCard(volume: Float, alpha: Float, onChange: (Float) -> Unit) {
    Box(modifier = Modifier.fillMaxWidth().alpha(alpha)
        .clip(RoundedCornerShape(18.dp))
        .background(CARD_BORDER, RoundedCornerShape(18.dp)).padding(1.dp)
        .background(CARD_BG, RoundedCornerShape(17.dp))
        .padding(horizontal = 20.dp, vertical = 16.dp)) {
        Column {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("VOLUME", color = TEXT_MUTED, fontSize = 12.sp, letterSpacing = 2.5.sp,
                    fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
                Text("${(volume * 100).roundToInt()}%",
                    color = TEXT_PRI, fontSize = 22.sp, fontWeight = FontWeight.SemiBold,
                    fontFamily = FontFamily.Monospace)
            }
            Spacer(Modifier.height(6.dp))
            GradientSlider(value = volume, range = 0f..1f, onValueChange = onChange)
        }
    }
}

@Composable
private fun PresetsCard(current: String, alpha: Float, onSelect: (V8SoundEngine.EnginePreset) -> Unit) {
    Column(modifier = Modifier.fillMaxWidth().alpha(alpha)
        .clip(RoundedCornerShape(18.dp))
        .background(CARD_BORDER, RoundedCornerShape(18.dp)).padding(1.dp)
        .background(CARD_BG, RoundedCornerShape(17.dp))
        .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("PRESETS", color = TEXT_MUTED, fontSize = 12.sp, letterSpacing = 2.5.sp,
            fontWeight = FontWeight.Bold)
        // 4 presets fullwidth + 2 half-width lado a lado
        val fullList = V8SoundEngine.PRESETS.take(4)
        val halfList = V8SoundEngine.PRESETS.drop(4)
        fullList.forEach { p -> PresetRow(p = p, selected = p.name == current, half = false,
            modifier = Modifier.fillMaxWidth(), onClick = { onSelect(p) }) }
        if (halfList.size >= 2) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                PresetRow(p = halfList[0], selected = halfList[0].name == current, half = true,
                    modifier = Modifier.weight(1f), onClick = { onSelect(halfList[0]) })
                PresetRow(p = halfList[1], selected = halfList[1].name == current, half = true,
                    modifier = Modifier.weight(1f), onClick = { onSelect(halfList[1]) })
            }
        }
    }
}

@Composable
private fun PresetRow(p: V8SoundEngine.EnginePreset, selected: Boolean, half: Boolean,
                     modifier: Modifier = Modifier, onClick: () -> Unit) {
    val bg = if (selected) RED_SPORT.copy(alpha = 0.12f) else CARD_BG2
    val border = if (selected) RED_SPORT.copy(alpha = 0.5f) else CARD_BORDER
    Box(modifier = modifier
        .clip(RoundedCornerShape(14.dp))
        .background(border, RoundedCornerShape(14.dp)).padding(1.dp)
        .background(bg, RoundedCornerShape(13.dp))
        .clickable(onClick = onClick)
        .padding(horizontal = 14.dp, vertical = 11.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(p.name, color = TEXT_PRI, fontSize = if (half) 15.sp else 17.sp,
                    fontWeight = FontWeight.SemiBold)
                Text(presetCharacterFor(p.name), color = TEXT_MUTED,
                    fontSize = if (half) 11.sp else 12.sp)
            }
            if (selected) Text("✓", color = RED_SPORT, fontSize = 18.sp,
                fontWeight = FontWeight.Bold)
        }
    }
}

private fun presetCharacterFor(name: String): String = when (name) {
    "V8 Mexido" -> "escape aberto · muito pipoco"
    "V8 Muscle" -> "ronco grave · low idle"
    "V10 Super" -> "alto e agudo · sem lope"
    "V12" -> "refinado · redline alto"
    "6 em linha" -> "suave · limpo"
    "4-cil turbo" -> "whistle · pop-pop"
    else -> ""
}

// ── DETAIL CENTRAL — Tabs + Seções ──────────────────────────────────────────

@Composable
private fun SectionTabs(current: Section, onSelect: (Section) -> Unit, enabled: Boolean) {
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.fillMaxWidth()) {
        Section.values().forEach { s ->
            val label = when (s) {
                Section.MIX -> "MIX"
                Section.ESCAPAMENTO -> "ESCAPAMENTO"
                Section.ROTACAO -> "ROTAÇÃO"
                Section.CAMBIO -> "CÂMBIO"
            }
            val sel = s == current
            val bg = if (sel) RED_SPORT.copy(alpha = 0.15f) else CARD_BG2
            val border = if (sel) RED_SPORT.copy(alpha = 0.55f) else CARD_BORDER
            val fg = if (sel) RED_SPORT else TEXT_SEC
            Box(modifier = Modifier.weight(1f).height(58.dp)
                .clip(RoundedCornerShape(14.dp))
                .background(border, RoundedCornerShape(14.dp)).padding(1.dp)
                .background(bg, RoundedCornerShape(13.dp))
                .clickable(enabled = enabled) { onSelect(s) },
                contentAlignment = Alignment.Center) {
                Text(label, color = fg, fontSize = 15.sp, letterSpacing = 2.sp,
                    fontWeight = FontWeight.Bold)
            }
        }
    }
}

@Composable
private fun SectionCard(content: @Composable ColumnScope.() -> Unit) {
    Column(modifier = Modifier.fillMaxWidth()
        .clip(RoundedCornerShape(18.dp))
        .background(CARD_BORDER, RoundedCornerShape(18.dp)).padding(1.dp)
        .background(CARD_BG2, RoundedCornerShape(17.dp))
        .padding(horizontal = 22.dp, vertical = 22.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
        content = content)
}

@Composable
private fun SectionMix(regenVol: Float, onRegenVol: (Float) -> Unit,
                      toneHz: Float, onToneHz: (Float) -> Unit) {
    SectionCard {
        LabeledSlider("Volume no regen", "volume quando frenagem regenerativa",
            regenVol, 0f..1f, formatter = { pct(it) }, onChange = onRegenVol)
        LabeledSlider("Timbre", "grave ↔ brilhante · corte do low-pass",
            toneHz, 800f..6000f, formatter = { "${it.roundToInt()} Hz" }, onChange = onToneHz)
    }
}

@Composable
private fun SectionEscape(
    rasp: Float, onRasp: (Float) -> Unit,
    rumble: Float, onRumble: (Float) -> Unit,
    loadBright: Float, onBright: (Float) -> Unit,
    crackle: Float, onCrackle: (Float) -> Unit,
    popAccel: Float, onPop: (Float) -> Unit,
) {
    SectionCard {
        LabeledSlider("Rasp", "rugosidade do escape 'mexido'",
            rasp, 0f..1f, formatter = { pct(it) }, onChange = onRasp)
        LabeledSlider("Ronco", "o 'vrum' grave do V8 (meia-ordem)",
            rumble, 0f..1.5f, formatter = { dec(it) }, onChange = onRumble)
        LabeledSlider("Agressividade sob carga", "harmônicas altas quando acelera",
            loadBright, 0f..1f, formatter = { pct(it) }, onChange = onBright)
        Row(horizontalArrangement = Arrangement.spacedBy(20.dp)) {
            Box(Modifier.weight(1f)) {
                LabeledSlider("Estalos ao soltar", "pipoco no lift/regen",
                    crackle, 0f..1f, formatter = { pct(it) }, onChange = onCrackle)
            }
            Box(Modifier.weight(1f)) {
                LabeledSlider("Estalos no WOT", "cuspidas ao acelerar forte",
                    popAccel, 0f..1f, formatter = { pct(it) }, onChange = onPop)
            }
        }
    }
}

@Composable
private fun SectionRotation(
    idleRpm: Float, onIdle: (Float) -> Unit,
    redlineRpm: Float, onRedline: (Float) -> Unit,
    speedToRpm: Float, onS2R: (Float) -> Unit,
    revBoost: Float, onBoost: (Float) -> Unit,
    powerFull: Float, onPowerFull: (Float) -> Unit,
) {
    var advanced by remember { mutableStateOf(false) }
    SectionCard {
        LabeledSlider("Marcha lenta", "idle rpm com o carro parado",
            idleRpm, 400f..1200f, formatter = { "${it.roundToInt()} rpm" }, onChange = onIdle)
        LabeledSlider("Corte (redline)", "rpm máximo antes do corte",
            redlineRpm, 4000f..8000f, formatter = { "${it.roundToInt()} rpm" }, onChange = onRedline)
        LabeledSlider("Rotação por km/h", "inclinação do câmbio virtual",
            speedToRpm, 10f..90f, formatter = { "${it.roundToInt()}" }, onChange = onS2R)

        AdvancedToggle(open = advanced, onClick = { advanced = !advanced })
        AnimatedVisibility(visible = advanced,
            enter = expandVertically(tween(200)),
            exit = shrinkVertically(tween(200))) {
            Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
                LabeledSlider("Empurrão do acelerador", "rpm além do cruzeiro quando pisa",
                    revBoost, 0f..5000f, formatter = { "${it.roundToInt()} rpm" }, onChange = onBoost,
                    dim = true)
                LabeledSlider("Potência p/ acelerador no fundo", "kW = WOT normalizado",
                    powerFull, 30f..200f, formatter = { "${it.roundToInt()} kW" }, onChange = onPowerFull,
                    dim = true)
            }
        }
    }
}

@Composable
private fun SectionCambio(
    gearCount: Int, onGear: (Int) -> Unit,
    shiftUpPct: Float, onShiftUp: (Float) -> Unit,
    kickdown: Boolean, onKickdown: (Boolean) -> Unit,
) {
    SectionCard {
        // Stepper de marchas (chips 1..8)
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.Bottom) {
                Text("Marchas", color = TEXT_PRI, fontSize = 17.sp, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.weight(1f))
                Text("${gearCount}" + if (gearCount == 1) "  linear" else "",
                    color = TEXT_PRI, fontSize = 20.sp, fontFamily = FontFamily.Monospace,
                    fontWeight = FontWeight.SemiBold)
            }
            Text("câmbio automático simulado", color = TEXT_MUTED, fontSize = 13.sp)
            Spacer(Modifier.height(4.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                (1..8).forEach { n ->
                    val sel = n == gearCount
                    val bg = if (sel) RED_SPORT else CARD_BG2
                    val fg = if (sel) Color.White else TEXT_SEC
                    Box(modifier = Modifier.weight(1f).height(48.dp)
                        .clip(RoundedCornerShape(10.dp))
                        .background(bg)
                        .clickable { onGear(n) },
                        contentAlignment = Alignment.Center) {
                        Text("$n", color = fg, fontSize = 17.sp,
                            fontFamily = FontFamily.Monospace, fontWeight = FontWeight.SemiBold)
                    }
                }
            }
        }
        LabeledSlider("Ponto de upshift", "% do redline para trocar pra cima",
            shiftUpPct, 0.60f..0.98f, formatter = { pct(it) }, onChange = onShiftUp)
        Row(verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth()) {
            Column(Modifier.weight(1f)) {
                Text("Kickdown", color = TEXT_PRI, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
                Text("desce marcha em aceleração forte", color = TEXT_MUTED, fontSize = 13.sp)
            }
            Switch(checked = kickdown, onCheckedChange = onKickdown,
                colors = SwitchDefaults.colors(
                    checkedThumbColor = Color.White,
                    checkedTrackColor = RED_SPORT,
                    uncheckedThumbColor = Color.White,
                    uncheckedTrackColor = Color(0xFF2A2A2A),
                ))
        }
    }
}

@Composable
private fun AdvancedToggle(open: Boolean, onClick: () -> Unit) {
    Column {
        Box(modifier = Modifier.fillMaxWidth().height(1.dp).background(CARD_BORDER))
        Spacer(Modifier.height(10.dp))
        Row(modifier = Modifier.fillMaxWidth().clickable(onClick = onClick),
            verticalAlignment = Alignment.CenterVertically) {
            Text("AVANÇADO", color = TEXT_MUTED, fontSize = 12.sp, letterSpacing = 2.5.sp,
                fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
            val rotation by animateFloatAsState(
                targetValue = if (open) 180f else 0f, animationSpec = tween(200), label = "rot",
            )
            Text("⌄", color = TEXT_MUTED, fontSize = 16.sp,
                modifier = Modifier.rotate(rotation))
        }
    }
}

@Composable
private fun LabeledSlider(name: String, why: String, value: Float,
                        range: ClosedFloatingPointRange<Float>,
                        formatter: (Float) -> String, onChange: (Float) -> Unit,
                        dim: Boolean = false) {
    val nameColor = if (dim) TEXT_MUTED else TEXT_PRI
    val whyColor = if (dim) TEXT_MUTED.copy(alpha = 0.7f) else TEXT_MUTED
    Column(verticalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier.fillMaxWidth()) {
        Row(verticalAlignment = Alignment.Bottom) {
            Text(name, color = nameColor, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
            Text(" · ", color = whyColor, fontSize = 13.sp)
            Text(why, color = whyColor, fontSize = 13.sp,
                modifier = Modifier.weight(1f).padding(top = 3.dp))
            Text(formatter(value),
                color = if (dim) TEXT_SEC else TEXT_PRI,
                fontSize = 20.sp, fontFamily = FontFamily.Monospace,
                fontWeight = FontWeight.SemiBold)
        }
        GradientSlider(value = value, range = range, onValueChange = onChange, dim = dim)
    }
}

@Composable
private fun GradientSlider(value: Float, range: ClosedFloatingPointRange<Float>,
                          onValueChange: (Float) -> Unit, dim: Boolean = false) {
    val activeColor = if (dim) TEXT_SEC else ORANGE
    val thumbColor = if (dim) TEXT_SEC else Color.White
    Slider(
        value = value, onValueChange = onValueChange, valueRange = range,
        modifier = Modifier.fillMaxWidth().height(28.dp),
        colors = SliderDefaults.colors(
            thumbColor = thumbColor,
            activeTrackColor = activeColor,
            inactiveTrackColor = TRACK,
            activeTickColor = Color.Transparent,
            inactiveTickColor = Color.Transparent,
        ),
    )
}

// ── RAIL DIREITO — Mini-tacô + Testar WOT + Resumo do preset ────────────────

@Composable
private fun MiniTacho(rpm: Int, redline: Int, regen: Boolean, throttle: Float,
                    gearNow: Int, gearCount: Int, speed: Int) {
    val ratio = (rpm.toFloat() / redline.toFloat()).coerceIn(0f, 1f)
    val stateWord = when {
        regen -> "REGEN"
        throttle > 0.15f -> "ACELERANDO"
        else -> "IDLE"
    }
    val stateColor = if (regen) BLUE_REGEN else if (throttle > 0.15f) RED_SPORT else TEXT_MUTED

    Box(modifier = Modifier.fillMaxWidth()
        .clip(RoundedCornerShape(18.dp))
        .background(CARD_BORDER, RoundedCornerShape(18.dp)).padding(1.dp)
        .background(CARD_BG2, RoundedCornerShape(17.dp))
        .padding(horizontal = 16.dp, vertical = 14.dp)) {
        Column(horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier.fillMaxWidth()) {
            // Arco semi 220×130
            Box(modifier = Modifier.size(220.dp, 130.dp)) {
                Canvas(modifier = Modifier.fillMaxSize()) {
                    val cx = size.width / 2f
                    val cy = size.height * 0.95f
                    val r = size.width / 2f - 12f
                    val stroke = 12f
                    val startDeg = 180f
                    val sweepDeg = 180f
                    // track
                    drawArc(color = TRACK, startAngle = startDeg, sweepAngle = sweepDeg,
                        useCenter = false, style = Stroke(width = stroke, cap = StrokeCap.Round),
                        topLeft = Offset(cx - r, cy - r), size = Size(r * 2, r * 2))
                    // fill
                    if (ratio > 0.01f) {
                        val brush = if (regen) Brush.linearGradient(colors = listOf(BLUE_REGEN, BLUE_REGEN))
                            else Brush.sweepGradient(colors = listOf(ORANGE, RED_SPORT), center = Offset(cx, cy))
                        drawArc(brush = brush, startAngle = startDeg, sweepAngle = sweepDeg * ratio,
                            useCenter = false, style = Stroke(width = stroke, cap = StrokeCap.Round),
                            topLeft = Offset(cx - r, cy - r), size = Size(r * 2, r * 2))
                    }
                }
                // texto no centro
                Column(horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = 4.dp)) {
                    Text("$rpm", color = TEXT_PRI, fontSize = 40.sp, fontWeight = FontWeight.Bold,
                        fontFamily = FontFamily.Monospace)
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("RPM", color = TEXT_MUTED, fontSize = 11.sp, letterSpacing = 2.sp,
                            fontWeight = FontWeight.Bold)
                        Text(" · ", color = TEXT_MUTED, fontSize = 11.sp)
                        Text(stateWord, color = stateColor, fontSize = 11.sp, letterSpacing = 2.sp,
                            fontWeight = FontWeight.Bold)
                    }
                }
            }
            Spacer(Modifier.height(6.dp))
            // Chips embaixo
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Chip("MARCHA ${if (gearCount <= 1) "D" else "$gearNow"}")
                Chip("$speed KM/H")
                Chip("${((kotlin.math.abs(throttle)).coerceIn(0f,1f) * 100).roundToInt()}%")
            }
        }
    }
}

@Composable
private fun Chip(text: String) {
    Box(modifier = Modifier
        .clip(RoundedCornerShape(6.dp))
        .background(TRACK)
        .padding(horizontal = 8.dp, vertical = 4.dp)) {
        Text(text, color = TEXT_SEC, fontSize = 10.sp,
            fontFamily = FontFamily.Monospace, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun WotTestButton(progress: Float, enabled: Boolean, onClick: () -> Unit) {
    val alpha = if (enabled) 1f else 0.4f
    Box(modifier = Modifier.fillMaxWidth().height(88.dp).alpha(alpha)
        .clip(RoundedCornerShape(18.dp))
        .background(RED_SPORT.copy(alpha = 0.4f), RoundedCornerShape(18.dp)).padding(1.dp)
        .background(
            Brush.horizontalGradient(colors = listOf(RED_SPORT.copy(alpha = 0.2f), CARD_BG)),
            RoundedCornerShape(17.dp),
        )
        .clickable(enabled = enabled && progress <= 0f, onClick = onClick),
    ) {
        // Fill de progresso quando testando
        if (progress > 0f) {
            Box(modifier = Modifier.fillMaxWidth(progress).fillMaxHeight()
                .background(RED_SPORT.copy(alpha = 0.35f)))
        }
        Row(modifier = Modifier.fillMaxSize().padding(horizontal = 16.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Text("▶", color = RED_SPORT, fontSize = 24.sp,
                modifier = Modifier.padding(end = 12.dp))
            Column {
                val label = if (progress > 0f) {
                    val remaining = kotlin.math.ceil((1f - progress) * 3f).toInt().coerceAtLeast(1)
                    "TESTANDO · $remaining"
                } else "TESTAR WOT"
                Text(label, color = RED_SPORT, fontSize = 18.sp, letterSpacing = 2.sp,
                    fontWeight = FontWeight.Bold)
                Text("simula 3 s de aceleração, parado", color = TEXT_MUTED, fontSize = 11.sp)
            }
        }
    }
}

@Composable
private fun PresetSummaryCard(preset: String) {
    val p = V8SoundEngine.PRESETS.firstOrNull { it.name == preset } ?: return
    val label = "${p.name} · firing order ${p.firingOrder.toInt()} · redline ${p.redlineRpm.toInt()}"
    Column(modifier = Modifier.fillMaxWidth()
        .clip(RoundedCornerShape(18.dp))
        .background(CARD_BORDER, RoundedCornerShape(18.dp)).padding(1.dp)
        .background(CARD_BG2, RoundedCornerShape(17.dp))
        .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text("ESTE PRESET", color = TEXT_MUTED, fontSize = 11.sp, letterSpacing = 2.5.sp,
            fontWeight = FontWeight.Bold)
        Text(label, color = TEXT_SEC, fontSize = 12.sp, fontWeight = FontWeight.Medium)
    }
}

// ── Helpers ──────────────────────────────────────────────────────────────────

private fun pct(v: Float) = "${(v * 100).roundToInt()}%"
private fun dec(v: Float) = String.format("%.2f", v)

private fun readFloat(car: CarDataManager, key: String): Float? = try {
    car.fetchCurrent(key)?.trim()?.toFloatOrNull()
} catch (_: Exception) { null }

// Modifier.alpha do Compose já é padrão via androidx.compose.ui.draw.alpha —
// importado no topo.
