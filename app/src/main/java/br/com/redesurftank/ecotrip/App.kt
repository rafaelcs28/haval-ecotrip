package br.com.redesurftank.ecotrip

import android.app.Application
import android.content.Context
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
        // Inicia o foreground service o quanto antes pra manter o processo vivo
        // mesmo se a Activity for destruída pelo Android (memory pressure).
        try { CarTelemetryService.start(this) } catch (_: Exception) {}
    }
}
