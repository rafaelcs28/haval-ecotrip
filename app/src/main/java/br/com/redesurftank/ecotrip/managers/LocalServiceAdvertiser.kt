package br.com.redesurftank.ecotrip.managers

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log

/**
 * Anuncia o LocalApiServer via mDNS/Bonjour pra que o iPad descubra o APK
 * automaticamente quando estiverem na mesma LAN.
 *
 * Service type: `_havalobd._tcp` (porta 8080)
 * Service name: `Haval-EcoTrip-<suffix>` (suffix derivado do VIN ou random)
 * TXT records:
 *   - version: número da versão do APK
 *   - api: "v1"
 *   - paths: "state,cmd,ws"
 */
class LocalServiceAdvertiser(private val context: Context) {

    companion object {
        private const val TAG = "LocalServiceAdvertiser"
        // NsdManager exige o tipo SEM ponto final ("_havalobd._tcp"). O OS já
        // adiciona o ponto na publicação. Se incluir ".", NsdManager registra
        // OK mas alguns clients (NWBrowser do iOS) podem não encontrar.
        const val SERVICE_TYPE = "_havalobd._tcp"
        private const val SERVICE_NAME_PREFIX = "Haval-EcoTrip"
    }

    private val nsdManager: NsdManager by lazy {
        context.applicationContext.getSystemService(Context.NSD_SERVICE) as NsdManager
    }
    private var registrationListener: NsdManager.RegistrationListener? = null
    private var registered = false

    fun start(port: Int, suffix: String = randomSuffix(), versionName: String = "0") {
        if (registered) return
        val serviceInfo = NsdServiceInfo().apply {
            serviceName = "$SERVICE_NAME_PREFIX-$suffix"
            serviceType = SERVICE_TYPE
            this.port = port
            // TXT records — visíveis no client antes do conectar
            setAttribute("version", versionName)
            setAttribute("api", "v1")
            setAttribute("paths", "state,cmd,ws")
        }

        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {
                registered = true
                Log.i(TAG, "registrado: ${info.serviceName} em :${info.port}")
            }
            override fun onRegistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                Log.w(TAG, "falha no registro: errorCode=$errorCode")
            }
            override fun onServiceUnregistered(info: NsdServiceInfo) {
                registered = false
                Log.i(TAG, "desregistrado: ${info.serviceName}")
            }
            override fun onUnregistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                Log.w(TAG, "falha no unregister: errorCode=$errorCode")
            }
        }
        try {
            nsdManager.registerService(serviceInfo, NsdManager.PROTOCOL_DNS_SD, listener)
            registrationListener = listener
        } catch (e: Exception) {
            Log.e(TAG, "registerService throw: ${e.message}")
        }
    }

    fun stop() {
        val l = registrationListener ?: return
        try { nsdManager.unregisterService(l) } catch (_: Exception) {}
        registrationListener = null
        registered = false
    }

    private fun randomSuffix(): String {
        // Suffix curto e estável durante a sessão. Não precisa ser do VIN —
        // o iPad só usa pra distinguir múltiplas instâncias na mesma rede.
        val bytes = ByteArray(2)
        java.security.SecureRandom().nextBytes(bytes)
        return bytes.joinToString("") { "%02x".format(it) }
    }
}
