package br.com.redesurftank.ecotrip.managers

import android.Manifest
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder

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

    @Volatile private var liveActive = false
    @Volatile private var recActive = false
    @Volatile private var capturing = false
    private var capThread: Thread? = null
    private var track: AudioTrack? = null
    private var appCtx: Context? = null
    @Volatile private var publisher: ((ByteArray) -> Unit)? = null
    private val lock = Any()

    val isActive: Boolean get() = liveActive
    val isRecording: Boolean get() = recActive

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
        capturing = true
        capThread = Thread { captureLoop() }.apply { isDaemon = true; name = "audio-capture"; start() }
    }

    private fun maybeStopCapture() {
        if (!liveActive && !recActive) {
            capturing = false   // o loop sai sozinho ao checar a flag
            capThread = null
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
        var rec: AudioRecord? = null
        for (src in intArrayOf(
            MediaRecorder.AudioSource.VOICE_RECOGNITION,
            MediaRecorder.AudioSource.MIC,
            MediaRecorder.AudioSource.DEFAULT)) {
            try {
                val r = AudioRecord(src, RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, bufBytes)
                if (r.state == AudioRecord.STATE_INITIALIZED) { rec = r; AppLogger.i(TAG, "AudioRecord src=$src OK"); break }
                r.release()
            } catch (e: Exception) { AppLogger.w(TAG, "src=$src falhou: ${e.message}") }
        }
        if (rec == null) { AppLogger.w(TAG, "nenhum AudioSource inicializou"); abortCapture(); return }
        val buf = ShortArray(FRAME)
        val bytes = ByteArray(FRAME * 2)
        try { rec.startRecording() } catch (e: Exception) {
            AppLogger.w(TAG, "startRecording falhou: ${e.message}"); rec.release(); abortCapture(); return
        }
        while (capturing) {
            val n = rec.read(buf, 0, buf.size)
            if (n <= 0) continue
            var bi = 0
            for (i in 0 until n) {
                val v = buf[i].toInt()
                bytes[bi++] = (v and 0xFF).toByte()
                bytes[bi++] = ((v shr 8) and 0xFF).toByte()
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

    private fun abortCapture() = synchronized(lock) {
        capturing = false
        liveActive = false
        if (recActive) { recActive = false; appCtx?.let { CabinRecorder.stop(it) } }
        try { track?.stop(); track?.release() } catch (_: Exception) {}
        track = null; publisher = null; capThread = null
    }
}
