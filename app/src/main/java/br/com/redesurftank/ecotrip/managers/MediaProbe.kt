package br.com.redesurftank.ecotrip.managers

import android.content.Context
import android.os.Bundle
import android.os.SystemClock
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import org.json.JSONObject

/**
 * Lê a mídia tocando no carro pelo provider do Haval Impulse (mesma fonte de onde o tema
 * dele tira capa e nome — cobre o player ativo, seja Android Auto, Spotify ou USB) e
 * publica no MQTT.
 *
 * Contrato: `call("virtualValue", extras{key="app.media.now_playing"})` → ok, json, updatedAtMs.
 *
 * A CAPA (`app.media.album_art`) NÃO é lida aqui de propósito: vem como data-URI base64
 * e são centenas de KB por faixa. Num tópico MQTT que atravessa 4G isso é caro pra um
 * display de uma linha. Se um dia a capa for exibida, o caminho é servi-la sob demanda
 * por HTTP, não empurrar no polling.
 */
object MediaProbe {
    private const val TAG = "MediaProbe"
    private const val URI = "content://br.com.redesurftank.havalshisuku.status/connectivity"
    private const val KEY = "app.media.now_playing"

    /** Metadado é leve. 5s dá troca de faixa quase imediata sem pesar. */
    private const val INTERVALO_S = 5L

    private val exec = Executors.newSingleThreadScheduledExecutor { r ->
        Thread(r, "media-probe").apply { isDaemon = true }
    }
    private var ctx: Context? = null
    private var tarefa: ScheduledFuture<*>? = null

    @Volatile private var falhas = 0
    @Volatile private var ultimoHash = ""      // evita republicar faixa idêntica
    @Volatile private var ultimaPubMs = 0L
    @Volatile private var tocando = false

    fun start(context: Context) {
        ctx = context.applicationContext
        if (tarefa != null) return
        tarefa = exec.scheduleWithFixedDelay({
            runCatching { tick() }.onFailure { AppLogger.w(TAG, "tick: ${it.message}") }
        }, 7, INTERVALO_S, TimeUnit.SECONDS)
        AppLogger.i(TAG, "probe de mídia ligado (${INTERVALO_S}s)")
    }

    fun parar() { tarefa?.cancel(false); tarefa = null }

    private fun tick() {
        val c = ctx ?: return
        // Backoff sem desistir — mesma lição do NavProbe: latch permanente a partir de
        // falha transitória (OTA do Impulse) emudece o recurso pra sempre e em silêncio.
        if (falhas >= 3 && (falhas % 8) != 0) { falhas++; return }

        // Mesmo vício do NavProbe: sem prazo, provider pendurado prendia a thread única
        // e a mídia parava de ser publicada até o app reiniciar. Ver ImpulseCall.
        val b: Bundle? = ImpulseCall.call(c, "virtualValue", Bundle().apply { putString("key", KEY) })
        if (b == null) {
            falhas++
            publicarParado("provider não respondeu")
            if (falhas <= 3) AppLogger.w(TAG, "provider de mídia sem resposta (${falhas}x)")
            return
        }
        falhas = 0
        if (!b.getBoolean("ok")) { publicarParado("provider respondeu ok=false"); return }

        val cru = b.getString("json") ?: "{}"
        if (cru.length < 3) { publicarParado("nada tocando"); return }

        val j = JSONObject(cru)
        val playing = j.optBoolean("isPlaying", false)
        val titulo  = j.optString("title", "")
        if (titulo.isEmpty() && !playing) { publicarParado("sem faixa"); return }

        // Posição resolvida AQUI. `positionUpdatedAtMs` vem em SystemClock.elapsedRealtime(),
        // que é monotônico DESTE device — o bridge, o iPhone e a página do link não têm esse
        // relógio, então extrapolar do outro lado daria posição errada. Converto pra
        // âncora em tempo de parede e mando junto.
        val posMs = j.optLong("positionMs", -1L)
        val posAt = j.optLong("positionUpdatedAtMs", 0L)
        val posAgora = when {
            posMs < 0 -> -1L
            playing && posAt > 0 -> posMs + (SystemClock.elapsedRealtime() - posAt)
            else -> posMs
        }

        val out = JSONObject().apply {
            put("playing", playing)
            put("muted", j.optBoolean("isMuted", false))
            put("title", titulo)
            put("artist", j.optString("artist", ""))
            put("album", j.optString("album", ""))
            put("app", j.optString("app", ""))
            put("duration_ms", j.optLong("durationMs", 0L))
            if (posAgora >= 0) {
                put("position_ms", posAgora)
                put("position_at_ms", System.currentTimeMillis())   // âncora em tempo de parede
            }
            put("has_art", j.optBoolean("hasAlbumArt", false))
            put("src", "impulse")
            put("apk", br.com.redesurftank.ecotrip.BuildConfig.VERSION_NAME)
        }

        // Publica quando a faixa/estado muda, ou a cada 30s como batimento (pro consumidor
        // saber que ainda está vivo e pra reancorar a posição).
        val hash = "$playing|$titulo|${j.optString("artist")}|${j.optString("album")}"
        val agora = System.currentTimeMillis()
        if (hash != ultimoHash || agora - ultimaPubMs > 30_000L) {
            ultimoHash = hash; ultimaPubMs = agora; tocando = true
            MqttManager.getInstance().publicarMidia(out.toString())
        }
    }

    private fun publicarParado(motivo: String) {
        val agora = System.currentTimeMillis()
        // Na transição publica na hora; seguindo parado, no máximo 1x/60s.
        if (!tocando && agora - ultimaPubMs < 60_000L) return
        tocando = false; ultimoHash = ""; ultimaPubMs = agora
        MqttManager.getInstance().publicarMidia(JSONObject().apply {
            put("playing", false)
            put("reason", motivo)
            put("src", "impulse")
            put("apk", br.com.redesurftank.ecotrip.BuildConfig.VERSION_NAME)
        }.toString())
    }
}
