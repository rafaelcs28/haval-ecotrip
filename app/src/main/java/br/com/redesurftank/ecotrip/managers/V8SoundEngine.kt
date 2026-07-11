package br.com.redesurftank.ecotrip.managers

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import br.com.redesurftank.ecotrip.models.SharedPreferencesKeys
import kotlin.math.PI
import kotlin.math.exp
import kotlin.math.sin
import kotlin.math.tanh

// Sintetizador procedural de motor V8. Não usa samples: gera o "braaap" somando
// harmônicas da rotação virtual (a 4ª ordem = a queima do V8; a meia-ordem = o
// ronco/lope característico) + ruído de escape + estalos de overrun no regen.
//
// Entrada = potência do motor elétrico (kW, + acelera / − regen) + velocidade.
// A potência vira "throttle" (carga → brilho + empurra a rotação pra cima); a
// velocidade + câmbio virtual dão a rotação de cruzeiro. Regen = marcha lenta /
// freio-motor (volume baixo + crackle).
//
// TUDO é ajustável ao vivo pelas Settings (V8Config, persistido em prefs). Rode
// no carro e mexa nos sliders até o ponto ideal — nada aqui é hardcode fixo.
object V8SoundEngine {
    private const val TAG = "V8SoundEngine"
    private const val SR = 22050            // rumble é grave; 22k basta e é barato
    private const val BLOCK = 512           // frames por escrita (~23ms)
    private const val CYL = 8               // 4 tempos: 4 queimas / volta de virabrequim

    // ── Config ao vivo (persistida). Todos os setters gravam + aplicam na hora. ──
    @Volatile var enabled = false;        private set
    @Volatile var masterVol = 0.65f
    @Volatile var idleRpm = 650f
    @Volatile var redlineRpm = 6200f
    @Volatile var powerFullKw = 90f       // kW que corresponde a "acelerador no fundo"
    @Volatile var speedToRpm = 42f        // rpm de cruzeiro por km/h (inclinação do câmbio virtual)
    @Volatile var revBoost = 2600f        // quanto o acelerador empurra a rotação acima do cruzeiro
    @Volatile var rumble = 0.85f          // amplitude da meia-ordem (ronco/lope do V8)
    @Volatile var loadBright = 1.0f       // quanta harmônica alta a carga adiciona (agressividade)
    @Volatile var regenVol = 0.5f         // volume relativo quando regenerando (freio-motor)
    @Volatile var crackle = 0.75f         // intensidade dos estalos de overrun (soltar/regen)
    @Volatile var popAccel = 0.55f        // estalos/cuspidas ao acelerar forte (WOT)
    @Volatile var rasp = 0.55f            // rasp/grit do escapamento mexido (drive/distorção)
    @Volatile var toneHz = 5200f          // corte do low-pass final (timbre: grave↔brilhante)
    @Volatile var firingOrder = 4f        // ordem de disparo dominante (V8=4, V10=5, V12=6, I6=3, I4=2)
    @Volatile var currentPreset = "V8 Mexido"

    // ── Entrada ao vivo (alimentada pelo hook de telemetria) ──
    @Volatile private var carOn = false
    @Volatile private var inThrottle = 0f     // -1..1 (potência normalizada)
    @Volatile private var inTargetRpm = 650f  // semente = marcha lenta (soa idle até chegar telemetria)

    @Volatile private var running = false
    private var thread: Thread? = null
    private var track: AudioTrack? = null
    private var appCtx: Context? = null

    // ── Estado do DSP (só a thread de áudio mexe) ──
    private var rpm = 0f
    private var crankPhase = 0.0
    private var lpState = 0f
    private var popEnv = 0f
    private var popCoef = 0f
    private var popPhase = 0.0        // thump grave do estalo
    private var prevThr = 0f          // detecção de "soltar" (lift) entre blocos
    private var overrunSamples = 0    // janela de estalos após soltar
    private val rng = java.util.Random()

    // ── Leituras ao vivo pra UI (tacômetro) ──
    @Volatile private var liveRpm = 0f
    @Volatile private var liveThrottle = 0f
    val displayRpm: Int get() = liveRpm.toInt()
    val displayThrottle: Float get() = liveThrottle
    val displayRegen: Boolean get() = liveThrottle < -0.02f

    val isRunning: Boolean get() = running

    // ── Presets de caráter (não tocam nos params calibrados por carro:
    //    volume, potência-p/-fundo, rotação-por-km/h) ────────────────────────────
    data class EnginePreset(
        val name: String,
        val firingOrder: Float,
        val idleRpm: Float,
        val redlineRpm: Float,
        val rumble: Float,
        val loadBright: Float,
        val crackle: Float,
        val popAccel: Float,
        val rasp: Float,
        val toneHz: Float,
        val revBoost: Float,
        val regenVol: Float,
    )

