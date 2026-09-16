package br.com.redesurftank.ecotrip.managers

import android.content.Context
import android.os.Bundle
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import org.json.JSONObject

/**
 * Lê a navegação do Android Auto (Waze / Maps) exposta pelo Haval Impulse e publica no
 * MQTT. O Impulse captura passivamente o que o host do AA entrega ao cluster; nós só
 * consumimos — nenhum bind nosso no serviço de projeção.
 *
 * Contrato (Impulse, provider `…havalshisuku.status/connectivity`):
 *   call("navDirections") → ok, key, json, updatedAtMs
 *
 * `updatedAtMs == 0` significa SEM rota ativa (o Impulse zera no fim). Não é "não sei":
 * é a afirmação de que não há navegação — e é o que nos deixa apagar o ETA em vez de
 * deixar o último valor pendurado.
 *
 * NÃO vem lat/long: o host do AA não expõe coordenada. Só ETA, distância/tempo restante
 * e próxima manobra. Coordenada continua sendo o GPS do head unit.
 */
object NavProbe {
    private const val TAG = "NavProbe"
    private const val URI = "content://br.com.redesurftank.havalshisuku.status/connectivity"

    /** ~7s: o host atualiza a posição ~1x/s, e o dado é snapshot em memória (chamada barata). */
    private const val INTERVALO_S = 7L

    /** Acima disso o snapshot não representa mais a rota corrente. Limite do próprio dev. */
    private const val MAX_IDADE_MS = 30_000L

    /** Teto absoluto. Entre MAX_IDADE_MS e este valor o snapshot ainda vale SE a
     *  distância restante estiver mudando — ver `ultimoRestanteM`. */
    private const val MAX_IDADE_MOVENDO_MS = 5 * 60_000L

    private val exec = Executors.newSingleThreadScheduledExecutor { r ->
        Thread(r, "nav-probe").apply { isDaemon = true }
    }
    private var ctx: Context? = null
    private var tarefa: ScheduledFuture<*>? = null

    /** Última publicação — pra emitir o "acabou" uma vez só, sem repetir a cada tick. */
    @Volatile private var ultimoAtivo = false
    /** Falhas consecutivas do provider. NUNCA desliga o probe — só espaça as tentativas.
     *  A v6.215 marcava `indisponivel = true` na primeira exceção e desistia até o
     *  processo reiniciar: o OTA do Impulse (que derruba o provider por instantes)
     *  emudecia a navegação de forma permanente e silenciosa (11/08). */
    @Volatile private var falhas = 0
    /** Último "estou mudo e eis o motivo" publicado. Sem isso o silêncio é indistinguível
     *  de "não há rota", e eu fico adivinhando de fora qual dos dois é. */
    @Volatile private var ultimoInativoMs = 0L
    /** Distância restante da amostra anterior. Mudança nela prova que a rota está viva
     *  mesmo com `updatedAtMs` parado: quando a navegação começa ANTES do app subir, o
     *  host pode não reemitir e o snapshot envelhece — e o corte de 30s descartava
     *  para sempre um destino que existia (visto em 12/08, "snapshot velho (30s)" em
     *  loop com o dono navegando). Reiniciar a rota resolvia, o que é sintoma de corte
     *  meu, não de dado morto. */
    @Volatile private var ultimoRestanteM = -1L

    fun start(context: Context) {
        ctx = context.applicationContext
        if (tarefa != null) return
        tarefa = exec.scheduleWithFixedDelay({
            runCatching { tick() }.onFailure { AppLogger.w(TAG, "tick: ${it.message}") }
        }, 5, INTERVALO_S, TimeUnit.SECONDS)
        AppLogger.i(TAG, "probe de navegação ligado (${INTERVALO_S}s)")
    }

    fun parar() {
        tarefa?.cancel(false); tarefa = null
    }

