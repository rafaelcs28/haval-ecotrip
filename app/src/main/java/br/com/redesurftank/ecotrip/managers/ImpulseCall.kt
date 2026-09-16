package br.com.redesurftank.ecotrip.managers

import android.content.Context
import android.os.Bundle
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.SynchronousQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

/**
 * Chamada ao ContentProvider do Haval Impulse COM PRAZO.
 *
 * `contentResolver.call()` bloqueia indefinidamente quando o provider do outro app
 * está pendurado (processo em mau estado, atualização no meio, Shizuku travado). Os
 * probes rodam em executor de thread ÚNICA, então uma chamada travada prendia a thread
 * para sempre: o `scheduleWithFixedDelay` nunca mais disparava e o recurso morria em
 * silêncio — nem o publish de "estou mudo" saía, porque viria depois da chamada presa.
 *
 * Observado em 14/08: a LA de viagem atualizando a cada 2s (APK vivo, MQTT ok) enquanto
 * `nav/directions` e `media/now_playing` — os DOIS únicos canais que leem o Impulse —
 * ficaram mudos por completo até o app ser reiniciado na mão.
 *
 * Aqui a chamada roda num pool separado e é ABANDONADA no timeout. Uma thread presa
 * fica presa, mas o probe segue vivo e tenta de novo no próximo tick. O pool é cached:
 * reaproveita thread ociosa e só cria outra quando todas estão ocupadas.
 */
object ImpulseCall {
    private const val TAG = "ImpulseCall"
    const val URI = "content://br.com.redesurftank.havalshisuku.status/connectivity"

    /** 2s: a leitura é snapshot em memória do lado do Impulse (o dev confirmou que não
     *  precisa nem bloquear). Qualquer coisa acima disso é provider pendurado. */
    private const val TIMEOUT_MS = 2_000L

    /** Pool LIMITADO a 2 threads, sem fila.
     *
     *  A v6.220 usava `newCachedThreadPool`: cada chamada que pendurava deixava uma
     *  thread presa PARA SEMPRE e a tentativa seguinte criava outra. Com os dois probes
     *  batendo a cada 5s e 7s, isso acumulava threads até ANR/OOM — as mortes do APK
     *  saltaram de ~2/dia para 17 em 18/08, todas "unclean (force-stop/ANR/OOM)". E
     *  cada morte zera o acumulador da sessão de recarga, que foi como o dono viu
     *  "+0,0 kWh" carregando.
     *
     *  Com `SynchronousQueue` + máximo 2 e política de rejeição: no pior caso duas
     *  threads ficam presas e TODA chamada seguinte é rejeitada na hora, devolvendo
     *  null sem alocar nada. Provider pendurado custa duas threads, não o processo. */
    private val pool = ThreadPoolExecutor(
        0, 2, 30L, TimeUnit.SECONDS, SynchronousQueue(),
        { r -> Thread(r, "impulse-call").apply { isDaemon = true } },
        ThreadPoolExecutor.AbortPolicy(),
    )

    /** Quantas chamadas foram abandonadas por timeout (threads possivelmente presas). */
    @Volatile var travadas = 0
        private set

    /**
     * Retorna o Bundle, ou `null` se o provider não respondeu no prazo, não existe, ou
     * lançou. Nunca propaga exceção — quem chama trata `null` como "não deu".
     */
    fun call(ctx: Context, metodo: String, extras: Bundle? = null): Bundle? {
        val f = try {
            pool.submit<Bundle?> {
                ctx.contentResolver.call(android.net.Uri.parse(URI), metodo, null, extras)
            }
        } catch (e: RejectedExecutionException) {
            // As 2 threads estão presas num provider pendurado. Falha rápido: sem isto
            // a alternativa seria criar thread nova a cada tick, que é o que matava o app.
            travadas++
            AppLogger.w(TAG, "pool saturado — chamada recusada ($metodo, travadas=$travadas)")
            return null
        } catch (e: Exception) {
            AppLogger.w(TAG, "submit falhou ($metodo): ${e.message}")
            return null
        }
        return try {
            f.get(TIMEOUT_MS, TimeUnit.MILLISECONDS)
        } catch (e: TimeoutException) {
            f.cancel(true)          // interrompe o que der; binder travado ignora, e tudo bem
            travadas++
            AppLogger.w(TAG, "provider não respondeu em ${TIMEOUT_MS}ms ($metodo) — abandonada (total=$travadas)")
            null
        } catch (e: Exception) {
            AppLogger.w(TAG, "provider falhou ($metodo): ${e.cause?.javaClass?.simpleName ?: e.message}")
            null
        }
    }
}
