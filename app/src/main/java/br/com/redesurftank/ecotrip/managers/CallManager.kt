package br.com.redesurftank.ecotrip.managers

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.Ringtone
import android.media.RingtoneManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.app.NotificationCompat
import br.com.redesurftank.ecotrip.IncomingCallActivity

// Chamada recebida do iOS (full-duplex via bridge). Comportamento: a multimídia
// AVISA com a mensagem personalizada + contagem; sem recusar. Se o motorista não
// atender, AUTO-ACEITA em 10s (ou ele toca "Atender agora"). Conectado, só pode
// Encerrar. O áudio reusa o CarAudioRelay (modo chamada). A sinalização
// (ringing/accepted/ended) volta pro iOS via MQTT call/event → bridge → WS.
object CallManager {
    private const val TAG = "CallManager"
    private const val CHAN = "incoming_call"
    private const val NOTIF_ID = 4711
    const val AUTO_ACCEPT_MS = 10_000L

    enum class CallState { IDLE, RINGING, IN_CALL }

    @Volatile var state: CallState = CallState.IDLE; private set
    @Volatile var callId: String = ""; private set
    @Volatile var caller: String = ""; private set
    @Volatile var message: String = ""; private set

    // Fiado pelo MqttManager: publica evento de ciclo e liga/desliga o áudio.
    @Volatile var publishEvent: ((callId: String, state: String) -> Unit)? = null
    @Volatile var startAudio: (() -> Unit)? = null
    @Volatile var stopAudio: (() -> Unit)? = null

    private var alert: Ringtone? = null
    private val handler = Handler(Looper.getMainLooper())
    private var autoAccept: Runnable? = null

    /** call_start chegou: avisa na multimídia e arma o auto-aceite de 10s. */
    fun incoming(ctx: Context, id: String, who: String, msg: String) = synchronized(this) {
        // Já em chamada/tocando: rejeita a nova (ocupado).
        if (state != CallState.IDLE) { publishEvent?.invoke(id, "busy"); return }
        callId = id; caller = who; message = msg; state = CallState.RINGING
        playAlert(ctx)                 // toque curto de aviso
        postNotif(ctx)                 // banner na multimídia
        launchActivity(ctx)            // tela cheia com a mensagem + contagem
        armAutoAccept(ctx)
        publishEvent?.invoke(id, "ringing")
        AppLogger.i(TAG, "chamada recebida id=$id de='$who' msg='$msg' (auto-aceite em ${AUTO_ACCEPT_MS}ms)")
    }

    /** Atende (manual via botão ou automático pelo timer de 10s). */
    fun accept(ctx: Context) = synchronized(this) {
        if (state != CallState.RINGING) return
        cancelAutoAccept(); stopAlert()
        state = CallState.IN_CALL
        startAudio?.invoke()
        postNotif(ctx)                 // atualiza o banner pra "em chamada"
        publishEvent?.invoke(callId, "accepted")
        AppLogger.i(TAG, "chamada atendida id=$callId")
    }

    /** Encerra (hang-up de qualquer ponta). notify=false quando o evento veio do iOS. */
    fun end(ctx: Context, notify: Boolean = true) = synchronized(this) {
        if (state == CallState.IDLE) return
        val id = callId
        if (state == CallState.IN_CALL) stopAudio?.invoke()
        teardown(ctx)
        if (notify) publishEvent?.invoke(id, "ended")
        AppLogger.i(TAG, "chamada encerrada id=$id")
    }

    private fun armAutoAccept(ctx: Context) {
        cancelAutoAccept()
        autoAccept = Runnable { accept(ctx) }.also { handler.postDelayed(it, AUTO_ACCEPT_MS) }
    }

    private fun cancelAutoAccept() { autoAccept?.let { handler.removeCallbacks(it) }; autoAccept = null }

    private fun teardown(ctx: Context) {
        cancelAutoAccept(); stopAlert(); cancelNotif(ctx)
        state = CallState.IDLE; callId = ""; caller = ""; message = ""
    }

    private fun playAlert(ctx: Context) {
        try {
            val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
            alert = RingtoneManager.getRingtone(ctx, uri)?.apply { play() }   // one-shot
        } catch (e: Exception) { AppLogger.w(TAG, "alerta falhou: ${e.message}") }
    }

    private fun stopAlert() {
        try { alert?.stop() } catch (_: Exception) {}
        alert = null
    }

    private fun nm(ctx: Context) = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private fun ensureChannel(ctx: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(CHAN, "Chamadas", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Chamada recebida do app"
                setBypassDnd(true)
            }
            nm(ctx).createNotificationChannel(ch)
        }
    }

    private fun callIntent(ctx: Context): Intent =
        Intent(ctx, IncomingCallActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            putExtra("callId", callId); putExtra("caller", caller); putExtra("message", message)
        }

    private fun postNotif(ctx: Context) {
        try {
            ensureChannel(ctx)
            val pi = PendingIntent.getActivity(
                ctx, 0, callIntent(ctx),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val title = if (caller.isNotBlank()) "$caller está em chamada" else "Chamada conectada"
            val n = NotificationCompat.Builder(ctx, CHAN)
                .setSmallIcon(android.R.drawable.sym_call_incoming)
                .setContentTitle(title)
                .setContentText(if (message.isNotBlank()) message else "Em chamada")
                .setPriority(NotificationCompat.PRIORITY_MAX)
                .setCategory(NotificationCompat.CATEGORY_CALL)
                .setOngoing(true)
                .setAutoCancel(false)
                .setFullScreenIntent(pi, true)
                .build()
            nm(ctx).notify(NOTIF_ID, n)
        } catch (e: Exception) { AppLogger.w(TAG, "notif falhou: ${e.message}") }
    }

    // Backup do full-screen-intent: tenta subir a Activity direto (HU costuma
    // permitir background-launch; se o policy bloquear, a notif cobre).
    private fun launchActivity(ctx: Context) {
        try { ctx.startActivity(callIntent(ctx)) } catch (e: Exception) {
            AppLogger.w(TAG, "startActivity direto falhou (usa notif): ${e.message}")
        }
    }

    private fun cancelNotif(ctx: Context) {
        try { nm(ctx).cancel(NOTIF_ID) } catch (_: Exception) {}
    }
}
