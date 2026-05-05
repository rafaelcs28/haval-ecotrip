package br.com.redesurftank.ecotrip.managers

import android.content.Context
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import br.com.redesurftank.ecotrip.models.CarConstants
import com.beantechs.intelligentvehiclecontrol.IIntelligentVehicleControlService
import com.beantechs.intelligentvehiclecontrol.sdk.IListener
import org.lsposed.hiddenapibypass.HiddenApiBypass
import rikka.shizuku.Shizuku
import rikka.shizuku.ShizukuBinderWrapper
import java.lang.reflect.Method

private const val TAG = "CarDataManager"
private const val SHIZUKU_PERMISSION_REQUEST_CODE = 1001

typealias DataListener = (key: String, value: String) -> Unit
typealias ConnectedListener = () -> Unit

class CarDataManager private constructor() {

    companion object {
        @Volatile private var instance: CarDataManager? = null
        fun getInstance() = instance ?: synchronized(this) {
            instance ?: CarDataManager().also { instance = it }
        }

        private val KEYS = CarConstants.entries.map { it.value }.toTypedArray()
    }

    private var controlService: IIntelligentVehicleControlService? = null
    private val dataListeners = mutableListOf<DataListener>()
    private val connectedListeners = mutableListOf<ConnectedListener>()
    private val lock = Any()
    private var pkg = ""

    val isConnected: Boolean get() = controlService != null

    private val remoteListener = object : IListener.Stub() {
        override fun onDataChanged(key: String, value: String) {
            synchronized(lock) { dataListeners.toList() }.forEach { it(key, value) }
        }
    }

    // Shizuku binder chegou — verifica permissão antes de conectar
    private val shizukuBinderListener = object : Shizuku.OnBinderReceivedListener {
        override fun onBinderReceived() {
            Log.i(TAG, "Shizuku binder received")
            checkPermissionAndConnect()
        }
    }

    // Resultado da solicitação de permissão ao usuário
    private val permissionResultListener =
        Shizuku.OnRequestPermissionResultListener { requestCode, grantResult ->
            if (requestCode == SHIZUKU_PERMISSION_REQUEST_CODE) {
                if (grantResult == android.content.pm.PackageManager.PERMISSION_GRANTED) {
                    Log.i(TAG, "Shizuku permission granted — connecting")
                    connectControlService()
                } else {
                    Log.w(TAG, "Shizuku permission DENIED by user")
                }
            }
        }

    private val shizukuDeadListener = Shizuku.OnBinderDeadListener {
        Log.w(TAG, "Shizuku binder died")
        controlService = null
    }

    fun init(context: Context) {
        pkg = context.packageName
        HiddenApiBypass.addHiddenApiExemptions("")
        Shizuku.addRequestPermissionResultListener(permissionResultListener)
        Shizuku.addBinderReceivedListenerSticky(shizukuBinderListener)
        Shizuku.addBinderDeadListener(shizukuDeadListener)
    }

    fun destroy() {
        try {
            controlService?.unRegisterDataChangedListener(pkg, remoteListener)
        } catch (e: Exception) {
            Log.e(TAG, "destroy error", e)
        }
        Shizuku.removeBinderReceivedListener(shizukuBinderListener)
        Shizuku.removeBinderDeadListener(shizukuDeadListener)
        Shizuku.removeRequestPermissionResultListener(permissionResultListener)
        controlService = null
    }

    fun addListener(l: DataListener) = synchronized(lock) { dataListeners.add(l) }
    fun removeListener(l: DataListener) = synchronized(lock) { dataListeners.remove(l) }

    fun addConnectedListener(l: ConnectedListener) = synchronized(lock) { connectedListeners.add(l) }
    fun removeConnectedListener(l: ConnectedListener) = synchronized(lock) { connectedListeners.remove(l) }

    fun fetchCurrent(key: String): String? = try {
        controlService?.fetchData(key)
    } catch (e: Exception) { null }

    fun requestSetting(key: String, value: String, action: String = "cmd.common.request.set"): Boolean {
        return try {
            val svc = controlService ?: run {
                AppLogger.w(TAG, "requestSetting: serviço do carro não conectado")
                return false
            }
            AppLogger.i(TAG, "request(action=$action, key=$key, value=$value)")
            svc.request(action, key, value)
            AppLogger.i(TAG, "request() executado sem exceção")
            true
        } catch (e: Exception) {
            AppLogger.e(TAG, "request() falhou: ${e.message}")
            false
        }
    }

    // ── Permissão ─────────────────────────────────────────────────────────────

    private fun checkPermissionAndConnect() {
        try {
            when {
                // Shizuku não está vivo
                !Shizuku.pingBinder() -> {
                    Log.e(TAG, "Shizuku binder not alive")
                }
                // Permissão já concedida — conecta direto
                Shizuku.checkSelfPermission() == android.content.pm.PackageManager.PERMISSION_GRANTED -> {
                    Log.i(TAG, "Shizuku permission already granted")
                    connectControlService()
                }
                // Nunca pediu permissão — solicita ao usuário (abre dialog do Shizuku)
                else -> {
                    Log.i(TAG, "Requesting Shizuku permission")
                    Shizuku.requestPermission(SHIZUKU_PERMISSION_REQUEST_CODE)
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "checkPermissionAndConnect error", e)
        }
    }

    // ── Conexão com o serviço do carro ────────────────────────────────────────

    private fun connectControlService() {
        try {
            if (!Shizuku.pingBinder()) { Log.e(TAG, "Shizuku not alive"); return }
            val binder: IBinder = ShizukuBinderWrapper(
                getSystemService("com.beantechs.intelligentvehiclecontrol")
            )
            if (!binder.isBinderAlive) { Log.e(TAG, "Control service binder not alive"); return }
            controlService = IIntelligentVehicleControlService.Stub.asInterface(binder)
            controlService!!.registerDataChangedListener(pkg, remoteListener)
            controlService!!.addListenerKey(pkg, KEYS)
            Log.i(TAG, "Connected — listening to ${KEYS.size} keys")
            // Notifica listeners de conexão na main thread
            val copy = synchronized(lock) { connectedListeners.toList() }
            Handler(Looper.getMainLooper()).post { copy.forEach { it() } }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to connect control service", e)
        }
    }

    private fun getSystemService(name: String): IBinder {
        val sm = Class.forName("android.os.ServiceManager")
        val method: Method = sm.getMethod("getService", String::class.java)
        return method.invoke(null, name) as IBinder
    }
}
