package br.com.redesurftank.ecotrip.managers

import android.content.Context
import br.com.redesurftank.ecotrip.models.SharedPreferencesKeys
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.RandomAccessFile

// Gravação local da cabine por sessão (controlada manualmente pelo iOS).
// Recebe frames PCM16 LE mono 8kHz vindos da captura única do CarAudioRelay e
// grava em WAV no armazenamento interno do app. Nada sai do carro sozinho — o
// download é sob demanda pela LAN (/api/rec/*) ou fallback bridge.
object CabinRecorder {
    private const val TAG = "CabinRecorder"
    private const val RATE = 8000
    private const val CHANNELS = 1
    private const val BITS = 16
    private const val QUOTA_BYTES = 1_500L * 1024 * 1024   // ~1.5GB, rotaciona o mais antigo
    private const val SEG_MIN_DEFAULT = 5
    private const val SEG_MIN_LO = 1
    private const val SEG_MIN_HI = 60
    @Volatile private var segmentMs = SEG_MIN_DEFAULT * 60_000L   // duração do segmento (configurável)

    @Volatile private var active = false
    private var raf: RandomAccessFile? = null
    private var dataBytes = 0L
    private var startMs = 0L
    private var currentId: String = ""
    private var dir: File? = null
    private var appCtx: Context? = null
    private val lock = Any()

    val isRecording: Boolean get() = active
    val sessionId: String get() = currentId

    private fun recDir(ctx: Context): File =
        File(ctx.filesDir, "recordings").apply { mkdirs() }

    /** Minutos por arquivo (persistido). Aplica na próxima rolagem (e nas futuras). */
    fun getSegmentMin(ctx: Context): Int {
        val m = ctx.getSharedPreferences(SharedPreferencesKeys.PREFS_NAME, Context.MODE_PRIVATE)
            .getInt(SharedPreferencesKeys.REC_SEGMENT_MIN, SEG_MIN_DEFAULT)
            .coerceIn(SEG_MIN_LO, SEG_MIN_HI)
        segmentMs = m * 60_000L
        return m
    }

    fun setSegmentMin(ctx: Context, min: Int): Int {
        val m = min.coerceIn(SEG_MIN_LO, SEG_MIN_HI)
        segmentMs = m * 60_000L
        ctx.getSharedPreferences(SharedPreferencesKeys.PREFS_NAME, Context.MODE_PRIVATE)
            .edit().putInt(SharedPreferencesKeys.REC_SEGMENT_MIN, m).apply()
        AppLogger.i(TAG, "segmento = ${m}min")
        return m
    }

    /** Abre uma nova sessão. Retorna "ok:<id>" ou "error: ...". */
    fun start(ctx: Context): String = synchronized(lock) {
        if (active) return "ok:$currentId"   // já gravando — idempotente
        appCtx = ctx.applicationContext
        getSegmentMin(ctx)   // recarrega a duração persistida
        return try {
            openSegmentLocked(ctx)
            active = true
            AppLogger.i(TAG, "gravação iniciada id=$currentId (segmentos de ${segmentMs / 60000}min)")
            "ok:$currentId"
        } catch (e: Exception) {
            active = false
            "error: ${e.message}"
        }
    }

    /** Abre um arquivo WAV novo (segmento) e zera os contadores. Exige o lock. */
    private fun openSegmentLocked(ctx: Context) {
        val d = recDir(ctx); dir = d
        val id = System.currentTimeMillis().toString()
        val f = File(d, "$id.wav")
        val r = RandomAccessFile(f, "rw")
        r.setLength(0)
        r.write(ByteArray(44))   // placeholder do header, corrigido ao fechar
        raf = r
        dataBytes = 0L
        startMs = System.currentTimeMillis()
        currentId = id
    }

    /** Fecha o segmento atual (corrige header + indexa) e abre o próximo. Exige o lock. */
    private fun rollSegmentLocked() {
        val ctx = appCtx ?: return
        val r = raf ?: return
        val id = currentId
        val durMs = System.currentTimeMillis() - startMs
        try { writeWavHeader(r, dataBytes); r.close() } catch (e: Exception) {
            AppLogger.w(TAG, "roll: patch header falhou: ${e.message}")
        }
        appendIndex(ctx, id, startMs, durMs, dataBytes + 44)
        enforceQuota(ctx)
        try { openSegmentLocked(ctx) } catch (e: Exception) {
            AppLogger.w(TAG, "roll: abrir próximo segmento falhou: ${e.message}"); active = false; return
        }
        AppLogger.i(TAG, "segmento $id fechado (${durMs}ms) → novo $currentId")
    }

    /** Frame PCM do loop de captura (no-op se não estiver gravando). */
    fun feed(pcm: ByteArray, len: Int = pcm.size) {
        if (!active) return
        synchronized(lock) {
            val r = raf ?: return
            try { r.write(pcm, 0, len); dataBytes += len } catch (_: Exception) {}
            if (System.currentTimeMillis() - startMs >= segmentMs) rollSegmentLocked()
        }
    }

    /** Finaliza a sessão, corrige o header WAV e atualiza o index. */
    fun stop(ctx: Context): String = synchronized(lock) {
        if (!active) return "ok: nada gravando"
        active = false
        val r = raf; raf = null
        val id = currentId
        val durMs = System.currentTimeMillis() - startMs
        try {
            r?.let { writeWavHeader(it, dataBytes); it.close() }
        } catch (e: Exception) {
            AppLogger.w(TAG, "patch header falhou: ${e.message}")
        }
        appendIndex(ctx, id, startMs, durMs, dataBytes + 44)
        enforceQuota(ctx)
        AppLogger.i(TAG, "gravação encerrada id=$id dur=${durMs}ms bytes=$dataBytes")
        "ok:$id dur=${durMs}ms bytes=${dataBytes + 44}"
    }

