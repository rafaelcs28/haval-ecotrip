package br.com.redesurftank.ecotrip.managers

import android.Manifest
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import br.com.redesurftank.ecotrip.models.SharedPreferencesKeys

// Captura ÚNICA do mic da central com dois sinks independentes:
//   • live  → escuta ao vivo (publica PCM em audio/c2p, carro→fone)
//   • rec   → gravação local da viagem (CabinRecorder grava WAV)
// Um único AudioRecord alimenta os dois — não dá pra abrir duas fontes no mesmo
// mic, e isso evita disputa/wedge. O loop roda enquanto QUALQUER sink ativo.
// Formato fixo: PCM16 LE mono 8kHz, frames de 20ms. AudioTrack (alto-falante,
// audio/p2c fone→carro) só existe no modo live (half-duplex).
object CarAudioRelay {
    private const val TAG = "CarAudioRelay"
    private const val RATE = 8000
    private const val FRAME = RATE / 50   // 160 samples = 20ms
    private val CANDIDATE_SOURCES = intArrayOf(
        MediaRecorder.AudioSource.VOICE_RECOGNITION,
        MediaRecorder.AudioSource.MIC,
        MediaRecorder.AudioSource.DEFAULT,
        MediaRecorder.AudioSource.VOICE_COMMUNICATION,
        MediaRecorder.AudioSource.CAMCORDER)

    @Volatile private var liveActive = false
    @Volatile private var recActive = false
    @Volatile private var capturing = false
    private var capThread: Thread? = null
    private var track: AudioTrack? = null
    private var appCtx: Context? = null
    @Volatile private var publisher: ((ByteArray) -> Unit)? = null
    private val lock = Any()

    // Ganho linear do mic (1.0 = neutro). Mic da cabine costuma ser baixo; o
    // usuário ajusta pelo app. Clampado em 0.5..16.0 e aplicado por amostra com
    // saturação (sem wrap) na captura — afeta escuta ao vivo E gravação.
    @Volatile private var micGain = 1.0f
    private const val GAIN_MIN = 0.5f
    private const val GAIN_MAX = 16.0f

    // AGC (ganho automático): nivela o volume mirando um pico-alvo, com ataque
    // rápido (reduz) e release lento (sobe). Multiplica DEPOIS do micGain manual.
    @Volatile private var agcEnabled = false
    private var agcGain = 1.0f
    private const val AGC_TARGET = 7000f   // pico-alvo (de 32768)
    private const val AGC_MIN = 0.5f
    private const val AGC_MAX = 12.0f
    private const val AGC_ATTACK = 0.30f   // ao reduzir (sinal alto) — rápido
    private const val AGC_RELEASE = 0.04f  // ao subir (sinal baixo) — lento, sem bombear

    val isActive: Boolean get() = liveActive
    val isRecording: Boolean get() = recActive

    fun getAgc(ctx: Context): Boolean =
        ctx.getSharedPreferences(SharedPreferencesKeys.PREFS_NAME, Context.MODE_PRIVATE)
            .getBoolean(SharedPreferencesKeys.AGC_ENABLED, false)
            .also { agcEnabled = it }

    fun setAgc(ctx: Context, on: Boolean): Boolean {
        agcEnabled = on
        if (!on) agcGain = 1.0f
        ctx.getSharedPreferences(SharedPreferencesKeys.PREFS_NAME, Context.MODE_PRIVATE)
            .edit().putBoolean(SharedPreferencesKeys.AGC_ENABLED, on).apply()
        AppLogger.i(TAG, "AGC = $on")
        return on
    }

    /** Lê o ganho persistido (default 1.0). */
    fun getGain(ctx: Context): Float {
        return ctx.getSharedPreferences(SharedPreferencesKeys.PREFS_NAME, Context.MODE_PRIVATE)
            .getFloat(SharedPreferencesKeys.MIC_GAIN, 1.0f)
            .also { micGain = it.coerceIn(GAIN_MIN, GAIN_MAX) }
    }

    /** Define+persiste o ganho. Aplica na hora (afeta captura em andamento). Retorna o valor efetivo. */
    fun setGain(ctx: Context, g: Float): Float {
        val v = g.coerceIn(GAIN_MIN, GAIN_MAX)
        micGain = v
        ctx.getSharedPreferences(SharedPreferencesKeys.PREFS_NAME, Context.MODE_PRIVATE)
            .edit().putFloat(SharedPreferencesKeys.MIC_GAIN, v).apply()
        AppLogger.i(TAG, "mic gain = $v")
        return v
    }

    // ── Escuta ao vivo ─────────────────────────────────────────────────────
    /** Liga a escuta. Retorna "ok", "already" ou "error: ...". */
    fun startLive(ctx: Context, publish: (ByteArray) -> Unit): String = synchronized(lock) {
        if (liveActive) return "already"
        if (!ShizukuPerms.ensureGranted(ctx, Manifest.permission.RECORD_AUDIO))
            return "error: RECORD_AUDIO não concedida"
        appCtx = ctx.applicationContext
        publisher = publish
        liveActive = true
        setupTrack()
        ensureCapture()
        AppLogger.i(TAG, "escuta ao vivo iniciada (8kHz mono)")
        return "ok"
    }

