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
        // Inicia o foreground service o quanto antes pra manter o processo vivo
        // mesmo se a Activity for destruída pelo Android (memory pressure).
        try { CarTelemetryService.start(this) } catch (_: Exception) {}
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
