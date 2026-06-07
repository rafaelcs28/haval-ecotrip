package br.com.consorciolimpagyn.navrelay

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.IBinder
import android.util.Log
import org.eclipse.paho.client.mqttv3.MqttClient
import org.eclipse.paho.client.mqttv3.MqttConnectOptions
import org.eclipse.paho.client.mqttv3.MqttMessage
import org.eclipse.paho.client.mqttv3.persist.MemoryPersistence
import org.json.JSONObject

// Serviço em foreground: mantém conexão MQTT e, ao receber um destino em nav_to,
// abre o Google Maps ou o Waze navegando (o Android Auto projeta no carro).
// O celular é dedicado e fica desbloqueado → o launch automático funciona.
class NavRelayService : Service() {
    companion object {
        const val TAG = "NavRelay"
        const val CH = "navrelay"
        @Volatile var status: String = "parado"
        @Volatile var lastNav: String = "—"
    }

    @Volatile private var client: MqttClient? = null
    @Volatile private var running = false
    @Volatile private var role = "car"   // 'car' (dedicado no carro) ou 'phone' (celular pessoal)

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(1, buildNotification("Conectando ao bridge…"))
        if (!running) { running = true; Thread { connectLoop() }.start() }
        return START_STICKY
    }

    private fun connectLoop() {
        val cfg = getSharedPreferences("navrelay", Context.MODE_PRIVATE)
        val broker = cfg.getString("broker", "") ?: ""
        val user   = cfg.getString("user", "") ?: ""
        val pass   = cfg.getString("pass", "") ?: ""
        val topic  = cfg.getString("topic", "haval/ecotrip/nav_to") ?: "haval/ecotrip/nav_to"
        role = cfg.getString("role", "car") ?: "car"
        if (broker.isBlank()) { status = "configure o bridge"; updateNotif(status); return }
        while (running) {
            try {
                val c = MqttClient(broker, "navrelay_" + (System.currentTimeMillis() % 100000), MemoryPersistence())
                val opts = MqttConnectOptions().apply {
                    isCleanSession = true
                    isAutomaticReconnect = true
                    connectionTimeout = 10
                    keepAliveInterval = 30
                    if (user.isNotBlank()) userName = user
                    if (pass.isNotBlank()) password = pass.toCharArray()
                }
                c.setCallback(object : org.eclipse.paho.client.mqttv3.MqttCallback {
                    override fun connectionLost(cause: Throwable?) { status = "reconectando…"; updateNotif(status) }
                    override fun deliveryComplete(t: org.eclipse.paho.client.mqttv3.IMqttDeliveryToken?) {}
                    override fun messageArrived(t: String?, msg: MqttMessage?) {
                        try { onNav(JSONObject(String(msg!!.payload))) } catch (e: Exception) { Log.w(TAG, "msg inválida: ${e.message}") }
                    }
                })
                c.connect(opts)
                c.subscribe(topic, 1)
                client = c
                status = "conectado · ${if (role == "phone") "Celular" else "Carro"} · ouvindo $topic"; updateNotif(status)
                while (running && c.isConnected) Thread.sleep(1000)
            } catch (e: Exception) {
                status = "erro: ${e.message}"; updateNotif(status)
                Thread.sleep(8000)   // espera e tenta de novo
            }
        }
    }

    private fun onNav(j: JSONObject) {
        // Filtra pelo papel: 'phone' só atende mensagens target=phone; 'car' (default)
        // atende target=car ou sem target (legado). Assim o iPhone manda só pro celular.
        val target = j.optString("target", "")
        if (target.isNotEmpty() && target != role) return
        val lat = j.optDouble("lat", 0.0); val lng = j.optDouble("lng", 0.0)
        val name = j.optString("name", ""); val app = j.optString("app", "maps")
        if (lat == 0.0 && lng == 0.0) return
        lastNav = "${if (app == "waze") "Waze" else "Maps"} → ${name.take(40)}"
        updateNotif("Navegando: $lastNav")
        val uri = if (app == "waze") Uri.parse("waze://?ll=$lat,$lng&navigate=yes")
                  else               Uri.parse("google.navigation:q=$lat,$lng&mode=d")
        val pkg = if (app == "waze") "com.waze" else "com.google.android.apps.maps"
        try {
            startActivity(Intent(Intent.ACTION_VIEW, uri).setPackage(pkg).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (e: Exception) {
            // App escolhido não instalado → tenta sem fixar o pacote.
            try { startActivity(Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
            catch (e2: Exception) { Log.w(TAG, "launch falhou: ${e2.message}") }
        }
    }

    private fun buildNotification(text: String): Notification {
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(NotificationChannel(CH, "Nav Relay", NotificationManager.IMPORTANCE_LOW))
        }
        return Notification.Builder(this, CH)
            .setContentTitle("Nav Relay")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setOngoing(true)
            .build()
    }
    private fun updateNotif(text: String) {
        getSystemService(NotificationManager::class.java).notify(1, buildNotification(text))
    }

    override fun onDestroy() {
        running = false
        try { client?.disconnect() } catch (_: Exception) {}
        super.onDestroy()
    }
}
