package br.com.redesurftank.ecotrip.ui.screens

import android.annotation.SuppressLint
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.View
import android.webkit.ConsoleMessage
import android.webkit.JavascriptInterface
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.platform.LocalContext
import br.com.redesurftank.ecotrip.managers.CarDataManager
import br.com.redesurftank.ecotrip.managers.LocalApiServer
import br.com.redesurftank.ecotrip.managers.MqttManager
import br.com.redesurftank.ecotrip.models.CarConstants
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import org.json.JSONObject

/**
 * Tela "Controles" embarcada no head unit (4º layout da tela inicial).
 *
 * IMPORTANTE: o WebView NÃO fica dentro do Compose (AndroidView) — nesse ROM
 * (Android 9) o WebView acelerado dentro do Compose renderiza preto. Em vez
 * disso ele é filho direto da FrameLayout da Activity (irmão do ComposeView,
 * fora da árvore de desenho do Compose), igual ao módulo cluster/ que roda
 * liso aqui. [ControlesWebHost] gerencia esse WebView overlay.
 *
 * Comandos vão DIRETO ao carro in-process (MqttManager.dispatchLocalCommand).
 * Estado: LocalApiServer.snapshotJson() + viagem (HomeData) via _nativeBridge.update.
 */

/** Dono do WebView overlay (fora do Compose). MainActivity registra a raiz. */
object ControlesWebHost {
    @Volatile private var root: FrameLayout? = null
    private var web: WebView? = null

    // Callbacks dos botões do topo (Config/Recargas/Viagens/Atualizar). Estáveis:
    // o EcotripCarBridge (criado 1x) chama estes; o ControlesLayout os atualiza.
    var onOpenSettings: () -> Unit = {}
    var onOpenRecargas: () -> Unit = {}
    var onOpenViagens: () -> Unit = {}
    var onCheckUpdate: () -> Unit = {}

    // Carrossel: onEnterRequest(dir) = swipe na favorita pediu pra abrir Controles;
    // onExit = swipe no limite das páginas internas pediu pra voltar à favorita.
    var onEnterRequest: (Int) -> Unit = {}
    var onExit: () -> Unit = {}

    // Player de mídia (Fase 3): MainActivity injeta o helper.
    var media: br.com.redesurftank.ecotrip.managers.MediaControllerHelper? = null

    private val mainH = Handler(Looper.getMainLooper())

    fun attach(r: FrameLayout) { root = r }

    fun isShowing(): Boolean = web != null && web?.visibility == View.VISIBLE

    /** Chamado pela MainActivity (gesto de 2 dedos na favorita). */
    fun requestEnter(dir: Int) { mainH.post { onEnterRequest(dir) } }

    /** Manda o WebView ir pra página interna (0=Dirigir, 1=Veículo). */
    fun showPage(p: Int) {
        val w = web ?: return
        w.post { w.evaluateJavascript("window.ControlScreen && window.ControlScreen.show($p)", null) }
    }