    fun stopLive() = synchronized(lock) {
        if (!liveActive) return
        liveActive = false
        try { track?.stop(); track?.release() } catch (_: Exception) {}
        track = null
        publisher = null
        AppLogger.i(TAG, "escuta ao vivo encerrada")
        maybeStopCapture()
    }

    // ── Gravação local ───────────────────────────────────────────────────────
    /** Inicia a gravação da sessão. Retorna "ok:<id>" ou "error: ...". */
    fun startRec(ctx: Context): String = synchronized(lock) {
        if (recActive) return "ok:${CabinRecorder.sessionId}"
        if (!ShizukuPerms.ensureGranted(ctx, Manifest.permission.RECORD_AUDIO))
            return "error: RECORD_AUDIO não concedida"
        appCtx = ctx.applicationContext
        val r = CabinRecorder.start(ctx)
        if (r.startsWith("error")) return r
        recActive = true
        ensureCapture()
        AppLogger.i(TAG, "gravação iniciada ($r)")
        return r
    }

    fun stopRec(): String = synchronized(lock) {
        if (!recActive) return "ok: nada gravando"
        recActive = false
        val ctx = appCtx
        val r = if (ctx != null) CabinRecorder.stop(ctx) else "ok: sem contexto"
        AppLogger.i(TAG, "gravação encerrada ($r)")
        maybeStopCapture()
        return r
    }

    /** Frame PCM vindo do fone (audio/p2c) → toca no alto-falante do carro. */
    fun onIncomingFrame(pcm: ByteArray) {
        if (!liveActive) return
        try { track?.write(pcm, 0, pcm.size) } catch (_: Exception) {}
    }

    // ── Captura (uma fonte, fan-out) ──────────────────────────────────────────
    private fun ensureCapture() {
        if (capturing) return
        appCtx?.let { getGain(it); getAgc(it) }   // recarrega ganho + AGC persistidos
        // FGS-microphone: sem isso o A14+ entrega zeros (mute por policy).
        try { br.com.redesurftank.ecotrip.services.CarTelemetryService.current?.enableMicForeground() } catch (_: Exception) {}
        capturing = true
        capThread = Thread { captureLoop() }.apply { isDaemon = true; name = "audio-capture"; start() }
    }

    private fun maybeStopCapture() {
        if (!liveActive && !recActive) {
            capturing = false   // o loop sai sozinho ao checar a flag
            capThread = null
            try { br.com.redesurftank.ecotrip.services.CarTelemetryService.current?.disableMicForeground() } catch (_: Exception) {}
        }
    }

    private fun setupTrack() {
        val minBuf = AudioTrack.getMinBufferSize(RATE, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
        track = AudioTrack(
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build(),
            AudioFormat.Builder()
                .setSampleRate(RATE)
                .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT).build(),
            maxOf(minBuf, RATE), AudioTrack.MODE_STREAM, AudioManager.AUDIO_SESSION_ID_GENERATE)
        try { track?.play() } catch (e: Exception) { AppLogger.w(TAG, "AudioTrack play falhou: ${e.message}") }
    }

    private fun captureLoop() {
        val minBuf = AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val bufBytes = maxOf(minBuf, FRAME * 2 * 4)
        val rec = openBestSource(bufBytes)
        if (rec == null) { AppLogger.w(TAG, "nenhuma fonte de áudio utilizável"); abortCapture(); return }
        val buf = ShortArray(FRAME)
        val bytes = ByteArray(FRAME * 2)
        while (capturing) {
            val n = rec.read(buf, 0, buf.size)
            if (n <= 0) continue
            val g = micGain
            val agc = agcEnabled
            val ag = agcGain
            var bi = 0
            var framePeak = 0
            for (i in 0 until n) {
                var v = buf[i].toInt()
                if (g != 1.0f) v = (v * g).toInt().coerceIn(-32768, 32767)  // saturação, sem wrap
                if (agc && ag != 1.0f) v = (v * ag).toInt().coerceIn(-32768, 32767)
                val a = if (v < 0) -v else v
                if (a > framePeak) framePeak = a
                bytes[bi++] = (v and 0xFF).toByte()
                bytes[bi++] = ((v shr 8) and 0xFF).toByte()
            }
            // Atualiza o ganho do AGC pro próximo frame (feedback: já inclui ag atual).
            if (agc && framePeak > 30) {
                val desired = (ag * AGC_TARGET / framePeak).coerceIn(AGC_MIN, AGC_MAX)
                val rate = if (desired < ag) AGC_ATTACK else AGC_RELEASE
                agcGain = ag + (desired - ag) * rate
            }
            val outLen = n * 2
            // fan-out: escuta ao vivo + gravação local (cada um independente)
            if (liveActive) {
                val frame = if (outLen == bytes.size) bytes else bytes.copyOf(outLen)
                try { publisher?.invoke(frame) } catch (_: Exception) {}
            }
            if (recActive) CabinRecorder.feed(bytes, outLen)
        }
        try { rec.stop(); rec.release() } catch (_: Exception) {}
    }

