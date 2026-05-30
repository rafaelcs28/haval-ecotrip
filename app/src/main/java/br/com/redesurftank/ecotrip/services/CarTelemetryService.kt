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
import br.com.redesurftank.ecotrip.models.SharedPreferencesKeys

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

        /** Singleton da instância em execução — pra UI toggle on/off do LAN server. */
        @Volatile var current: CarTelemetryService? = null
            private set

        /** True = LAN HTTP/WS está ativa. */
        fun isLanServerRunning(): Boolean = current?.localApi != null

        /** Liga ou desliga o LAN server em tempo real (sem matar o foreground). */
        fun setLanEnabled(ctx: Context, on: Boolean) {
            val prefs = ctx.getSharedPreferences(SharedPreferencesKeys.PREFS_NAME, Context.MODE_PRIVATE)
            prefs.edit().putBoolean(SharedPreferencesKeys.LOCAL_LAN_ENABLED, on).apply()
            current?.applyLanEnabled(on)
        }

        /** Leitura do estado salvo (default ON). */
        fun isLanEnabledPref(ctx: Context): Boolean {
            val prefs = ctx.getSharedPreferences(SharedPreferencesKeys.PREFS_NAME, Context.MODE_PRIVATE)
            return prefs.getBoolean(SharedPreferencesKeys.LOCAL_LAN_ENABLED, true)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private var localApi: LocalApiServer? = null
    private var advertiser: LocalServiceAdvertiser? = null
    private var carDataListener: ((String, String) -> Unit)? = null

    override fun onCreate() {
        super.onCreate()
        current = this
        createChannel()
        startForeground(NOTIF_ID, buildNotification("Capturando dados do carro"))

        // Os managers já são singletons inicializados pela Application/Activity; aqui só
        // garantimos que estão "tocados" (init feito). Nenhum trabalho extra.
        try { MqttManager.getInstance() } catch (_: Exception) {}
        try { TripManager.getInstance() } catch (_: Exception) {}
        try { CarDataManager.getInstance() } catch (_: Exception) {}

        // ── Servidor LAN local: respeita pref (default ON)
        if (isLanEnabledPref(this)) applyLanEnabled(true)

        android.util.Log.i(TAG, "CarTelemetryService.onCreate — foreground started")
    }

    /**
     * Liga ou desliga o servidor LAN sem matar o foreground service.
     * Chamado pelo onCreate (lê pref) e pelo toggle das Settings.
     *
     * Tenta portas em ordem: 8088, 8080, 9080, 7777, 9999. Se TODAS estiverem
     * em uso (improvável), loga e não inicia.
     */
    fun applyLanEnabled(on: Boolean) {
        if (on && localApi == null) {
            val mqtt = try { MqttManager.getInstance() } catch (_: Exception) { null } ?: return
            val carData = try { CarDataManager.getInstance() } catch (_: Exception) { null }
            val portsToTry = listOf(LocalApiServer.LOCAL_API_PORT) + LocalApiServer.FALLBACK_PORTS
            var started: LocalApiServer? = null
            for (port in portsToTry) {
                try {
                    val api = LocalApiServer(mqtt, port)
                    api.startServer()
                    if (LocalApiServer.activePort > 0) {
                        started = api
                        break
                    }
                } catch (e: Exception) {
                    android.util.Log.w(TAG, "porta $port falhou: ${e.message}")
                }
            }
            val api = started
            if (api == null) {
                android.util.Log.e(TAG, "✗ todas as portas em uso — LAN server NÃO iniciado")
                return
            }
            localApi = api

            // Hook: cada update do CAN dispara push WS pros clients
            val listener: (String, String) -> Unit = { _, _ ->
                try { api.notifyStateChange() } catch (_: Exception) {}
            }
            carData?.addListener(listener)
            carDataListener = listener

            val adv = LocalServiceAdvertiser(this)
            adv.start(LocalApiServer.activePort, versionName = packageVersionName())
            advertiser = adv
            android.util.Log.i(TAG, "✓ LAN server LIGADO em :${LocalApiServer.activePort}")
        } else if (!on && localApi != null) {
            try { advertiser?.stop() } catch (_: Exception) {}
            advertiser = null
            try { localApi?.stopServer() } catch (_: Exception) {}
            localApi = null
            try {
                val l = carDataListener
                if (l != null) CarDataManager.getInstance().removeListener(l)
            } catch (_: Exception) {}
            carDataListener = null
            android.util.Log.i(TAG, "LAN server DESLIGADO")
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // START_STICKY: se o Android matar o service, ele tenta reiniciar.
        return START_STICKY
    }

    override fun onDestroy() {
        android.util.Log.i(TAG, "CarTelemetryService.onDestroy")
        applyLanEnabled(false)
        if (current === this) current = null
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
