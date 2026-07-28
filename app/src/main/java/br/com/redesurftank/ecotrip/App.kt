package br.com.redesurftank.ecotrip

import android.app.Application
import android.content.Context
import br.com.redesurftank.ecotrip.managers.AppLogger
import br.com.redesurftank.ecotrip.models.SharedPreferencesKeys
import br.com.redesurftank.ecotrip.services.CarTelemetryService

class App : Application() {
    companion object {
        private lateinit var instance: App

        fun getDeviceProtectedContext(): Context =
            instance.createDeviceProtectedStorageContext()

        /**
         * A sessão ANTERIOR terminou limpa? Capturado em reportDeathIfAny() antes
         * de o flag ser sobrescrito. Quem consome: AutomationManager — bordas de
         * trigger "state" salvas por uma sessão que morreu mal não são confiáveis
         * (ver loadTrigState).
         */
        @Volatile var lastSessionEndedCleanly: Boolean = true
            private set
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        // ANTES de qualquer coisa que leia a URL do bridge: o MqttManager lê
        // BRIDGE_URL direto das prefs, então a migração tem que já ter gravado o
        // valor novo quando ele carregar.
        try {
            // Device-protected storage: é onde MqttManager e reportDeathIfAny leem
            // as prefs. Usar o contexto normal aqui abriria OUTRO arquivo e a
            // migração não teria efeito nenhum.
            val ctx = try { createDeviceProtectedStorageContext() } catch (_: Exception) { this }
            val p = ctx.getSharedPreferences(SharedPreferencesKeys.PREFS_NAME, Context.MODE_PRIVATE)
            migrarBridgeUrl(p, (p.getString(SharedPreferencesKeys.BRIDGE_URL, "") ?: "").trim().trimEnd('/'))
        } catch (_: Exception) {}
        installDeathBreadcrumb()
        // Se a sessão anterior morreu (crash Java OU force-stop/ANR/OOM), reporta
        // ao bridge no boot atual — antes só reportava se havia trip aberta.
        // Sem isso, mortes fora de viagem ficavam invisíveis (o incidente de
        // 15/07 v6.131 com 23 restarts em 60min NÃO gerou nenhuma entrada).
        try { reportDeathIfAny() } catch (_: Exception) {}
        // Inicia o foreground service o quanto antes pra manter o processo vivo
        // mesmo se a Activity for destruída pelo Android (memory pressure).
        try { CarTelemetryService.start(this) } catch (_: Exception) {}
    }

    /**
     * Le o breadcrumb persistido (LAST_DEATH_REASON + SESSION_ENDED_CLEANLY) e,
     * se a última sessão não terminou limpa, envia POST /api/apk-death. Roda
     * independente de haver viagem aberta — captura force-stop/ANR/OOM que
     * NÃO passam pelo UncaughtExceptionHandler. Fire-and-forget.
     */
    private fun reportDeathIfAny() {
        val dpCtx = createDeviceProtectedStorageContext()
        val prefs = dpCtx.getSharedPreferences(SharedPreferencesKeys.PREFS_NAME, Context.MODE_PRIVATE)
        val cleanly = prefs.getBoolean(SharedPreferencesKeys.SESSION_ENDED_CLEANLY, true)
        val reason  = prefs.getString(SharedPreferencesKeys.LAST_DEATH_REASON, null)
        // Guarda antes do overwrite abaixo — o AutomationManager precisa saber.
        lastSessionEndedCleanly = cleanly
        // Marca "unclean" pra próxima — só vira "clean" no shutdown intencional.
        prefs.edit().putBoolean(SharedPreferencesKeys.SESSION_ENDED_CLEANLY, false).apply()
        if (cleanly && reason == null) return  // primeira vez OU boot limpo — nada a reportar
        val url   = getBridgeUrlFromPrefs(prefs)
        val token = prefs.getString(SharedPreferencesKeys.BRIDGE_TOKEN, "") ?: ""
        if (url.isBlank()) return
        val effReason = reason ?: if (!cleanly) "unclean (force-stop/ANR/OOM)" else "unknown"
        Thread {
            try {
                val body = org.json.JSONObject()
                    .put("tripId", "0").put("reason", effReason)
                    .put("sessionEndedCleanly", cleanly)
                    .put("version", BuildConfig.VERSION_NAME)
                    .put("ts", System.currentTimeMillis())
                    .put("source", "boot").toString()
                val conn = (java.net.URL("$url/api/apk-death").openConnection() as java.net.HttpURLConnection).apply {
                    requestMethod = "POST"; connectTimeout = 8000; readTimeout = 8000; doOutput = true
                    setRequestProperty("Content-Type", "application/json")
                    if (token.isNotBlank()) setRequestProperty("Authorization", "Bearer $token")
                }
                conn.outputStream.use { it.write(body.toByteArray()) }
                conn.responseCode; conn.disconnect()
                prefs.edit().remove(SharedPreferencesKeys.LAST_DEATH_REASON).apply()
            } catch (_: Exception) {}
        }.start()
    }

