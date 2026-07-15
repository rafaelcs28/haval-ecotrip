package br.com.redesurftank.ecotrip

import android.app.Application
import android.content.Context
import br.com.redesurftank.ecotrip.models.SharedPreferencesKeys
import br.com.redesurftank.ecotrip.services.CarTelemetryService

class App : Application() {
    companion object {
        private lateinit var instance: App

        fun getDeviceProtectedContext(): Context =
            instance.createDeviceProtectedStorageContext()
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
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
