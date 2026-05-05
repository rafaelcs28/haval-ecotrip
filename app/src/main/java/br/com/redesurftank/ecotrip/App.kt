package br.com.redesurftank.ecotrip

import android.app.Application
import android.content.Context

class App : Application() {
    companion object {
        private lateinit var instance: App

        fun getDeviceProtectedContext(): Context =
            instance.createDeviceProtectedStorageContext()
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
    }
}