    private fun getBridgeUrlFromPrefs(prefs: android.content.SharedPreferences): String {
        val raw = (prefs.getString(SharedPreferencesKeys.BRIDGE_URL, "") ?: "").trim().trimEnd('/')
        return migrarBridgeUrl(prefs, raw)
    }

    /**
     * Converte URL antiga do bridge gravada nas prefs pro host atual.
     *
     * O Funnel do Tailscale (mac-mini.*.ts.net) vai sair do ar, e a URL do bridge
     * fica em SharedPreferences desde o pareamento — sem isto o carro continuaria
     * batendo lá até alguém re-parear na tela de config. Foi o APK o último cliente
     * do Funnel: apareceu como Dalvik/Android 9 chamando /api/pending-renames.
     *
     * Grava de volta pra não repetir a substituição em cada leitura.
     */
    private fun migrarBridgeUrl(prefs: android.content.SharedPreferences, raw: String): String {
        val novo = "https://bridge.malha.dev"
        fun ehAntigo(s: String) = s.contains("tailacc6e7") || s.contains(".ts.net")

        // Caso 1: BRIDGE_URL preenchida com o host antigo.
        if (raw.isNotEmpty() && ehAntigo(raw)) {
            prefs.edit().putString(SharedPreferencesKeys.BRIDGE_URL, novo).apply()
            AppLogger.i("App", "bridge_url migrado: $raw -> $novo")
            return novo
        }
        if (raw.isNotEmpty()) return raw

        // Caso 2: BRIDGE_URL VAZIA. Aí TripManager.getBridgeHttpUrl() deriva do
        // HA_EXPORT_URL (nível 2) ou do MQTT_HOST (nível 3) — e se qualquer um
        // deles for o Funnel, o carro continua batendo lá. Foi o que aconteceu:
        // a v6.152 migrou "nada" porque a pref estava vazia, e o app seguiu
        // derivando o ts.net do HA_EXPORT_URL.
        //
        // Grava BRIDGE_URL explícita pra ganhar do nível 2/3, sem tocar no
        // HA_EXPORT_URL (que é a URL do Home Assistant e serve pra outra coisa).
        val ha   = prefs.getString(SharedPreferencesKeys.HA_EXPORT_URL, "") ?: ""
        val mqtt = prefs.getString(SharedPreferencesKeys.MQTT_HOST, "") ?: ""
        if (ehAntigo(ha) || ehAntigo(mqtt)) {
            prefs.edit().putString(SharedPreferencesKeys.BRIDGE_URL, novo).apply()
            AppLogger.i("App", "bridge_url vazio e derivava do Funnel (ha='$ha' mqtt='$mqtt') -> fixado em $novo")
            return novo
        }
        return raw
    }

    /**
     * Grava a causa da morte quando o processo cai por exceção não tratada.
     * commit() síncrono pra garantir flush antes do processo encerrar. Encadeia
     * no handler anterior (crash reporter default) pra não engolir o crash.
     * OTA/force-stop/OOM NÃO passam por aqui — esses são cobertos pelo
     * LAST_DEATH_REASON do OTA e pelo SESSION_ENDED_CLEANLY (fallback "unclean").
     */
    private fun installDeathBreadcrumb() {
        val prev = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, ex ->
            try {
                val reason = "crash: ${ex::class.simpleName}: ${ex.message}".take(300)
                createDeviceProtectedStorageContext()
                    .getSharedPreferences(SharedPreferencesKeys.PREFS_NAME, Context.MODE_PRIVATE)
                    .edit()
                    .putString(SharedPreferencesKeys.LAST_DEATH_REASON, reason)
                    .commit()
            } catch (_: Throwable) {}
            prev?.uncaughtException(thread, ex)
        }
    }
}
