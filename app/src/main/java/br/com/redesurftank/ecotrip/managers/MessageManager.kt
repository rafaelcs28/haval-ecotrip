package br.com.redesurftank.ecotrip.managers

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.Person
import br.com.redesurftank.ecotrip.MessageActivity

/**
 * Recado curto enviado do iOS ou do link do trajeto, exibido no HU.
 *
 * Mesmo mecanismo da chamada recebida: notificação de prioridade máxima com
 * `setFullScreenIntent`, que faz o sistema abrir a MessageActivity por cima do
 * app que estiver na tela. É o caminho NATIVO do Android — não precisa de
 * SYSTEM_ALERT_WINDOW nem de overlay próprio, e por ser do sistema tem mais
 * chance de aparecer também sobre a UI projetada que um overlay de terceiro.
 *
 * A notificação usa MessagingStyle + CATEGORY_MESSAGE pra que head-units que
 * dão tratamento especial a mensagens (estilo SMS nativo) a renderizem no
 * próprio formato, em vez de um card genérico.
 */
object MessageManager {
    private const val TAG = "MessageManager"
    private const val CHAN = "recados"
    private const val NOTIF_ID = 4711

    /** Exibe o recado. [from] quem escreveu, [text] a mensagem (limitada no servidor). */
    fun show(ctx: Context, from: String, text: String) {
        val who = from.ifBlank { "Recado" }
        try {
            ensureChannel(ctx)
            val full = Intent(ctx, MessageActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                putExtra("from", who); putExtra("text", text)
            }
            val pi = PendingIntent.getActivity(
                ctx, NOTIF_ID, full,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val sender = Person.Builder().setName(who).build()
            val style = NotificationCompat.MessagingStyle(sender).addMessage(
                text, System.currentTimeMillis(), sender,
            )
            val n = NotificationCompat.Builder(ctx, CHAN)
                .setSmallIcon(android.R.drawable.ic_dialog_email)
                .setContentTitle(who)
                .setContentText(text)
                .setStyle(style)
                .setPriority(NotificationCompat.PRIORITY_MAX)
                .setCategory(NotificationCompat.CATEGORY_MESSAGE)
                .setAutoCancel(true)
                .setContentIntent(pi)
                // O que efetivamente coloca a tela por cima de tudo.
                .setFullScreenIntent(pi, true)
                .build()
            nm(ctx).notify(NOTIF_ID, n)
            AppLogger.i(TAG, "recado de '$who' exibido: ${text.take(40)}")
            // Fallback: em algumas builds o full-screen-intent é ignorado quando
            // não há tela ligada/desbloqueada. O startActivity direto cobre isso
            // — a activity é singleInstance, então não empilha duplicado.
            try { ctx.startActivity(full) } catch (_: Exception) {}
        } catch (e: Exception) {
            AppLogger.w(TAG, "falha ao exibir recado: ${e.message}")
        }
    }

    /** Remove a notificação (chamado quando a activity fecha). */
    fun clear(ctx: Context) {
        try { nm(ctx).cancel(NOTIF_ID) } catch (_: Exception) {}
    }

    private fun nm(ctx: Context) =
        ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private fun ensureChannel(ctx: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(CHAN, "Recados", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Mensagens curtas enviadas pelo app ou pelo link do trajeto"
                setBypassDnd(true)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }
            nm(ctx).createNotificationChannel(ch)
        }
    }
}