    private fun tick() {
        val c = ctx ?: return
        // Backoff: depois de 3 falhas seguidas, tenta 1 em cada 8 ticks (~1min) em vez
        // de parar. O provider volta sozinho quando o Impulse reinicia.
        if (falhas >= 3 && (falhas % 8) != 0) { falhas++; return }
        // SEM gate de "carro ligado". A v6.214 gateava em `latestDrivingReadyMs`, que só
        // avança quando o APK recebe CAR_BASIC_DRIVING_READY_STATE — e este carro não
        // publica esse campo. Resultado: depois do primeiro "carro desligado" o timestamp
        // nunca mais era renovado e o probe emudecia PARA SEMPRE (10/08: destino posto no
        // Waze com engine_state='1' e nada chegava). Perguntar sempre é mais barato que
        // adivinhar: é snapshot em memória do Impulse, e o `updatedAtMs == 0` dele já é a
        // resposta autoritativa de "não há rota".
        // Com PRAZO: `contentResolver.call` direto bloqueava a thread única do probe pra
        // sempre quando o provider do Impulse pendurava, e o recurso morria calado até
        // reiniciar o app (14/08). Ver ImpulseCall.
        val b: Bundle? = ImpulseCall.call(c, "navDirections")
        if (b == null) {
            falhas++
            publicarInativo("provider não respondeu")
            if (falhas <= 3) AppLogger.w(TAG, "provider de navegação sem resposta (${falhas}x)")
            return
        }
        falhas = 0
        if (!b.getBoolean("ok")) { publicarInativo("provider respondeu ok=false"); return }

        val updatedAtMs = b.getLong("updatedAtMs")
        if (updatedAtMs <= 0L) {                       // afirmação de "sem rota"
            // SEM o `if (ultimoAtivo)`: com ele, um probe que nunca viu rota jamais
            // publicava nada, e "não há rota" ficava indistinguível de "probe morto"
            // visto de fora. Foi essa cegueira que me fez perseguir o NavProbe por duas
            // semanas — o `media` publicando e o `nav` calado não provavam nada sozinhos.
            // O throttle de 60s vive dentro do publicarInativo, então isto não vira spam.
            publicarInativo("sem rota ativa (updatedAtMs=0)")
            return
        }
        val idade = System.currentTimeMillis() - updatedAtMs
        val cru = b.getString("json") ?: "{}"
        if (cru.length < 3) {                          // "{}" = host não mandou nada ainda
            publicarInativo("json vazio — host do AA não emitiu nada")
            return
        }

        // Frescor: até 30s vale sempre. Acima disso só continua valendo enquanto a
        // distância restante MUDA — aí a rota está viva de fato, mesmo com o host sem
        // reemitir o timestamp. Passando do teto, ou parando de mudar, encerra.
        val restanteM = JSONObject(cru).optLong("remainingMeters", -1L)
        val mexeu = restanteM >= 0 && ultimoRestanteM >= 0 && restanteM != ultimoRestanteM
        ultimoRestanteM = restanteM
        if (idade > MAX_IDADE_MS) {
            if (idade > MAX_IDADE_MOVENDO_MS) {
                publicarInativo("snapshot velho (${idade / 1000}s, teto)")
                return
            }
            if (!mexeu) {
                publicarInativo("snapshot velho (${idade / 1000}s) e distância parada")
                return
            }
            AppLogger.i(TAG, "snapshot com ${idade / 1000}s mas distância mudou (${restanteM}m) — aceito")
        }

        // Repassa o JSON do host intacto e anexa a procedência. O bridge decide o que usar;
        // não quero reinterpretar campo do host aqui e ter duas versões da verdade.
        val out = JSONObject(cru).apply {
            put("active", true)
            put("updated_at_ms", updatedAtMs)
            put("age_ms", idade)
            put("src", "android_auto")
            put("apk", br.com.redesurftank.ecotrip.BuildConfig.VERSION_NAME)
        }
        MqttManager.getInstance().publicarNav(out.toString())
        ultimoAtivo = true
    }

    private fun publicarInativo(motivo: String) {
        // Publica na transição E a cada 60s enquanto seguir mudo: o bridge precisa saber
        // a DIFERENÇA entre "sem rota" e "não consigo ler", e antes as duas chegavam
        // como nada.
        val agora = System.currentTimeMillis()
        if (!ultimoAtivo && agora - ultimoInativoMs < 60_000L) return
        ultimoInativoMs = agora
        ultimoAtivo = false
        MqttManager.getInstance().publicarNav(JSONObject().apply {
            put("active", false)
            put("reason", motivo)
            put("src", "android_auto")
            put("apk", br.com.redesurftank.ecotrip.BuildConfig.VERSION_NAME)
        }.toString())
        AppLogger.i(TAG, "navegação inativa — $motivo")
    }
}
