package br.com.redesurftank.ecotrip.managers

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import org.json.JSONObject
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/// Lê o estado de conectividade do carro (roteamento do hotspot + dados móveis)
/// do app Impulse, via ContentProvider, e republica no MQTT pro bridge.
///
/// **Só consulta, nunca recalcula.** O cálculo pesado — incluindo o shell do
/// HotRouter via Shizuku e o estado do 4G — roda no processo do Impulse. Duplicar
/// aqui gastaria CPU e memória do head unit pra chegar na mesma resposta, e as
/// duas telas poderiam divergir.
///
/// A permissão é `signature`: funciona porque EcoTrip e Impulse são assinados com
/// a mesma keystore. Se algum dia divergirem, o query lança SecurityException — e
/// isso aparece em `uplink/status` como erro, em vez de sumir calado.
object ConnectivityStatusReader {
    private const val TAG = "ConnStatus"
    private const val URI_STR = "content://br.com.redesurftank.havalshisuku.status/connectivity"
    private const val ACAO_MUDOU = "br.com.redesurftank.havalshisuku.CONNECTIVITY_CHANGED"

    private val exec = Executors.newSingleThreadScheduledExecutor { r ->
        Thread(r, "conn-status").apply { isDaemon = true }
    }
    private var appCtx: Context? = null
    private var ultimoJson: String? = null
    private var receiver: BroadcastReceiver? = null

    /// O broadcast do Impulse cobre 4G/regras/WiFi na hora. Mudança de MODO do
    /// HotRouter não tem evento do lado dele, então um poll lento cobre — 60s e não
    /// os 2s do handoff, porque aqui não há card na tela: é telemetria pro bridge,
    /// e 2s seria consulta a cada ciclo sem ninguém olhando.
    private const val POLL_S = 60L