    @SuppressLint("SetJavaScriptEnabled")
    fun show(ctx: Context) {
        val r = root ?: return
        if (web == null) {
            web = WebView(ctx.applicationContext).apply {
                setBackgroundColor(android.graphics.Color.BLACK)
                settings.javaScriptEnabled = true
                settings.domStorageEnabled = true
                settings.allowFileAccess = true
                @Suppress("DEPRECATION") settings.allowFileAccessFromFileURLs = true
                @Suppress("DEPRECATION") settings.allowUniversalAccessFromFileURLs = true
                settings.textZoom = 100
                // NÃO usar useWideViewPort/loadWithOverviewMode: a página é
                // responsiva (100vw/100vh) e esses dão "zoom out" deixando vazio.
                settings.mediaPlaybackRequiresUserGesture = false
                isVerticalScrollBarEnabled = false
                isHorizontalScrollBarEnabled = false
                webViewClient = object : WebViewClient() {
                    override fun onReceivedError(v: WebView?, req: WebResourceRequest?, e: WebResourceError?) {
                        Log.w("ControlesWeb", "erro ${req?.url}: ${e?.errorCode} ${e?.description}")
                    }
                }
                webChromeClient = object : WebChromeClient() {
                    override fun onConsoleMessage(m: ConsoleMessage): Boolean {
                        Log.w("ControlesWeb", "console: ${m.message()} @${m.lineNumber()}")
                        return true
                    }
                }
                WebView.setWebContentsDebuggingEnabled(true)
                addJavascriptInterface(EcotripCarBridge(), "EcotripCarBridge")
                addJavascriptInterface(AppNavBridge(), "AppNav")
                addJavascriptInterface(MediaBridge(), "MediaBridge")
                loadUrl("file:///android_asset/controles/cockpit.html")
            }
            r.addView(web, FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        }
        web?.apply { visibility = View.VISIBLE; bringToFront() }
    }

    fun hide() { web?.visibility = View.GONE }

    fun feed(json: String) {
        val w = web ?: return
        w.post { w.evaluateJavascript("window._nativeBridge && window._nativeBridge.update($json)", null) }
    }

    /** Empurra o estado de mídia (window.applyMedia) a partir do helper. */
    fun feedMediaFromHelper() {
        val h = media ?: return
        val w = web ?: return
        val s = h.state
        val o = JSONObject()
        o.put("title", s.title ?: JSONObject.NULL)
        o.put("artist", s.artist ?: JSONObject.NULL)
        o.put("album", s.album ?: JSONObject.NULL)
        o.put("artworkUrl", h.artworkDataUri() ?: JSONObject.NULL)
        o.put("isPlaying", s.isPlaying)
        o.put("durationMs", s.durationMs)
        o.put("elapsedMs", s.elapsedMs)
        o.put("canSeek", s.canSeek)
        o.put("packageName", s.packageName ?: JSONObject.NULL)
        o.put("volume", h.volume())
        o.put("volumeMax", h.volumeMax())
        val js = o.toString()
        w.post { w.evaluateJavascript("window.applyMedia && window.applyMedia($js)", null) }
    }
}

/**
 * "Renderiza" o overlay: ao entrar em composição mostra o WebView (fora do
 * Compose) e alimenta o estado; ao sair, esconde. Não desenha nada em Compose.
 */
@Composable
fun ControlesLayout(
    hd: HomeData,
    onOpenSettings: () -> Unit,
    onOpenRecargas: () -> Unit = {},
    onOpenViagens: () -> Unit = {},
    onCheckUpdate: () -> Unit = {},
) {
    val ctx = LocalContext.current
    val hdState = rememberUpdatedState(hd)

    DisposableEffect(Unit) {
        ControlesWebHost.onOpenSettings = onOpenSettings
        ControlesWebHost.onOpenRecargas = onOpenRecargas
        ControlesWebHost.onOpenViagens = onOpenViagens
        ControlesWebHost.onCheckUpdate = onCheckUpdate
        ControlesWebHost.show(ctx)
        onDispose { ControlesWebHost.hide() }
    }

    LaunchedEffect(Unit) {
        while (true) {
            val json = withContext(Dispatchers.Default) { buildControlesSnapshot(hdState.value) }
            ControlesWebHost.feed(json)
            ControlesWebHost.media?.start()   // re-tenta caso o listener só tenha vinculado depois
            ControlesWebHost.feedMediaFromHelper()   // reenvia estado de mídia mesmo sem mudança
            delay(800L)
        }
    }
}

/** Ponte JS→Kotlin. postCommand recebe {__cmd,value} e despacha in-process. */
private class EcotripCarBridge {
    private fun main(block: () -> Unit) = Handler(Looper.getMainLooper()).post(block)

    @JavascriptInterface
    fun postCommand(json: String) {
        try {
            val o = JSONObject(json)
            val cmd = o.optString("__cmd")
            if (cmd.isBlank()) return
            val value = if (o.isNull("value")) "" else o.get("value").toString()
            MqttManager.getInstance().dispatchLocalCommand(cmd, value)
        } catch (_: Exception) { /* comando malformado — ignora */ }
    }

