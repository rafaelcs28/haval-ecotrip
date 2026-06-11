package br.com.redesurftank.ecotrip.ui.screens

import android.annotation.SuppressLint
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
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.viewinterop.AndroidView
import br.com.redesurftank.ecotrip.managers.LocalApiServer
import br.com.redesurftank.ecotrip.managers.MqttManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import org.json.JSONObject

/**
 * Tela "Controles" embarcada no head unit (4º layout da tela inicial).
 *
 * Renderiza o cockpit V4 (1920×720) num WebView e despacha os comandos DIRETO
 * ao carro in-process (MqttManager.dispatchLocalCommand) — sem LAN nem nuvem,
 * já que roda dentro do próprio app que tem as permissões do barramento.
 *
 * Estado: telemetria/controles vêm de LocalApiServer.snapshotJson() (mesmo JSON
 * do iPad) e a viagem em curso vem do [HomeData], mesclados via _nativeBridge.update.
 */
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun ControlesLayout(
    hd: HomeData,
    onOpenSettings: () -> Unit,
    onOpenRecargas: () -> Unit = {},
    onOpenViagens: () -> Unit = {},
    onCheckUpdate: () -> Unit = {},
) {
    val hdState = rememberUpdatedState(hd)
    val webHolder = remember { arrayOfNulls<WebView>(1) }

    AndroidView(
        modifier = Modifier.fillMaxSize().background(Color.Black),
        factory = { ctx ->
            WebView(ctx).apply {
                // Head unit (Android 9): WebView dentro do Compose AndroidView desenha
                // preto com aceleração de hardware. Camada de software resolve.
                setLayerType(View.LAYER_TYPE_SOFTWARE, null)
                setBackgroundColor(android.graphics.Color.BLACK)
                settings.javaScriptEnabled = true
                settings.domStorageEnabled = true
                settings.allowFileAccess = true
                settings.allowFileAccessFromFileURLs = true
                settings.allowUniversalAccessFromFileURLs = true
                settings.textZoom = 100
                settings.mediaPlaybackRequiresUserGesture = false
                isVerticalScrollBarEnabled = false
                isHorizontalScrollBarEnabled = false
                webViewClient = object : WebViewClient() {
                    override fun onReceivedError(view: WebView?, request: WebResourceRequest?, error: WebResourceError?) {
                        Log.w("ControlesWeb", "erro ao carregar ${request?.url}: ${error?.errorCode} ${error?.description}")
                    }
                }
                webChromeClient = object : WebChromeClient() {
                    override fun onConsoleMessage(m: ConsoleMessage): Boolean {
                        Log.w("ControlesWeb", "console: ${m.message()} @${m.sourceId()}:${m.lineNumber()}")
                        return true
                    }
                }
                WebView.setWebContentsDebuggingEnabled(true)
                addJavascriptInterface(
                    EcotripCarBridge(onOpenSettings, onOpenRecargas, onOpenViagens, onCheckUpdate),
                    "EcotripCarBridge",
                )
                loadUrl("file:///android_asset/controles/cockpit.html")
                webHolder[0] = this
            }
        },
    )

    // Feed de estado: ~3 Hz. Carro (snapshot in-process) + viagem (HomeData), mesclados.
    LaunchedEffect(Unit) {
        while (true) {
            val wv = webHolder[0]
            if (wv != null) {
                val json = withContext(Dispatchers.Default) { buildControlesSnapshot(hdState.value) }
                wv.post {
                    wv.evaluateJavascript(
                        "window._nativeBridge && window._nativeBridge.update($json)", null,
                    )
                }
            }
            delay(330L)
        }
    }
}

/** Ponte JS→Kotlin. postCommand recebe {__cmd,value} e despacha in-process. */
private class EcotripCarBridge(
    private val onOpenSettings: () -> Unit,
    private val onOpenRecargas: () -> Unit,
    private val onOpenViagens: () -> Unit,
    private val onCheckUpdate: () -> Unit,
) {
    private fun main(block: () -> Unit) = Handler(Looper.getMainLooper()).post(block)

    @JavascriptInterface
    fun postCommand(json: String) {
        try {
            val o = JSONObject(json)
            val cmd = o.optString("__cmd")
            if (cmd.isBlank()) return
            val value = when {
                o.isNull("value") -> ""
                else -> o.get("value").toString()
            }
            MqttManager.getInstance().dispatchLocalCommand(cmd, value)
        } catch (_: Exception) { /* comando malformado — ignora */ }
    }

    @JavascriptInterface fun openSettings() = main(onOpenSettings)
    @JavascriptInterface fun openRecargas() = main(onOpenRecargas)
    @JavascriptInterface fun openViagens() = main(onOpenViagens)
    @JavascriptInterface fun checkUpdate() = main(onCheckUpdate)
}

private fun ptBr(v: Float, dec: Int): String =
    String.format(java.util.Locale.US, "%,.${dec}f", v).replace(",", "X").replace(".", ",").replace("X", ".")

/** Monta o JSON: telemetria/controles (snapshot LAN) + viagem (HomeData). */
private fun buildControlesSnapshot(hd: HomeData): String {
    val o = try {
        LocalApiServer.current?.snapshotJson()?.let { JSONObject(it) } ?: JSONObject()
    } catch (_: Exception) { JSONObject() }

    // ── Viagem em curso (do TripManager via HomeData) ──
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