    val PRESETS = listOf(
        EnginePreset("V8 Mexido",   4f, 650f, 6200f, 0.85f, 1.0f,  0.75f, 0.55f, 0.55f, 5200f, 2600f, 0.5f),
        EnginePreset("V8 Muscle",   4f, 600f, 5800f, 1.10f, 0.8f,  0.55f, 0.40f, 0.45f, 3800f, 2400f, 0.5f),
        EnginePreset("V10 Super",   5f, 950f, 8500f, 0.30f, 1.0f,  0.45f, 0.50f, 0.45f, 6000f, 3200f, 0.45f),
        EnginePreset("V12",         6f, 700f, 7800f, 0.25f, 0.9f,  0.30f, 0.35f, 0.35f, 5600f, 3000f, 0.4f),
        EnginePreset("6 em linha",  3f, 750f, 6600f, 0.45f, 0.85f, 0.50f, 0.45f, 0.50f, 4600f, 2600f, 0.5f),
        EnginePreset("4-cil turbo", 2f, 850f, 6800f, 0.35f, 0.9f,  0.90f, 0.80f, 0.60f, 5000f, 2800f, 0.55f),
    )

    /** Aplica um preset de caráter (grava tudo em prefs + aplica ao vivo). */
    fun applyPreset(ctx: Context, p: EnginePreset) {
        setParam(ctx, SharedPreferencesKeys.V8_FIRING_ORDER, p.firingOrder)
        setParam(ctx, SharedPreferencesKeys.V8_IDLE_RPM, p.idleRpm)
        setParam(ctx, SharedPreferencesKeys.V8_REDLINE_RPM, p.redlineRpm)
        setParam(ctx, SharedPreferencesKeys.V8_RUMBLE, p.rumble)
        setParam(ctx, SharedPreferencesKeys.V8_LOAD_BRIGHT, p.loadBright)
        setParam(ctx, SharedPreferencesKeys.V8_CRACKLE, p.crackle)
        setParam(ctx, SharedPreferencesKeys.V8_POP_ACCEL, p.popAccel)
        setParam(ctx, SharedPreferencesKeys.V8_RASP, p.rasp)
        setParam(ctx, SharedPreferencesKeys.V8_TONE_HZ, p.toneHz)
        setParam(ctx, SharedPreferencesKeys.V8_REV_BOOST, p.revBoost)
        setParam(ctx, SharedPreferencesKeys.V8_REGEN_VOL, p.regenVol)
        currentPreset = p.name
        prefs(ctx).edit().putString(SharedPreferencesKeys.V8_PRESET, p.name).apply()
    }

    // ── API pública ────────────────────────────────────────────────────────────

    /** Alimenta o motor com a telemetria crua do carro. Barato; chame à vontade. */
    fun feed(motorPowerKw: Float, speedKmh: Float, drivingReady: Boolean, gear: Int) {
        carOn = drivingReady
        val full = if (powerFullKw > 1f) powerFullKw else 90f
        inThrottle = (motorPowerKw / full).coerceIn(-1f, 1f)
        // Rotação-alvo: cruzeiro (velocidade × câmbio) + empurrão do acelerador.
        val cruise = idleRpm + speedKmh.coerceAtLeast(0f) * speedToRpm
        val boost = if (inThrottle > 0f) inThrottle * revBoost else 0f
        // No regen tira um pouco da rotação (desacelerando) pra dar o freio-motor.
        val drag = if (inThrottle < 0f) inThrottle * 400f else 0f
        inTargetRpm = (cruise + boost + drag).coerceIn(idleRpm, redlineRpm)
    }

    fun start(ctx: Context) {
        appCtx = ctx.applicationContext
        if (running) return
        running = true
        rpm = idleRpm
        inTargetRpm = idleRpm
        inThrottle = 0f
        thread = Thread { audioLoop() }.apply { isDaemon = true; name = "v8-engine"; start() }
        AppLogger.i(TAG, "V8 engine iniciado (sr=$SR)")
    }

    fun stop() {
        running = false
        try { thread?.join(300) } catch (_: Exception) {}
        thread = null
        try { track?.stop(); track?.release() } catch (_: Exception) {}
        track = null
        AppLogger.i(TAG, "V8 engine parado")
    }

    // ── DSP ──────────────────────────────────────────────────────────────────

