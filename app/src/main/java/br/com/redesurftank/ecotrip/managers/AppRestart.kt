package br.com.redesurftank.ecotrip.managers

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import br.com.redesurftank.ecotrip.MainActivity

/**
 * Reinício do PRÓPRIO app, comandado de fora.
 *
 * Existe porque o modo de falha mais caro daqui não derruba o processo: o app
 * segue publicando MQTT com timestamp fresco enquanto a leitura do CAN congela.
 * Em 22/09 aconteceu três vezes no mesmo dia; nas três, o que resolveu foi
 * reiniciar — a multimídia de manhã, o app à tarde. O dono descobriu olhando o
 * painel mudo, dirigindo, e reiniciou na mão.
 *
 * `killProcess` sozinho NÃO traz o app de volta: quem relança é o alarme agendado
 * antes de morrer. Sem ele o head unit fica com o app fechado, que é pior que o
 * app travado — pelo menos travado ele publica alguma coisa.
 *
 * Trava de segurança: um reinício por [MIN_ENTRE_MS]. O bridge decide QUANDO
 * reiniciar, mas se a decisão dele estiver errada (ou o CAN não voltar depois do
 * reinício) um laço de reinício seria pior que a falha original — o carro ficaria
 * inutilizável em vez de só cego.
 */
object AppRestart {
    private const val TAG = "AppRestart"
    private const val MIN_ENTRE_MS = 15 * 60_000L
    private const val PREF = "ultimo_restart_ms"

    /** Quando foi o último reinício comandado (0 = nunca nesta instalação). */
    fun ultimoMs(ctx: Context): Long =
        ctx.getSharedPreferences("app_restart", Context.MODE_PRIVATE).getLong(PREF, 0L)

    /**
     * Agenda o relançamento e mata o processo. Devolve false (sem reiniciar) se
     * outro reinício aconteceu há menos de 15 min.
     *
     * @param motivo vai pro log em disco — é o que sobra pra entender depois.
     */
    fun reiniciar(ctx: Context, motivo: String): Boolean {
        val agora = System.currentTimeMillis()
        val ultimo = ultimoMs(ctx)
        if (agora - ultimo < MIN_ENTRE_MS) {
            AppLogger.w(TAG, "reinício IGNORADO ($motivo) — último há "
                + "${(agora - ultimo) / 60_000}min, mínimo é ${MIN_ENTRE_MS / 60_000}min")
            return false
        }
        AppLogger.w(TAG, "reiniciando o app: $motivo")
        ctx.getSharedPreferences("app_restart", Context.MODE_PRIVATE)
            .edit().putLong(PREF, agora).commit()   // commit(): o kill abaixo não espera flush

        return try {
            val intent = Intent(ctx, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
            }
            val flags = PendingIntent.FLAG_ONE_SHOT or PendingIntent.FLAG_IMMUTABLE
            val pi = PendingIntent.getActivity(ctx, 4321, intent, flags)
            val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            // 800 ms: tempo de o processo morrer antes de o alarme disparar. Menos que
            // isso e o relançamento corre com a morte.
            am.set(AlarmManager.RTC, agora + 800, pi)
            android.os.Process.killProcess(android.os.Process.myPid())
            true
        } catch (e: Exception) {
            AppLogger.e(TAG, "falha ao reiniciar", e)
            false
        }
    }
}
