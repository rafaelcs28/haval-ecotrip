package br.com.redesurftank.ecotrip.services

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import br.com.redesurftank.ecotrip.MainActivity
import br.com.redesurftank.ecotrip.R
import br.com.redesurftank.ecotrip.managers.CarDataManager
import br.com.redesurftank.ecotrip.managers.LocalApiServer
import br.com.redesurftank.ecotrip.managers.LocalServiceAdvertiser
import br.com.redesurftank.ecotrip.managers.MqttManager
import br.com.redesurftank.ecotrip.managers.TripManager

/**
 * Serviço persistente que mantém o processo APK vivo enquanto o carro estiver
 * ligado. Garante que MqttManager, CarDataManager e TelemetryRecorder
 * continuem capturando dados mesmo se a Activity Compose for destruída pelo
 * Android (memory pressure, troca pra outro app no head unit, etc).
 *
 * Notification mínima ("Ecotrip · capturando dados do carro") fica visível
 * na barra de status — trade-off obrigatório do Android pra ForegroundService.
 */
class CarTelemetryService : Service() {

    companion object {
        private const val CHANNEL_ID  = "ecotrip_telemetry"
        private const val NOTIF_ID    = 1001
        private const val TAG         = "CarTelemetryService"

        /** Inicia o service. Idempotente. */
        fun start(ctx: Context) {
            val intent = Intent(ctx, CarTelemetryService::class.java)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) ctx.startForegroundService(intent)
                else ctx.startService(intent)
            } catch (e: Exception) {
                android.util.Log.w(TAG, "start() falhou: ${e.message}")
            }
        }

        /** Para o service. Raramente chamado em produção. */
        fun stop(ctx: Context) {
            try { ctx.stopService(Intent(ctx, CarTelemetryService::class.java)) } catch (_: Exception) {}
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private var localApi: LocalApiServer? = null
    private var advertiser: LocalServiceAdvertiser? = null
    private var carDataListener: ((String, String) -> Unit)? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
        startForeground(NOTIF_ID, buildNotification("Capturando dados do carro"))

        // Os managers já são singletons inicializados pela Application/Activity; aqui só
        // garantimos que estão "tocados" (init feito). Nenhum trabalho extra.
        val mqtt = try { MqttManager.getInstance() } catch (_: Exception) { null }
        try { TripManager.getInstance() } catch (_: Exception) {}
        val carData = try { CarDataManager.getInstance() } catch (_: Exception) { null }

        // ── Servidor LAN local: HTTP + WS pra iPad descobrir e consumir
        // telemetria fast direto (sem passar pelo Mac mini via Tailscale).
        // Anunciado via mDNS pra descoberta automática.
        if (mqtt != null) {
            try {
                val api = LocalApiServer(mqtt)
                api.startServer()
                localApi = api

                // Hook: cada update do CAN dispara push WS pros clients
                val listener: (String, String) -> Unit = { _, _ ->
                    try { api.notifyStateChange() } catch (_: Exception) {}
                }
                carData?.addListener(listener)
                carDataListener = listener

                val adv = LocalServiceAdvertiser(this)
                adv.start(LocalApiServer.LOCAL_API_PORT, versionName = packageVersionName())
                advertiser = adv
            } catch (e: Exception) {
                android.util.Log.w(TAG, "LocalApiServer start falhou: ${e.message}")
            }
        }

        android.util.Log.i(TAG, "CarTelemetryService.onCreate — foreground started")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // START_STICKY: se o Android matar o service, ele tenta reiniciar.
        return START_STICKY
    }

    override fun onDestroy() {
        android.util.Log.i(TAG, "CarTelemetryService.onDestroy")
        // Para LAN server e desregistra mDNS
        try { advertiser?.stop() } catch (_: Exception) {}
        try { localApi?.stopServer() } catch (_: Exception) {}
        try {
            val l = carDataListener
            if (l != null) CarDataManager.getInstance().removeListener(l)
        } catch (_: Exception) {}
        super.onDestroy()
    }

    private fun packageVersionName(): String = try {
        val pkg = packageManager.getPackageInfo(packageName, 0)
        pkg.versionName ?: "0"
    } catch (_: Exception) { "0" }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val ch = NotificationChannel(
                CHANNEL_ID,
                "Telemetria Ecotrip",
                NotificationManager.IMPORTANCE_MIN   // mínima — silenciosa, sem som, sem heads-up
            ).apply {
                description = "Mantém Ecotrip capturando dados do carro em background"
                setShowBadge(false)
                lockscreenVisibility = Notification.VISIBILITY_SECRET
            }
            nm.createNotificationChannel(ch)
        }
    }

    private fun buildNotification(text: String): Notification {
        val openIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_NEW_TASK
        }
        val pi = android.app.PendingIntent.getActivity(
            this, 0, openIntent,
            android.app.PendingIntent.FLAG_IMMUTABLE or android.app.PendingIntent.FLAG_UPDATE_CURRENT
        )
        // ic_launcher_foreground existe como vector em res/drawable; fallback para ícone do sistema se algo der errado.
        val iconRes = try { R.drawable.ic_launcher_foreground } catch (_: Exception) { android.R.drawable.ic_menu_compass }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(iconRes)
            .setContentTitle("Ecotrip")
            .setContentText(text)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setOngoing(true)
            .setShowWhen(false)
            .setContentIntent(pi)
            .build()
    }
}
