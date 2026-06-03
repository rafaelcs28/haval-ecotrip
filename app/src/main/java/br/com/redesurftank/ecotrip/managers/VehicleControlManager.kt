package br.com.redesurftank.ecotrip.managers

import android.os.IBinder
import com.beantechs.voice.adapter.IBinderPool
import com.beantechs.voice.adapter.IVehicle
import rikka.shizuku.Shizuku
import rikka.shizuku.ShizukuBinderWrapper
import java.lang.reflect.Method

/**
 * Controle físico do carro (vidro, teto solar, cortina, porta) via binder IVehicle,
 * obtido pelo IBinderPool do VoiceAdapterService (pool id=6) através do Shizuku.
 *
 * Mecanismo idêntico ao app de referência bobaoapae/haval-app-tool-multimidia.
 * O AIDL IVehicle.aidl precisa ser BYTE-IDÊNTICO ao do serviço (a ordem dos
 * métodos define os códigos de transação do binder).
 *
 * Convenções de valor (descobertas no ref; "abrir" do vidro ainda a confirmar):
 *  - setWindowStatus(janela, status): status 1 = FECHADO. Demais valores = abertura.
 *  - setSkylightLevel(level): 0 = FECHADO, >0 = aberto.
 *  - setShadeScreensLevel(level): 0 = fechado.
 */
object VehicleControlManager {
    private const val TAG = "VehicleControlManager"
    private const val POOL_SERVICE = "com.beantechs.voice.adapter.VoiceAdapterService"
    private const val BINDER_VEHICLE = 6

    @Volatile private var vehicle: IVehicle? = null

    val isConnected: Boolean get() = vehicle?.asBinder()?.isBinderAlive == true

    /** Conecta (lazy) ao IVehicle. Retorna o binder vivo ou null. */
    @Synchronized
    private fun connect(): IVehicle? {
        vehicle?.let { if (it.asBinder()?.isBinderAlive == true) return it }
        vehicle = null
        try {
            if (!Shizuku.pingBinder()) { AppLogger.w(TAG, "Shizuku não está vivo"); return null }
            if (Shizuku.checkSelfPermission() != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                AppLogger.w(TAG, "Sem permissão Shizuku"); return null
            }
            val poolBinder: IBinder = ShizukuBinderWrapper(getSystemService(POOL_SERVICE))
            if (!poolBinder.pingBinder()) { AppLogger.e(TAG, "Pool binder morto"); return null }
            val pool = IBinderPool.Stub.asInterface(poolBinder)
            val vehicleBinder = pool.queryBinder(BINDER_VEHICLE)
            val v = IVehicle.Stub.asInterface(ShizukuBinderWrapper(vehicleBinder))
            vehicle = v
            AppLogger.i(TAG, "IVehicle conectado")
            return v
        } catch (e: Exception) {
            AppLogger.e(TAG, "Falha ao conectar IVehicle: ${e.message}")
            return null
        }
    }

    /** Status atual de cada janela (array; 1 = fechado). null se indisponível. */
    fun getWindowsStatus(): IntArray? = try {
        connect()?.getWindowsStatus(0)
    } catch (e: Exception) { AppLogger.e(TAG, "getWindowsStatus: ${e.message}"); null }

    /** Define o status de UMA janela. status 1 = fechar; outros = abrir (a confirmar). */
    fun setWindowStatus(window: Int, status: Int): Boolean = try {
        val v = connect() ?: return false
        AppLogger.i(TAG, "setWindowStatus(window=$window, status=$status)")
        v.setWindowStatus(window, status); true
    } catch (e: Exception) { AppLogger.e(TAG, "setWindowStatus: ${e.message}"); false }

    /** Aplica o mesmo status a todas as janelas conhecidas. */
    fun setAllWindows(status: Int): Boolean {
        val cur = getWindowsStatus() ?: return false
        var ok = true
        for (i in cur.indices) ok = setWindowStatus(i, status) && ok
        return ok
    }

    fun getSkylightLevel(): Int? = try { connect()?.getSkylightLevel(0) }
        catch (e: Exception) { AppLogger.e(TAG, "getSkylightLevel: ${e.message}"); null }

    fun setSkylightLevel(level: Int): Boolean = try {
        val v = connect() ?: return false
        AppLogger.i(TAG, "setSkylightLevel($level)")
        v.setSkylightLevel(level); true
    } catch (e: Exception) { AppLogger.e(TAG, "setSkylightLevel: ${e.message}"); false }

    fun getShadeScreensLevel(): Int? = try { connect()?.getShadeScreensLevel(0) }
        catch (e: Exception) { AppLogger.e(TAG, "getShadeScreensLevel: ${e.message}"); null }

    fun setShadeScreensLevel(level: Int): Boolean = try {
        val v = connect() ?: return false
        AppLogger.i(TAG, "setShadeScreensLevel($level)")
        v.setShadeScreensLevel(level); true
    } catch (e: Exception) { AppLogger.e(TAG, "setShadeScreensLevel: ${e.message}"); false }

    /** setDoorOpen(param1, param2) — semântica de índices a confirmar no carro. */
    fun setDoorOpen(p1: Int, p2: Int): Boolean = try {
        val v = connect() ?: return false
        AppLogger.i(TAG, "setDoorOpen($p1, $p2)")
        v.setDoorOpen(p1, p2); true
    } catch (e: Exception) { AppLogger.e(TAG, "setDoorOpen: ${e.message}"); false }

    private fun getSystemService(name: String): IBinder {
        val sm = Class.forName("android.os.ServiceManager")
        val method: Method = sm.getMethod("getService", String::class.java)
        return method.invoke(null, name) as IBinder
    }
}
