package br.com.consorciolimpagyn.navrelay

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.widget.Toast
import org.eclipse.paho.client.mqttv3.MqttClient
import org.eclipse.paho.client.mqttv3.MqttConnectOptions
import org.eclipse.paho.client.mqttv3.MqttMessage
import org.eclipse.paho.client.mqttv3.persist.MemoryPersistence
import org.json.JSONObject

// Alvo de "Compartilhar" do Maps/Waze. Recebe o texto/link do local compartilhado e
// publica em haval/ecotrip/car_dest_raw → o bridge resolve a coordenada e manda pro
// carro (Ecotrip abre a tela Chegada com a previsão de SOC). Activity invisível: só
// publica, mostra um toast e fecha.
class ShareActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val text = when (intent?.action) {
            Intent.ACTION_SEND -> intent.getStringExtra(Intent.EXTRA_TEXT)
            else -> null
        }?.trim()
        if (text.isNullOrBlank()) {
            Toast.makeText(this, "Nada pra enviar", Toast.LENGTH_SHORT).show(); finish(); return
        }
        Thread { publish(text) }.start()
        finish()
    }

    private fun publish(text: String) {
        val cfg = getSharedPreferences("navrelay", Context.MODE_PRIVATE)
        val broker = cfg.getString("broker", "") ?: ""
        val user   = cfg.getString("user", "") ?: ""
        val pass   = cfg.getString("pass", "") ?: ""
        val navTopic = cfg.getString("topic", "haval/ecotrip/nav_to") ?: "haval/ecotrip/nav_to"
        // car_dest_raw vive no mesmo prefixo do tópico nav_to (haval/ecotrip/*).
        val rawTopic = navTopic.substringBeforeLast('/', "haval/ecotrip") + "/car_dest_raw"
        val base = navTopic.substringBeforeLast('/', "haval/ecotrip")
        val resultTopic = "$base/car_dest_result"
        if (broker.isBlank()) { toast("Configure o Nav Relay primeiro"); return }
        try {
            val c = MqttClient(broker, "navshare_" + (System.currentTimeMillis() % 100000), MemoryPersistence())
            val opts = MqttConnectOptions().apply {
                isCleanSession = true; connectionTimeout = 10; keepAliveInterval = 20
                if (user.isNotBlank()) userName = user
                if (pass.isNotBlank()) password = pass.toCharArray()
            }
            // Aguarda o bridge confirmar a resolução (ok/erro) por até ~8s.
            val result = java.util.concurrent.SynchronousQueue<String>()
            c.setCallback(object : org.eclipse.paho.client.mqttv3.MqttCallback {
                override fun connectionLost(cause: Throwable?) {}
                override fun deliveryComplete(t: org.eclipse.paho.client.mqttv3.IMqttDeliveryToken?) {}
                override fun messageArrived(t: String?, msg: MqttMessage?) {
                    try {
                        val j = JSONObject(String(msg!!.payload))
                        result.offer(if (j.optBoolean("ok", false)) "ok:${j.optString("name", "")}"
                                     else "err:${j.optString("err", "não resolveu")}")
                    } catch (_: Exception) {}
                }
            })
            c.connect(opts)
            c.subscribe(resultTopic, 1)
            val payload = JSONObject().put("text", text).put("ts", System.currentTimeMillis()).toString()
            c.publish(rawTopic, MqttMessage(payload.toByteArray()).apply { qos = 1 })
            val res = result.poll(8, java.util.concurrent.TimeUnit.SECONDS)
            try { c.disconnect() } catch (_: Exception) {}
            when {
                res == null            -> toast("Enviado, mas o carro não confirmou (offline?)")
                res.startsWith("ok:")  -> toast("Destino no carro ✓ ${res.removePrefix("ok:")}")
                else                   -> toast("Não consegui o destino: ${res.removePrefix("err:")}")
            }
        } catch (e: Exception) {
            toast("Falha ao enviar: ${e.message}")
        }
    }

    private fun toast(msg: String) {
        val app = applicationContext
        android.os.Handler(android.os.Looper.getMainLooper()).post {
            Toast.makeText(app, msg, Toast.LENGTH_LONG).show()
        }
    }
}