    fun fileFor(ctx: Context, id: String): File? {
        val f = File(recDir(ctx), "$id.wav")
        return if (f.exists()) f else null
    }

    /**
     * Sobe o WAV pro bridge sob demanda (fallback WAN quando o fone não está na
     * LAN). Autoriza via nonce de uso único (X-Rec-Token) que o bridge mandou no
     * cmd/rec_fetch — sem precisar do token do bridge no carro. Stream sem
     * carregar o arquivo na memória. Retorna "ok:..." ou "error: ...".
     */
    fun uploadToBridge(ctx: Context, id: String, token: String, base: String): String {
        if (base.isBlank()) return "error: bridge não configurado"
        val safe = id.filter { it.isDigit() }
        val f = fileFor(ctx, safe) ?: return "error: gravação $safe não encontrada"
        return try {
            val url = java.net.URL("${base.trimEnd('/')}/api/rec/upload?id=$safe")
            val conn = url.openConnection() as java.net.HttpURLConnection
            conn.requestMethod = "POST"
            conn.doOutput = true
            conn.connectTimeout = 15_000
            conn.readTimeout = 120_000
            conn.setRequestProperty("Content-Type", "audio/wav")
            conn.setRequestProperty("X-Rec-Token", token)
            conn.setFixedLengthStreamingMode(f.length())
            f.inputStream().use { input -> conn.outputStream.use { input.copyTo(it, 64 * 1024) } }
            val code = conn.responseCode
            if (code in 200..299) "ok:$safe (${f.length()} bytes)" else "error: bridge HTTP $code"
        } catch (e: Exception) {
            "error: ${e.message}"
        }
    }

    /** JSON do index (lista de sessões, mais recente primeiro). */
    fun listJson(ctx: Context): String {
        val arr = readIndex(ctx)
        // anexa flag "recording" da sessão atual (ainda sem entry no index)
        val out = JSONObject()
        out.put("recording", active)
        out.put("currentId", if (active) currentId else JSONObject.NULL)
        out.put("sessions", arr)
        return out.toString()
    }

    // ── WAV header (RIFF/WAVE PCM) ──────────────────────────────────────────
    private fun writeWavHeader(r: RandomAccessFile, dataLen: Long) {
        val byteRate = RATE * CHANNELS * BITS / 8
        val blockAlign = CHANNELS * BITS / 8
        val riffLen = 36 + dataLen
        r.seek(0)
        r.writeBytes("RIFF")
        r.write(le32(riffLen.toInt()))
        r.writeBytes("WAVE")
        r.writeBytes("fmt ")
        r.write(le32(16))               // subchunk1 size (PCM)
        r.write(le16(1))                // audio format = PCM
        r.write(le16(CHANNELS))
        r.write(le32(RATE))
        r.write(le32(byteRate))
        r.write(le16(blockAlign))
        r.write(le16(BITS))
        r.writeBytes("data")
        r.write(le32(dataLen.toInt()))
    }

    private fun le32(v: Int) = byteArrayOf(
        (v and 0xFF).toByte(), ((v shr 8) and 0xFF).toByte(),
        ((v shr 16) and 0xFF).toByte(), ((v shr 24) and 0xFF).toByte())

    private fun le16(v: Int) = byteArrayOf((v and 0xFF).toByte(), ((v shr 8) and 0xFF).toByte())

    // ── Index (recordings/index.json) ──────────────────────────────────────
    private fun indexFile(ctx: Context) = File(recDir(ctx), "index.json")

    private fun readIndex(ctx: Context): JSONArray {
        val f = indexFile(ctx)
        if (!f.exists()) return JSONArray()
        return try { JSONArray(f.readText()) } catch (_: Exception) { JSONArray() }
    }

    private fun appendIndex(ctx: Context, id: String, start: Long, durMs: Long, bytes: Long) {
        try {
            val arr = readIndex(ctx)
            val o = JSONObject()
                .put("id", id).put("startMs", start)
                .put("durationMs", durMs).put("bytes", bytes)
            // mais recente primeiro
            val merged = JSONArray().put(o)
            for (i in 0 until arr.length()) merged.put(arr.get(i))
            indexFile(ctx).writeText(merged.toString())
        } catch (e: Exception) {
            AppLogger.w(TAG, "appendIndex falhou: ${e.message}")
        }
    }

    /** Mantém o diretório abaixo da cota apagando as sessões mais antigas. */
    private fun enforceQuota(ctx: Context) {
        try {
            val d = recDir(ctx)
            var total = d.listFiles()?.filter { it.extension == "wav" }?.sumOf { it.length() } ?: 0L
            if (total <= QUOTA_BYTES) return
            val arr = readIndex(ctx)
            // remove do fim (mais antigos) até caber
            val kept = ArrayList<JSONObject>()
            for (i in 0 until arr.length()) kept.add(arr.getJSONObject(i))
            while (total > QUOTA_BYTES && kept.isNotEmpty()) {
                val old = kept.removeAt(kept.size - 1)
                val f = File(d, "${old.getString("id")}.wav")
                val len = f.length()
                if (f.delete()) total -= len
            }
            val out = JSONArray(); kept.forEach { out.put(it) }
            indexFile(ctx).writeText(out.toString())
        } catch (e: Exception) {
            AppLogger.w(TAG, "enforceQuota falhou: ${e.message}")
        }
    }
}