    @JavascriptInterface fun openSettings() = main { ControlesWebHost.onOpenSettings() }
    @JavascriptInterface fun openRecargas() = main { ControlesWebHost.onOpenRecargas() }
    @JavascriptInterface fun openViagens() = main { ControlesWebHost.onOpenViagens() }
    @JavascriptInterface fun checkUpdate() = main { ControlesWebHost.onCheckUpdate() }
}

/** Ponte de navegação: o HTML chama AppNav.swipe(dir) no limite das páginas
 *  internas pra sair da Controles e voltar pra tela favorita. */
private class AppNavBridge {
    @JavascriptInterface
    fun swipe(dir: Int) {
        Handler(Looper.getMainLooper()).post { ControlesWebHost.onExit() }
    }
}

/** Ponte de mídia: botões do player chamam estes; encaminha pro helper. */
private class MediaBridge {
    private fun main(b: () -> Unit) = Handler(Looper.getMainLooper()).post(b)
    @JavascriptInterface fun playPause() = main { ControlesWebHost.media?.playPause() }
    @JavascriptInterface fun next() = main { ControlesWebHost.media?.next() }
    @JavascriptInterface fun previous() = main { ControlesWebHost.media?.previous() }
    @JavascriptInterface fun seekTo(ms: Int) = main { ControlesWebHost.media?.seekTo(ms.toLong()) }
    @JavascriptInterface fun setVolume(v: Int) = main { ControlesWebHost.media?.setVolume(v) }
}

private fun ptBr(v: Float, dec: Int): String =
    String.format(java.util.Locale.US, "%,.${dec}f", v).replace(",", "X").replace(".", ",").replace("X", ".")

/**
 * Lê ativamente do CAN as configs de condução (que o carro nem sempre transmite
 * no barramento quando mudadas por fora) e atualiza o estado via syncXFromCar.
 * Assim a tela reflete mudanças feitas direto no carro. Throttle ~1,5s.
 */
private var _lastSettingsSync = 0L
private fun syncDriveSettingsFromCar() {
    val now = System.currentTimeMillis()
    if (now - _lastSettingsSync < 1500) return
    _lastSettingsSync = now
    val m = MqttManager.getInstance()
    val car = CarDataManager.getInstance()
    fun rd(k: String): Int? = try { car.fetchCurrent(k)?.trim()?.toFloatOrNull()?.toInt() } catch (_: Exception) { null }
    try {
        rd(CarConstants.CAR_EV_SETTING_POWER_MODEL_CONFIG.value)?.let { m.syncDriveModeFromCar(it) }
        rd(CarConstants.CAR_EV_SETTING_POWER_RESERVE_CONFIG.value)?.let { m.syncPowerReserveFromCar(it) }
        rd(CarConstants.CAR_EV_SETTING_CHARGE_SOC_TARGET_CONFIG.value)?.let { m.syncSocTargetFromCar(it) }
        rd(CarConstants.CAR_DRIVE_SETTING_DRIVE_MODE.value)?.let { m.syncTerrainModeFromCar(it) }
        rd(CarConstants.CAR_EV_SETTING_ENERGY_RECOVERY_LEVEL.value)?.let { m.syncRegenLevelFromCar(it) }
        rd(CarConstants.CAR_EV_SETTING_PEDAL_CONTROL_ENABLE.value)?.let { m.syncOnePedalFromCar(it) }
        rd(CarConstants.CAR_DRIVE_SETTING_ESP_ENABLE.value)?.let { m.syncEspFromCar(it) }
        rd(CarConstants.CAR_DRIVE_SETTING_STEER_MODE.value)?.let { m.syncSteerModeFromCar(it) }
    } catch (_: Exception) {}
}

/** Monta o JSON: telemetria/controles (snapshot in-process) + viagem (HomeData). */
private fun buildControlesSnapshot(hd: HomeData): String {
    syncDriveSettingsFromCar()
    val o = try {
        LocalApiServer.current?.snapshotJson()?.let { JSONObject(it) } ?: JSONObject()
    } catch (_: Exception) { JSONObject() }

    o.put("trip_dist", ptBr(hd.distKm, 1))
    o.put("trip_time", hd.timeStr)
    o.put("trip_kwh", ptBr(hd.netKwh, 1))
    o.put("trip_fuel", ptBr(hd.fuelL, 1))
    o.put("trip_cost", "R$ " + ptBr(hd.costBrl, 2))
    o.put("trip_cost_km", "R$ " + ptBr(hd.costPerKm, 2))
    o.put("trip_regen_kwh", ptBr(hd.regenKwh, 1))
    o.put("trip_regen_pct", "${hd.regenPct}%")
    o.put("trip_ce", ptBr(hd.kwh100, 1))
    val kml = if (hd.fuelL > 0.001f) hd.distKm / hd.fuelL else 0f
    o.put("trip_kml", ptBr(kml, 1))
    if (hd.navActive) {
        val dest = "→ <b>${hd.navName}</b><span class=\"sep\">·</span><b>${ptBr(hd.navDistKm, 1)} km</b>" +
            "<span class=\"sep\">·</span>ETA <b>${hd.navEtaClock}</b>" +
            "<span class=\"sep\">·</span>chegada <b>${hd.navArrivalSoc}%</b>"
        o.put("trip_dest", dest)
    }
    return o.toString()
}
