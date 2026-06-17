package br.com.redesurftank.ecotrip.managers

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder

// Escuta ao vivo da cabine: captura o mic da central e publica PCM em audio/c2p
// (carro→fone); toca em audio/p2c (fone→carro) no alto-falante. Half-duplex
// controlado pelo fone. Formato fixo: PCM16 LE mono 8kHz, frames de 20ms.
object CarAudioRelay {
    private const val TAG = "CarAudioRelay"
    private const val RATE = 8000
    private const val FRAME = RATE / 50   // 160 samples = 20ms

    @Volatile private var active = false
    private var recThread: Thread? = null
    private var track: AudioTrack? = null
    @Volatile private var publisher: ((ByteArray) -> Unit)? = null

    val isActive: Boolean get() = active

    /** Liga a sessão. Retorna "ok", "already" ou "error: ...". */
    fun start(ctx: Context, publish: (ByteArray) -> Unit): String {
        if (active) return "already"
        if (ctx.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED)
            return "error: RECORD_AUDIO não concedida"
        publisher = publish
        active = true
        setupTrack()
        recThread = Thread { captureLoop() }.apply { isDaemon = true; name = "audio-c2p"; start() }
        AppLogger.i(TAG, "sessão de áudio iniciada (8kHz mono)")
        return "ok"
    }

    fun stop() {
        if (!active) return
        active = false
        recThread = null
        try { track?.stop(); track?.release() } catch (_: Exception) {}
        track = null
        publisher = null
        AppLogger.i(TAG, "sessão de áudio encerrada")
    }

    /** Frame PCM vindo do fone (audio/p2c) → toca no alto-falante do carro. */
    fun onIncomingFrame(pcm: ByteArray) {
        if (!active) return
        try { track?.write(pcm, 0, pcm.size) } catch (_: Exception) {}
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
        if (rec == null) { AppLogger.w(TAG, "nenhum AudioSource inicializou"); active = false; return }
        val buf = ShortArray(FRAME)
        val bytes = ByteArray(FRAME * 2)
        try { rec.startRecording() } catch (e: Exception) { AppLogger.w(TAG, "startRecording falhou: ${e.message}"); active = false; rec.release(); return }
        while (active) {
            val n = rec.read(buf, 0, buf.size)
            if (n <= 0) continue
            var bi = 0
            for (i in 0 until n) {
                val v = buf[i].toInt()
                bytes[bi++] = (v and 0xFF).toByte()
                bytes[bi++] = ((v shr 8) and 0xFF).toByte()
            }
            val out = if (n == FRAME) bytes else bytes.copyOf(n * 2)
            try { publisher?.invoke(out) } catch (_: Exception) {}
        }
        try { rec.stop(); rec.release() } catch (_: Exception) {}
    }
}