    private fun audioLoop() {
        val minBuf = AudioTrack.getMinBufferSize(SR, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val t = AudioTrack(
            // USAGE_MEDIA sem pedir foco → mistura por cima da música/nav em vez de pausá-las.
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build(),
            AudioFormat.Builder()
                .setSampleRate(SR)
                .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT).build(),
            maxOf(minBuf, BLOCK * 2 * 4), AudioTrack.MODE_STREAM, AudioManager.AUDIO_SESSION_ID_GENERATE)
        if (t.state != AudioTrack.STATE_INITIALIZED) { AppLogger.w(TAG, "AudioTrack não inicializou"); running = false; return }
        track = t
        try { t.play() } catch (e: Exception) { AppLogger.w(TAG, "play falhou: ${e.message}"); running = false; return }

        val buf = ShortArray(BLOCK)
        // Suavização por-amostra da rotação: sobe rápido (attack), desce mais devagar.
        val attackTc = 0.12f; val decayTc = 0.45f
        val aUp = 1f - exp(-1f / (SR * attackTc))
        val aDn = 1f - exp(-1f / (SR * decayTc))
        var carGain = 0f   // fade in/out quando o carro liga/desliga (evita clique)

        while (running) {
            // Ligou o efeito = intenção de ouvir. NÃO gateia por carOn/driving_ready
            // (que pode nunca chegar ou estar 0 parado) — senão fica mudo. A telemetria
            // só MODULA (rpm/carga) via feed(); a marcha lenta soa mesmo sem dado.
            val on = enabled
            val target = if (on) inTargetRpm.coerceAtLeast(idleRpm) else idleRpm
            val thr = inThrottle
            val vol = masterVol
            // coef do low-pass final a partir do corte configurado
            val lpA = (1f - exp(-2.0 * PI * toneHz / SR)).toFloat().coerceIn(0.01f, 1f)
            val regen = thr < -0.02f
            val load = thr.coerceIn(0f, 1f)
            // Volume alvo: fade pra 0 com carro desligado; regen abaixa o volume.
            val targetCarGain = if (on) (if (regen) regenVol else 1f) else 0f

            // "Soltou" o acelerador entre este bloco e o anterior → abre janela de
            // estalos de overrun (escapamento mexido cuspindo na desaceleração).
            val lift = prevThr - thr
            if (on && lift > 0.10f && prevThr > 0.22f) overrunSamples = (SR * 0.6f).toInt()
            prevThr = thr
            // Overrun ativo: soltou há pouco OU está regenerando (freio-motor).
            val overrun = on && (overrunSamples > 0 || regen)

            for (i in 0 until BLOCK) {
                if (overrunSamples > 0) overrunSamples--
                // rotação → alvo
                rpm += (target - rpm) * (if (target > rpm) aUp else aDn)
                carGain += (targetCarGain - carGain) * 0.0008f

                val f0 = rpm / 60.0            // Hz do virabrequim (fundamental)
                crankPhase += f0 / SR
                if (crankPhase >= 1.0) crankPhase -= 1.0
                val ph = 2.0 * PI * crankPhase

                val bright = loadBright * (if (regen) 0f else load)

                // Harmônicas: 0.5 = ronco/lope (crossplane V8); a queima fica na
                // ORDEM DE DISPARO (fire) — 4 pra V8, 5 V10, 6 V12, 3 I6, 2 I4.
                val fire = firingOrder.toDouble()
                var s = (rumble * sin(0.5 * ph)).toFloat()
                s += (0.55 * sin(ph)).toFloat()
                s += (0.45 * sin(2.0 * ph)).toFloat()
                s += (0.35 * sin(3.0 * ph)).toFloat()
                s += ((0.8 + 0.6 * bright) * sin(fire * ph)).toFloat()       // queima
                s += (bright * 0.40 * sin((fire + 1) * ph)).toFloat()
                s += (bright * 0.34 * sin((fire + 2) * ph)).toFloat()
                s += (bright * 0.26 * sin((fire * 2) * ph)).toFloat()

                // Ruído de escape proporcional à rotação e à carga
                val rpmN = (rpm / redlineRpm).coerceIn(0f, 1f)
                val noise = (rng.nextFloat() - 0.5f) * 2f
                s += noise * (0.08f + 0.22f * load) * (0.3f + 0.7f * rpmN)

                // ── Estalos ("pops"/cuspidas) ──────────────────────────────────
                // Dispara no OVERRUN (soltou/regen) e no acelerador FUNDO (WOT).
                // Cada pop = burst de ruído + thump grave (~110 Hz), decaindo rápido.
                val overrunFire = overrun && crackle > 0f && rng.nextFloat() < crackle * 0.0042f
                val accelFire = !regen && load > 0.6f && popAccel > 0f && rng.nextFloat() < popAccel * 0.0026f
                if (overrunFire || accelFire) {
                    popEnv = if (accelFire) 1.0f else 0.85f
                    popCoef = 1f - exp(-1f / (SR * 0.018f))
                    popPhase = 0.0
                }
                if (popEnv > 0.0001f) {
                    popPhase += 110.0 / SR
                    val amp = if (regen || overrunSamples > 0) crackle else popAccel
                    val pop = ((rng.nextFloat() - 0.5f) * 2f) * 0.75f + sin(2.0 * PI * popPhase).toFloat() * 0.5f
                    s += pop * popEnv * amp * 1.4f
                    popEnv -= popEnv * popCoef
                }

                // Low-pass (timbre) + rasp/drive + volume + soft-clip.
                lpState += (s - lpState) * lpA
                var o = lpState * 0.26f * vol * carGain
                o = tanh(o * (1.4f + rasp * 3.0f))   // rasp = grit do escapamento mexido
                buf[i] = (o.coerceIn(-1f, 1f) * 32767f).toInt().toShort()
            }
            liveRpm = rpm
            liveThrottle = thr
            try { t.write(buf, 0, BLOCK) } catch (_: Exception) { break }
        }
        try { t.stop(); t.release() } catch (_: Exception) {}
        if (track === t) track = null
    }

