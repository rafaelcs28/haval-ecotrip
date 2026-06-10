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
import android.os.PowerManager
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
    @Volatile private var deviceId = ""
    @Volatile private var deviceName = ""
    @Volatile private var alwaysOn = false
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        // WakeLock só quando "sempre online" está ligado — esse modo é pra dispositivo
        // dedicado no carro plugado. Pra celular pessoal, deixa o Android gerenciar.
        val cfg = getSharedPreferences("navrelay", Context.MODE_PRIVATE)
        alwaysOn = cfg.getBoolean("always_on", false)
        if (alwaysOn) acquireWakeLock()
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$TAG:mqtt").apply {
            setReferenceCounted(false)
            acquire()
        }
    }
    private fun releaseWakeLock() {
        try { wakeLock?.let { if (it.isHeld) it.release() } } catch (_: Exception) {}
        wakeLock = null
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(1, buildNotification("Conectando ao bridge…"))
        // Reaplica config a cada start (pode ter mudado via UI).
        val cfg = getSharedPreferences("navrelay", Context.MODE_PRIVATE)
        val nowAlwaysOn = cfg.getBoolean("always_on", false)
        if (nowAlwaysOn != alwaysOn) {
            alwaysOn = nowAlwaysOn
            if (alwaysOn) acquireWakeLock() else releaseWakeLock()
        }
        if (!running) { running = true; Thread { connectLoop() }.start() }
        return START_STICKY
    }

    private fun connectLoop() {
        val cfg = getSharedPreferences("navrelay", Context.MODE_PRIVATE)
        val broker = cfg.getString("broker", "") ?: ""
        val user   = cfg.getString("user", "") ?: ""
        val pass   = cfg.getString("pass", "") ?: ""
        val baseTopic = cfg.getString("topic", "haval/ecotrip/nav_to") ?: "haval/ecotrip/nav_to"
        val prefix = baseTopic.removeSuffix("/nav_to").ifBlank { "haval/ecotrip" }   // "haval/ecotrip"
        role = cfg.getString("role", "car") ?: "car"
        // Device id estável (UUID curto). Gera 1x e persiste — distingue múltiplos APKs
        // do mesmo usuário (carro + celular + tablet etc.).
        deviceId = cfg.getString("device_id", "") ?: ""
        if (deviceId.isBlank()) {
            deviceId = java.util.UUID.randomUUID().toString().substring(0, 8)
            cfg.edit().putString("device_id", deviceId).apply()
        }
        deviceName = (cfg.getString("device_name", "") ?: "").ifBlank { if (role == "phone") "Celular" else "Carro" }
        if (broker.isBlank()) { status = "configure o bridge"; updateNotif(status); return }
        // Tópico de registro: NavRelay publica seu status aqui (retain) pra o iOS
        // listar dispositivos disponíveis. LWT esvazia ao desconectar.
        val devTopic = "$prefix/nav_devices/$deviceId"
        // Tópico direcionado: iOS publica neste pra mandar destino só pra esse aparelho.
        val directTopic = "$prefix/nav_to/$deviceId"
        while (running) {
            try {
                val c = MqttClient(broker, "navrelay_$deviceId", MemoryPersistence())
                val opts = MqttConnectOptions().apply {
                    isCleanSession = true
                    isAutomaticReconnect = true
                    connectionTimeout = 10
                    keepAliveInterval = 20   // 30→20s: detecta drop mais rápido em NAT residencial
                    if (user.isNotBlank()) userName = user
                    if (pass.isNotBlank()) password = pass.toCharArray()
                    // LWT: ao perder conexão, broker apaga o registro retido (payload vazio).
                    setWill(devTopic, "".toByteArray(), 1, true)
                    // ssl:// no Android: o Paho exige o socketFactory explícito (igual ao
                    // APK do carro), senão dá MqttException no handshake. Cert é Let's
                    // Encrypt, então o trust store padrão do Android resolve.
                    if (broker.startsWith("ssl://")) socketFactory = javax.net.ssl.SSLSocketFactory.getDefault()
                }
                c.setCallback(object : org.eclipse.paho.client.mqttv3.MqttCallbackExtended {
                    // connectComplete dispara na conexão inicial E em cada auto-reconnect do Paho.
                    // Re-subscreve aqui SEMPRE — como cleanSession=true, o broker reentrega neste
                    // momento as mensagens RETIDAS (inclusive o último nav_to), então o destino é
                    // puxado automaticamente ao voltar a conexão. Também re-publica o registro
                    // retido (a LWT o apaga ao cair).
                    override fun connectComplete(reconnect: Boolean, serverURI: String?) {
                        try {
                            c.subscribe(arrayOf(directTopic, baseTopic), intArrayOf(1, 1))
                            val reg = JSONObject().apply {
                                put("id", deviceId); put("name", deviceName); put("role", role)
                                put("alwaysOn", alwaysOn); put("ts", System.currentTimeMillis())
                            }
                            c.publish(devTopic, reg.toString().toByteArray(), 1, true)
                            status = "conectado · $deviceName · id=$deviceId"; updateNotif(status)
                        } catch (e: Exception) { Log.w(TAG, "resubscribe falhou: ${e.message}") }
                    }
                    override fun connectionLost(cause: Throwable?) { status = "reconectando…"; updateNotif(status) }
                    override fun deliveryComplete(t: org.eclipse.paho.client.mqttv3.IMqttDeliveryToken?) {}
                    override fun messageArrived(t: String?, msg: MqttMessage?) {
                        try { onNav(JSONObject(String(msg!!.payload))) } catch (e: Exception) { Log.w(TAG, "msg inválida: ${e.message}") }
                    }
                })
                c.connect(opts)
                client = c
                // Conexão estabelecida. Deixa o Paho cuidar da reconexão (isAutomaticReconnect):
                // NÃO recriamos o cliente quando cai. Recriar brigava com o auto-reconnect e
                // causava o churn "conectado → reconectando" + rc=0. Só caímos no catch abaixo
                // se o connect() INICIAL falhar (ex: sem rede no boot) — aí sim tentamos de novo.
                while (running) Thread.sleep(1000)
            } catch (e: Exception) {
                val rc = (e as? org.eclipse.paho.client.mqttv3.MqttException)?.reasonCode
                val detail = (e.message ?: e.cause?.message ?: e.javaClass.simpleName) +
                    (rc?.let { " · rc=$it" } ?: "") + (e.cause?.let { " · ${it.javaClass.simpleName}" } ?: "")
                status = "erro: $detail"; updateNotif(status)
                Log.w(TAG, "connect falhou: ${e.javaClass.name} rc=$rc msg=${e.message}", e)
                Thread.sleep(8000)   // espera e tenta de novo
            }
        }
    }

    private fun onNav(j: JSONObject) {
        // Endereçamento atual: msg pode vir no tópico direto (nav_to/<deviceId>) ou
        // no legado (nav_to) com `target` = role OU = deviceId. Quando recebida no
        // direto, já é nossa. No legado: aceita se target vazio, igual ao role ou
        // igual ao nosso deviceId.
        val target = j.optString("target", "")
        if (target.isNotEmpty() && target != role && target != deviceId) return
        val lat = j.optDouble("lat", 0.0); val lng = j.optDouble("lng", 0.0)
        val name = j.optString("name", ""); val app = j.optString("app", "maps")
        if (lat == 0.0 && lng == 0.0) return
        // Dedup por ts: o destino é publicado RETIDO no broker, então o broker reentrega
        // a cada (re)subscribe. Sem isso, todo reconnect re-abriria o Waze pro mesmo lugar.
        // Só marcamos como tratado DEPOIS de abrir o app — se o launch falhar (ex: sem
        // permissão de overlay em background), o destino não é "queimado" e dispara de novo.
        val ts = j.optLong("ts", 0L)
        val cfg = getSharedPreferences("navrelay", Context.MODE_PRIVATE)
        if (ts > 0L && ts <= cfg.getLong("last_nav_ts", 0L)) return
        lastNav = "${if (app == "waze") "Waze" else "Maps"} → ${name.take(40)}"
        updateNotif("Navegando: $lastNav")
        val uri = if (app == "waze") Uri.parse("waze://?ll=$lat,$lng&navigate=yes")
                  else               Uri.parse("google.navigation:q=$lat,$lng&mode=d")
        val pkg = if (app == "waze") "com.waze" else "com.google.android.apps.maps"
        val launched = launchNav(uri, pkg)
        // Fallback: launch bloqueado (background sem overlay). Posta notificação tocável
        // que abre o Waze quando o usuário tocar, e NÃO marca como tratado.
        if (!launched) { notifyTapToOpen(uri, pkg); return }
        if (ts > 0L) cfg.edit().putLong("last_nav_ts", ts).apply()
    }

    // Tenta abrir Maps/Waze. Retorna true se o startActivity não lançou exceção.
    // Em background, o Android 10+ só permite o start se o app tiver SYSTEM_ALERT_WINDOW
    // (overlay) concedido — daí a tela de permissão no app.
    private fun launchNav(uri: Uri, pkg: String): Boolean {
        try {
            startActivity(Intent(Intent.ACTION_VIEW, uri).setPackage(pkg).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            return true
        } catch (e: Exception) {
            try {
                startActivity(Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                return true
            } catch (e2: Exception) { Log.w(TAG, "launch falhou: ${e2.message}") }
        }
        return false
    }

    // Notificação de alta prioridade que, ao ser tocada, abre a navegação.
    private fun notifyTapToOpen(uri: Uri, pkg: String) {
        val intent = Intent(Intent.ACTION_VIEW, uri).setPackage(pkg).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val flags = android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE
        val pi = android.app.PendingIntent.getActivity(this, 2, intent, flags)
        val n = Notification.Builder(this, CH)
            .setContentTitle("Toque para navegar")
            .setContentText(lastNav)
            .setSmallIcon(android.R.drawable.ic_menu_directions)
            .setContentIntent(pi)
            .setAutoCancel(true)
            .build()
        getSystemService(NotificationManager::class.java).notify(2, n)
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
        releaseWakeLock()
        super.onDestroy()
    }
}