    fun start(ctx: Context) {
        if (appCtx != null) return
        appCtx = ctx.applicationContext

        receiver = object : BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) {
                AppLogger.i(TAG, "Impulse avisou mudança — reconsultando")
                exec.execute { consultarEPublicar("broadcast") }
            }
        }
        runCatching {
            // Android 9 (o carro é API 28): registerReceiver de 2 args.
            appCtx!!.registerReceiver(receiver, IntentFilter(ACAO_MUDOU))
        }.onFailure { AppLogger.w(TAG, "registerReceiver falhou: ${it.message}") }

        exec.scheduleWithFixedDelay({ consultarEPublicar("poll") }, 5, POLL_S, TimeUnit.SECONDS)
        AppLogger.i(TAG, "leitor de conectividade do Impulse ativo (poll ${POLL_S}s + broadcast)")
    }

    fun stop() {
        receiver?.let { r -> runCatching { appCtx?.unregisterReceiver(r) } }
        receiver = null
    }

    /// Consulta o provider e publica só quando o conteúdo MUDA — o bridge não
    /// precisa de republicação idêntica a cada minuto.
    private fun consultarEPublicar(origem: String) {
        val ctx = appCtx ?: return
        val o = JSONObject()
        try {
            ctx.contentResolver.query(Uri.parse(URI_STR), null, null, null, null)?.use { c ->
                if (!c.moveToFirst()) { o.put("ok", false).put("erro", "sem linha") }
                else {
                    fun str(n: String): String? =
                        c.getColumnIndex(n).let { if (it < 0 || c.isNull(it)) null else c.getString(it) }
                    fun int0(n: String): Int =
                        c.getColumnIndex(n).let { if (it < 0 || c.isNull(it)) 0 else c.getInt(it) }
                    o.put("ok", true)
                    // displayText null = o Impulse pede pra ESCONDER o card. Mantemos
                    // como null no JSON, não como "": o bridge distingue "sem estado
                    // pra mostrar" de "texto vazio".
                    o.put("displayText", str("displayText") ?: JSONObject.NULL)
                    o.put("displayLevel", str("displayLevel") ?: JSONObject.NULL)
                    o.put("displayIcon", str("displayIcon") ?: JSONObject.NULL)
                    o.put("routingMode", str("routingMode") ?: JSONObject.NULL)
                    o.put("routingWifiName", str("routingWifiName") ?: JSONObject.NULL)
                    o.put("hotspotRouting", int0("hotspotRouting"))
                    o.put("mobileControlEnabled", int0("mobileControlEnabled"))
                    o.put("mobile4gOn", int0("mobile4gOn"))
                    o.put("mobileBlockReason", str("mobileBlockReason") ?: JSONObject.NULL)
                    // vc7260: prioridade automática de WiFi e a rede em que a TELA está.
                    o.put("wifiPriorityEnabled", int0("wifiPriorityEnabled"))
                    o.put("headUnitWifiSsid", str("headUnitWifiSsid") ?: JSONObject.NULL)
                    // TODAS as colunas restantes, pelo tipo que o cursor declara. O
                    // Impulse vai acrescentar as 5 regras de corte + mobileUsedMb na
                    // query (vc7267) e copiar assim evita um patch aqui a cada campo
                    // novo — a mesma disciplina que já uso no Bundle do call().
                    for (i in 0 until c.columnCount) {
                        val nome = c.getColumnName(i) ?: continue
                        if (o.has(nome)) continue
                        if (c.isNull(i)) { o.put(nome, JSONObject.NULL); continue }
                        when (c.getType(i)) {
                            android.database.Cursor.FIELD_TYPE_INTEGER -> o.put(nome, c.getLong(i))
                            android.database.Cursor.FIELD_TYPE_FLOAT   -> o.put(nome, c.getDouble(i))
                            else -> o.put(nome, c.getString(i) ?: "")
                        }
                    }
                }
            } ?: o.put("ok", false).put("erro", "provider ausente")
        } catch (e: SecurityException) {
            // A permissão é `signature`, então isto é divergência de keystore — config
            // de build, não falha de runtime. Compara os dois digests e manda no
            // payload: sem isso o dono não tem como saber QUAL app assinar de novo.
            o.put("ok", false).put("erro", "sem permissão (assinatura difere)")
            o.put("assinaturaEcotrip", digestAssinatura(ctx, ctx.packageName))
            o.put("assinaturaImpulse", digestAssinatura(ctx, "br.com.redesurftank.havalshisuku"))
            AppLogger.w(TAG, "SecurityException no provider: ${e.message}")
        } catch (e: Exception) {
            o.put("ok", false).put("erro", e.javaClass.simpleName + ": " + (e.message ?: ""))
        }
        // Compara SEM o instante da medição: com ele no meio, todo ciclo pareceria
        // mudança e o log encheria o buffer de 300 com a mesma linha.
        val comparavel = o.toString()
        // Quando o carro mediu. O bridge não consegue derivar isso: retained é
        // reentregue em cada reconexão dele, então "quando recebi" dizia que dado de
        // uma hora atrás era novo. O relógio do head unit é sincronizado por rede.
        o.put("medidoMs", System.currentTimeMillis())
        val json = o.toString()
        // Publica SEMPRE, mesmo sem mudança. Guardar "já publiquei isso" só em
        // memória deixa o tópico órfão: se o retained for limpo no broker (restart,
        // limpeza manual), o carro nunca republica e o bridge fica sem estado pra
        // sempre. Uma mensagem por minuto é irrelevante; estado órfão não é.
        // O log é que fica gateado por mudança, pra não encher o buffer de 300.
        val mudou = comparavel != ultimoJson
        ultimoJson = comparavel
        if (mudou) AppLogger.i(TAG, "uplink ($origem): $json")
        MqttManager.getInstance().publicarUplinkStatus(json)
    }

    /// Manda o Impulse aplicar uma mudança (4G, prioridade de WiFi, trocar de rede).
    ///
    /// Vai pelo MESMO provider que já é lido, via `call()` — o guard é por pacote, e
    /// o EcoTrip está na lista. Roda fora da main thread porque o Impulse pode mexer
    /// em shell/WiFi por baixo.
    ///
    /// Depois de aplicar, RE-CONSULTA em vez de assumir que o pedido virou verdade:
    /// `setMobileBlock(false)` só limpa o bloqueio manual, e outras regras (consumo,
    /// WiFi, AA/CarPlay) podem seguir cortando o 4G. Quem manda é o estado lido.
    fun comandar(metodo: String, valor: Boolean? = null, ssid: String? = null,
                 extraInts: Map<String, Int>? = null, senha: String? = null,
                 aoTerminar: ((JSONObject) -> Unit)? = null) {
        val ctx = appCtx ?: return
        exec.execute {
            val res = JSONObject().put("metodo", metodo)
            try {
                val extras = android.os.Bundle().apply {
                    valor?.let { putBoolean("value", it) }
                    senha?.let { putString("password", it) }
                    // addWifi quer o ssid nos extras; os outros usam o `arg`.
                    if (metodo == "addWifi") ssid?.let { putString("ssid", it) }
                    extraInts?.forEach { (k, v) -> putInt(k, v) }
                }
                val out = ctx.contentResolver.call(Uri.parse(URI_STR), metodo,
                    if (metodo == "addWifi") null else ssid, extras)
                if (out == null) { res.put("ok", false).put("erro", "provider não respondeu") }
                else {
                    // Copia o Bundle INTEIRO pelo tipo de cada chave, em vez de listar
                    // campo por campo: a resposta traz um snapshot completo do estado
                    // (mobileBlocked, mobileLimitMb, wifiPriorityEnabled, …) e o
                    // Impulse pode acrescentar campos. Listar à mão significaria um
                    // patch aqui a cada mudança do outro lado.
                    for (k in out.keySet()) {
                        when (val v = out.get(k)) {
                            null -> res.put(k, JSONObject.NULL)
                            is Boolean -> res.put(k, v)
                            is Int -> res.put(k, v)
                            is Long -> res.put(k, v)
                            is String -> res.put(k, v)
                            is ArrayList<*> -> res.put(k, org.json.JSONArray(v.map { it.toString() }))
                            else -> res.put(k, v.toString())
                        }
                    }
                    if (!out.containsKey("ok")) res.put("ok", false)
                    // O handoff usa `error`; padroniza pra `erro` sem perder o original.
                    out.getString("error")?.let { res.put("erro", it) }
                }
            } catch (e: Exception) {
                res.put("ok", false).put("erro", e.javaClass.simpleName + ": " + (e.message ?: ""))
            }
            AppLogger.i(TAG, "comando $metodo → ${res.toString().take(300)}")
            MqttManager.getInstance().publicarUplinkResultado(res.toString())
            aoTerminar?.invoke(res)
            consultarEPublicar("pos-comando")
        }
    }

    /// SHA-256 curto do certificado de assinatura de um pacote. Serve pra provar se
    /// EcoTrip e Impulse foram assinados com a MESMA keystore — a permissão é
    /// `signature`, e comparar os dois digests transforma "não funciona" em "estes
    /// são os dois valores, reassine o que estiver diferente".
    private fun digestAssinatura(ctx: Context, pkg: String): String = try {
        @Suppress("DEPRECATION")
        val info = ctx.packageManager.getPackageInfo(pkg, android.content.pm.PackageManager.GET_SIGNATURES)
        @Suppress("DEPRECATION")
        val sigs = info.signatures
        if (sigs.isNullOrEmpty()) "sem-assinatura" else {
            val md = java.security.MessageDigest.getInstance("SHA-256")
            md.digest(sigs[0].toByteArray()).take(8)
                .joinToString("") { "%02x".format(it) }
        }
    } catch (e: Exception) { "erro:" + e.javaClass.simpleName }

    /// Estado atual pra quem já está no processo (a UI usa isto sem re-consultar).
    fun ultimo(): JSONObject? = ultimoJson?.let { runCatching { JSONObject(it) }.getOrNull() }
}