    // ── Persistência ───────────────────────────────────────────────────────────

    private fun prefs(ctx: Context) =
        ctx.getSharedPreferences(SharedPreferencesKeys.PREFS_NAME, Context.MODE_PRIVATE)

    fun loadConfig(ctx: Context) {
        val p = prefs(ctx)
        enabled    = p.getBoolean(SharedPreferencesKeys.V8_ENABLED, false)
        masterVol  = p.getFloat(SharedPreferencesKeys.V8_MASTER_VOL, masterVol)
        idleRpm    = p.getFloat(SharedPreferencesKeys.V8_IDLE_RPM, idleRpm)
        redlineRpm = p.getFloat(SharedPreferencesKeys.V8_REDLINE_RPM, redlineRpm)
        powerFullKw= p.getFloat(SharedPreferencesKeys.V8_POWER_FULL_KW, powerFullKw)
        speedToRpm = p.getFloat(SharedPreferencesKeys.V8_SPEED_TO_RPM, speedToRpm)
        revBoost   = p.getFloat(SharedPreferencesKeys.V8_REV_BOOST, revBoost)
        rumble     = p.getFloat(SharedPreferencesKeys.V8_RUMBLE, rumble)
        loadBright = p.getFloat(SharedPreferencesKeys.V8_LOAD_BRIGHT, loadBright)
        regenVol   = p.getFloat(SharedPreferencesKeys.V8_REGEN_VOL, regenVol)
        crackle    = p.getFloat(SharedPreferencesKeys.V8_CRACKLE, crackle)
        popAccel   = p.getFloat(SharedPreferencesKeys.V8_POP_ACCEL, popAccel)
        rasp       = p.getFloat(SharedPreferencesKeys.V8_RASP, rasp)
        toneHz     = p.getFloat(SharedPreferencesKeys.V8_TONE_HZ, toneHz)
        firingOrder= p.getFloat(SharedPreferencesKeys.V8_FIRING_ORDER, firingOrder)
        currentPreset = p.getString(SharedPreferencesKeys.V8_PRESET, currentPreset) ?: currentPreset
    }

    fun setEnabled(ctx: Context, on: Boolean) {
        enabled = on
        prefs(ctx).edit().putBoolean(SharedPreferencesKeys.V8_ENABLED, on).apply()
        if (on) start(ctx) else stop()
    }

    /** Grava um parâmetro (chave de prefs) e aplica no campo ao vivo. */
    fun setParam(ctx: Context, key: String, value: Float) {
        when (key) {
            SharedPreferencesKeys.V8_MASTER_VOL  -> masterVol = value
            SharedPreferencesKeys.V8_IDLE_RPM    -> idleRpm = value
            SharedPreferencesKeys.V8_REDLINE_RPM -> redlineRpm = value
            SharedPreferencesKeys.V8_POWER_FULL_KW -> powerFullKw = value
            SharedPreferencesKeys.V8_SPEED_TO_RPM -> speedToRpm = value
            SharedPreferencesKeys.V8_REV_BOOST   -> revBoost = value
            SharedPreferencesKeys.V8_RUMBLE      -> rumble = value
            SharedPreferencesKeys.V8_LOAD_BRIGHT -> loadBright = value
            SharedPreferencesKeys.V8_REGEN_VOL   -> regenVol = value
            SharedPreferencesKeys.V8_CRACKLE     -> crackle = value
            SharedPreferencesKeys.V8_POP_ACCEL   -> popAccel = value
            SharedPreferencesKeys.V8_RASP        -> rasp = value
            SharedPreferencesKeys.V8_TONE_HZ     -> toneHz = value
            SharedPreferencesKeys.V8_FIRING_ORDER -> firingOrder = value
        }
        prefs(ctx).edit().putFloat(key, value).apply()
    }
}