    // Sonda cada AudioSource por ~500ms e escolhe a que entrega sinal REAL.
    // Num HU automotivo VOICE_RECOGNITION costuma inicializar mas devolver zeros
    // (escuta/gravação mudas) — pegar a primeira que inicializa não basta. Um ADC
    // vivo sempre tem ruído de fundo (pico > 0) mesmo no silêncio; fonte zerada dá
    // pico exatamente 0. Escolhe a primeira com pico > SILENCE_FLOOR; senão, a de
    // maior pico (último recurso). A fonte retornada já está em startRecording().
    private fun openBestSource(bufBytes: Int): AudioRecord? {
        val SILENCE_FLOOR = 8
        val probe = ShortArray(2048)
        var bestSrc = -1
        var bestPeak = -1
        for (src in CANDIDATE_SOURCES) {
            val peak = probeSource(src, bufBytes, probe)
            AppLogger.i(TAG, "probe src=$src peak=$peak")
            if (peak < 0) continue                       // não inicializou
            if (peak > SILENCE_FLOOR) {                  // sinal real → usa já
                AppLogger.i(TAG, "fonte escolhida src=$src (sinal real, peak=$peak)")
                return openSource(src, bufBytes)
            }
            if (peak > bestPeak) { bestPeak = peak; bestSrc = src }
        }
        if (bestSrc >= 0) {
            AppLogger.w(TAG, "nenhuma fonte com sinal nítido; usando melhor src=$bestSrc pico=$bestPeak (provável silêncio do HU)")
            return openSource(bestSrc, bufBytes)
        }
        return null
    }

    // Neste HU o mic FÍSICO da cabine é o TYPE_BUILTIN_MIC ("bottom") — é o único
    // que entrega PCM real. Os TYPE_BUS (bus*_vr_in, etc.) são pipelines de
    // roteamento interno do barramento, vários mudos (VR/COMM devolvem zeros).
    // Por isso preferimos BUILTIN_MIC; se não existir, deixa o default (sem forçar
    // BUS, que rotearia pra um device mudo).
    private fun preferInputDevice(rec: AudioRecord) {
        val ctx = appCtx ?: return
        try {
            val am = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            val devs = am.getDevices(AudioManager.GET_DEVICES_INPUTS)
            val builtin = devs.firstOrNull { it.type == android.media.AudioDeviceInfo.TYPE_BUILTIN_MIC }
            if (builtin != null) {
                val ok = rec.setPreferredDevice(builtin)
                AppLogger.i(TAG, "setPreferredDevice type=${builtin.type} addr=${builtin.address} ok=$ok")
            }
        } catch (e: Exception) { AppLogger.w(TAG, "preferInputDevice falhou: ${e.message}") }
    }

    /** Abre+grava a fonte e mede o pico em ~500ms. Retorna pico, ou -1 se não inicializou. */
    private fun probeSource(src: Int, bufBytes: Int, probe: ShortArray): Int {
        var r: AudioRecord? = null
        try {
            r = AudioRecord(src, RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, bufBytes)
            if (r.state != AudioRecord.STATE_INITIALIZED) return -1
            preferInputDevice(r)
            r.startRecording()
            var peak = 0
            val deadline = System.currentTimeMillis() + 500
            while (System.currentTimeMillis() < deadline) {
                val n = r.read(probe, 0, probe.size, AudioRecord.READ_NON_BLOCKING)
                if (n > 0) { for (i in 0 until n) { val a = kotlin.math.abs(probe[i].toInt()); if (a > peak) peak = a } }
                else Thread.sleep(20)
            }
            return peak
        } catch (e: Exception) {
            AppLogger.w(TAG, "src=$src probe falhou: ${e.message}"); return -1
        } finally {
            try { r?.stop() } catch (_: Exception) {}
            try { r?.release() } catch (_: Exception) {}
        }
    }

    /** Abre a fonte e já deixa em startRecording(). null se falhar. */
    private fun openSource(src: Int, bufBytes: Int): AudioRecord? {
        return try {
            val r = AudioRecord(src, RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, bufBytes)
            if (r.state != AudioRecord.STATE_INITIALIZED) { r.release(); return null }
            preferInputDevice(r)
            r.startRecording(); r
        } catch (e: Exception) { AppLogger.w(TAG, "openSource src=$src falhou: ${e.message}"); null }
    }

    private fun abortCapture() = synchronized(lock) {
        capturing = false
        liveActive = false
        if (recActive) { recActive = false; appCtx?.let { CabinRecorder.stop(it) } }
        try { track?.stop(); track?.release() } catch (_: Exception) {}
        track = null; publisher = null; capThread = null
    }
}
