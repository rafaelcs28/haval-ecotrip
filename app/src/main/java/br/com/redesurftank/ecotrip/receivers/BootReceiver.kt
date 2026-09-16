package br.com.redesurftank.ecotrip.receivers

import br.com.redesurftank.ecotrip.managers.AppLogger

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import br.com.redesurftank.ecotrip.MainActivity
import br.com.redesurftank.ecotrip.services.CarTelemetryService

private const val TAG = "BootReceiver"

class BootReceiver : BroadcastReceiver() {
    companion object {
        /// Alarme periódico: o AlarmManager guarda o disparo mesmo com o processo
        /// morto e o relança na hora marcada — é o único caminho que sobrevive ao
        /// app ser derrubado sem boot em seguida.
        const val ACAO_VIGIA = "br.com.redesurftank.ecotrip.VIGIA"
        private const val INTERVALO_MS = 15 * 60_000L

        fun agendarVigia(ctx: Context) {
            val am = ctx.getSystemService(Context.ALARM_SERVICE) as android.app.AlarmManager
            val pi = android.app.PendingIntent.getBroadcast(
                ctx, 4711,
                Intent(ctx, BootReceiver::class.java).setAction(ACAO_VIGIA),
                android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE)
            // Inexato de propósito: só precisa acordar de vez em quando, e inexato
            // não briga com o Doze nem gasta bateria do 12V à toa.
            am.setInexactRepeating(android.app.AlarmManager.ELAPSED_REALTIME,
                android.os.SystemClock.elapsedRealtime() + INTERVALO_MS, INTERVALO_MS, pi)
        }
    }

    /// Default true: o carro liga sozinho toda vez, e ninguém quer o app tomando a
    /// tela no lugar do rádio/Waze.
    ///
    /// Lê do prefs NORMAL, que é onde `setBootMinimized` grava. O
    /// `createDeviceProtectedStorageContext()` aponta pra um arquivo DIFERENTE, que
    /// ninguém escreve — quem lê de lá recebe sempre o default e a opção do dono não
    /// tem efeito (era o caso do `moveTaskToBack` da MainActivity). Só cai no
    /// device-protected quando o usuário ainda não desbloqueou, porque aí o storage
    /// normal não é legível — em LOCKED_BOOT_COMPLETED, que chega antes do unlock.
    private fun bootMinimizado(ctx: Context): Boolean {
        val um = ctx.getSystemService(android.os.UserManager::class.java)
        val desbloqueado = um?.isUserUnlocked ?: true
        val c = if (desbloqueado) ctx
                else try { ctx.createDeviceProtectedStorageContext() } catch (_: Exception) { ctx }
        return try {
            c.getSharedPreferences(
                br.com.redesurftank.ecotrip.models.SharedPreferencesKeys.PREFS_NAME,
                Context.MODE_PRIVATE,
            ).getBoolean(br.com.redesurftank.ecotrip.models.SharedPreferencesKeys.BOOT_MINIMIZED, true)
        } catch (_: Exception) { true }
    }

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            "android.intent.action.QUICKBOOT_POWERON",
            "android.intent.action.LOCKED_BOOT_COMPLETED",
            Intent.ACTION_MY_PACKAGE_REPLACED,
            // O head unit nem sempre dá BOOT_COMPLETED: ligar o carro depois de um
            // sleep não é boot, e aí NADA relançava o app. Em 01/08 ele morreu às
            // 19:34 e só voltou 3h30 depois, no meio da viagem seguinte — os
            // primeiros 9 min do trajeto não foram gravados por ninguém.
            // START_STICKY não cobre isso: force-stop e OOM em ROM de carro não
            // garantem relançamento.
            Intent.ACTION_POWER_CONNECTED,
            ACAO_VIGIA -> {
                AppLogger.i(TAG, "Boot/update recebido (${intent.action})")
                // O foreground service é TUDO que o boot precisa: ele liga o overlay,
                // o MQTT, as automações, o servidor LAN e o GPS. A UI não faz parte do
                // funcionamento — só de olhar.
                try { CarTelemetryService.start(context) } catch (e: Exception) {
                    AppLogger.w(TAG, "Falha ao iniciar CarTelemetryService no boot: ${e.message}")
                }
                // SÓ o boot de verdade pode abrir a tela. `ACTION_POWER_CONNECTED` e o
                // alarme de vigia entraram aqui pra RESSUSCITAR o app (v6.208), mas
                // caíam no mesmo caminho e lançavam a Activity — e o head unit emite
                // POWER_CONNECTED sempre que a alimentação oscila. Resultado: o EcoTrip
                // roubava a tela de tempos em tempos, por cima do app que o dono estava
                // usando (relatado em 09/08). Pra esses dois, o serviço basta.
                val ehBoot = intent.action == Intent.ACTION_BOOT_COMPLETED
                    || intent.action == "android.intent.action.QUICKBOOT_POWERON"
                    || intent.action == "android.intent.action.LOCKED_BOOT_COMPLETED"
                    || intent.action == Intent.ACTION_MY_PACKAGE_REPLACED
                if (!ehBoot) {
                    AppLogger.i(TAG, "gatilho ${intent.action} — só serviço, sem abrir tela")
                    return
                }
                // A Activity sobe SEMPRE, e se minimiza sozinha quando "iniciar
                // minimizado" está ligado (MainActivity, extra from_boot).
                //
                // Tentei subir só o serviço na 6.190 pra evitar o flash na tela. Não
                // funciona neste head unit: em 02/08, com a 6.195 (que já tinha alarme
                // de vigia, ACTION_POWER_CONNECTED e ressurreição pelo
                // NotificationListener), o dono saiu de casa, rodou 300-400 m, nenhuma
                // automação disparou e o app estava zerado ao ser aberto na mão.
                // Nenhuma das três redes substitui o lançamento da Activity aqui.
                //
                // O flash de ~1s é o preço de o app existir. Perder o começo do
                // trajeto e as automações não é aceitável; piscar é.
                val launch = Intent(context, MainActivity::class.java).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                    putExtra("from_boot", true)
                }
                try { context.startActivity(launch) } catch (e: Exception) {
                    AppLogger.w(TAG, "Falha ao lançar Activity: ${e.message}")
                }
            }
        }
    }
}
