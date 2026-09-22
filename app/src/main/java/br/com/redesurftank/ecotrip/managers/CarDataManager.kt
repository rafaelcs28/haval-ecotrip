package br.com.redesurftank.ecotrip.managers

import android.content.Context
import android.os.Handler
import android.os.IBinder
import android.os.Looper
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
    private var appCtx: Context? = null

    val isConnected: Boolean get() = controlService != null

    /** Último valor CRU de cada chave do CarConstants, como o barramento entregou.
     *
     *  Existe pro viewer 3D, que fala o vocabulário do CarConstants nativamente:
     *  exportar o cru evita o round-trip pelos nossos campos normalizados, que
     *  perde informação (vetor de portas vira 5 booleanos, vidro de 4 estados vira
     *  2). E é um mapa, não campo por chave, pra não precisar mexer aqui toda vez
     *  que o viewer quiser mais uma. */
    private val rawValues = java.util.concurrent.ConcurrentHashMap<String, String>()
    val rawCarValues: Map<String, String> get() = rawValues

    private val remoteListener = object : IListener.Stub() {
        override fun onDataChanged(key: String, value: String) {
            ultimoDadoMs = System.currentTimeMillis()
            if (value.isNotEmpty()) rawValues[key] = value
            synchronized(lock) { dataListeners.toList() }.forEach { it(key, value) }
        }
    }

    /// Quando o barramento entregou algo pela última vez. É o único sinal que
    /// distingue "registrado e o carro está quieto" de "o registro caiu e eu não
    /// sei" — e era exatamente o que faltava.
    @Volatile private var ultimoDadoMs = 0L
    @Volatile private var ultimaTentativaMs = 0L

    /// Morte do serviço do CARRO (não do Shizuku).
    ///
    /// Aqui estava o buraco. O `shizukuDeadListener` cobre o Shizuku morrer, mas o
    /// que morre no despertar depois de horas paradas é o
    /// `com.beantechs.intelligentvehiclecontrol`: ele reinicia junto com a multimídia
    /// e PERDE a nossa inscrição. O Shizuku segue vivo, `pingBinder()` responde true,
    /// o `controlService` continua apontando pra um proxy morto — e ninguém
    /// re-registra. O app fica publicando MQTT com timestamp fresco e zero dado do
    /// CAN, que é exatamente o travamento de 22/09, três vezes no mesmo dia, sempre
    /// na primeira saída depois de um longo repouso.
    private val controlDeath = IBinder.DeathRecipient {
        AppLogger.w(TAG, "binder do serviço do carro MORREU — reconectando")
        controlService = null
        checkPermissionAndConnect()
    }

    // Shizuku binder chegou — verifica permissão antes de conectar
    private val shizukuBinderListener = object : Shizuku.OnBinderReceivedListener {
        override fun onBinderReceived() {
            AppLogger.i(TAG, "Shizuku binder received")
            checkPermissionAndConnect()
        }
    }

    // Resultado da solicitação de permissão ao usuário
    private val permissionResultListener =
        Shizuku.OnRequestPermissionResultListener { requestCode, grantResult ->
            if (requestCode == SHIZUKU_PERMISSION_REQUEST_CODE) {
                if (grantResult == android.content.pm.PackageManager.PERMISSION_GRANTED) {
                    AppLogger.i(TAG, "Shizuku permission granted — connecting")
                    connectControlService()
                } else {
                    AppLogger.w(TAG, "Shizuku permission DENIED by user")
                }
            }
        }

    private val shizukuDeadListener = Shizuku.OnBinderDeadListener {
        AppLogger.w(TAG, "Shizuku binder died")
        controlService = null
    }

    fun init(context: Context) {
        pkg = context.packageName
        appCtx = context.applicationContext
        HiddenApiBypass.addHiddenApiExemptions("")
        Shizuku.addRequestPermissionResultListener(permissionResultListener)
        Shizuku.addBinderReceivedListenerSticky(shizukuBinderListener)
        Shizuku.addBinderDeadListener(shizukuDeadListener)
    }

    fun destroy() {
        try {
            controlService?.unRegisterDataChangedListener(pkg, remoteListener)
        } catch (e: Exception) {
            AppLogger.e(TAG, "destroy error", e)
        }
        Shizuku.removeBinderReceivedListener(shizukuBinderListener)
        Shizuku.removeBinderDeadListener(shizukuDeadListener)
        Shizuku.removeRequestPermissionResultListener(permissionResultListener)
        controlService = null
    }

    /**
     * Vigia do registro: silêncio longo do barramento = inscrição caída.
     *
     * `linkToDeath` cobre o serviço MORRER. Não cobre o caso em que ele sobrevive
     * mas esquece de nós — o binder segue vivo, `pingBinder()` diz sim, e o dado
     * nunca chega. Do lado de fora as duas falhas são idênticas: painel mudo.
     *
     * 90 s de silêncio é seguro mesmo com o carro dormindo: reconectar é registrar
     * de novo, operação idempotente e barata. Melhor tentar à toa de vez em quando
     * do que ficar cego uma viagem inteira — que foi o que aconteceu três vezes hoje.
     *
     * Chamado pelo CarTelemetryService, que já tem laço próprio.
     */
    fun vigiaRegistro() {
        val agora = System.currentTimeMillis()
        if (ultimoDadoMs > 0 && agora - ultimoDadoMs < 90_000) return
        if (agora - ultimaTentativaMs < 60_000) return     // no máximo 1 tentativa/min
        ultimaTentativaMs = agora
        val quieto = if (ultimoDadoMs > 0) (agora - ultimoDadoMs) / 1000 else -1
        AppLogger.w(TAG, "barramento quieto há ${quieto}s — re-registrando no serviço do carro")
        checkPermissionAndConnect()
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
                    AppLogger.e(TAG, "Shizuku binder not alive")
                }
                // Permissão já concedida — conecta direto
                Shizuku.checkSelfPermission() == android.content.pm.PackageManager.PERMISSION_GRANTED -> {
                    AppLogger.i(TAG, "Shizuku permission already granted")
                    connectControlService()
                }
                // Nunca pediu permissão — solicita ao usuário (abre dialog do Shizuku)
                else -> {
                    AppLogger.i(TAG, "Requesting Shizuku permission")
                    Shizuku.requestPermission(SHIZUKU_PERMISSION_REQUEST_CODE)
                }
            }
        } catch (e: Exception) {
            AppLogger.e(TAG, "checkPermissionAndConnect error", e)
        }
    }

    // ── Conexão com o serviço do carro ────────────────────────────────────────

    private fun connectControlService() {
        try {
            if (!Shizuku.pingBinder()) { AppLogger.e(TAG, "Shizuku not alive"); return }
            val binder: IBinder = ShizukuBinderWrapper(
                getSystemService("com.beantechs.intelligentvehiclecontrol")
            )
            if (!binder.isBinderAlive) { AppLogger.e(TAG, "Control service binder not alive"); return }
            // Registra num val local: se o binder morrer entre a atribuição e as
            // chamadas, o shizukuDeadListener zera controlService e o `!!` daria NPE.
            // Só publica em controlService depois de registrar com sucesso.
            val svc = IIntelligentVehicleControlService.Stub.asInterface(binder)
            svc.registerDataChangedListener(pkg, remoteListener)
            svc.addListenerKey(pkg, KEYS)
            // Avisa quando ESTE serviço cair. Sem isto a inscrição sumia calada.
            try { binder.linkToDeath(controlDeath, 0) }
            catch (e: Exception) { AppLogger.w(TAG, "linkToDeath falhou: ${e.message}") }
            controlService = svc
            ultimoDadoMs = System.currentTimeMillis()
            AppLogger.i(TAG, "Connected — listening to ${KEYS.size} keys")
            // Shizuku confirmado vivo+autorizado: concede RECORD_AUDIO (escuta ao
            // vivo) que nunca foi pedida em runtime no head-unit.
            appCtx?.let { ShizukuPerms.ensureGranted(it, android.Manifest.permission.RECORD_AUDIO) }
            // Notifica listeners de conexão na main thread
            val copy = synchronized(lock) { connectedListeners.toList() }
            Handler(Looper.getMainLooper()).post { copy.forEach { it() } }
        } catch (e: Exception) {
            AppLogger.e(TAG, "Failed to connect control service", e)
        }
    }

    private fun getSystemService(name: String): IBinder {
        val sm = Class.forName("android.os.ServiceManager")
        val method: Method = sm.getMethod("getService", String::class.java)
        return method.invoke(null, name) as IBinder
    }
}
