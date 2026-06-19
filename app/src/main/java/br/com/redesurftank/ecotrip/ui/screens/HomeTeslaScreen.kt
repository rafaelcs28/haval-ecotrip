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
import br.com.redesurftank.ecotrip.BuildConfig
import br.com.redesurftank.ecotrip.managers.CarDataManager
import br.com.redesurftank.ecotrip.managers.LocalApiServer
import br.com.redesurftank.ecotrip.models.CarConstants
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import org.json.JSONObject

/**
 * Tela inicial "Tesla" (layout 0) — render do desenho `home/tesla-fluxo.html`:
 * carro raio-x com fluxo de energia por eixo (data-driven) + grade de viagem.
 *
 * Igual à Controles, o WebView fica FORA do Compose (filho direto da FrameLayout
 * da Activity) — neste ROM (Android 9) o WebView acelerado dentro do Compose
 * renderiza preto. [HomeTeslaWebHost] gerencia esse WebView.
 *
 * Alimentação: window.applyHome({header/nav/viagem}) + window.applyFlow({powertrain}).
 */
object HomeTeslaWebHost {
    @Volatile private var root: FrameLayout? = null
    private var web: WebView? = null

    // Ícones do header → overlays Compose. ConsumptionScreen pluga os callbacks.
    var onOpenSettings: () -> Unit = {}
    var onOpenRecargas: () -> Unit = {}
    var onOpenViagens: () -> Unit = {}

    private val mainH = Handler(Looper.getMainLooper())

    fun attach(r: FrameLayout) { root = r }

    fun isShowing(): Boolean = web != null && web?.visibility == View.VISIBLE

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
                settings.mediaPlaybackRequiresUserGesture = false
                isVerticalScrollBarEnabled = false
                isHorizontalScrollBarEnabled = false
                webViewClient = object : WebViewClient() {
                    override fun onReceivedError(v: WebView?, req: WebResourceRequest?, e: WebResourceError?) {
                        Log.w("HomeTeslaWeb", "erro ${req?.url}: ${e?.errorCode} ${e?.description}")
                    }
                }
                webChromeClient = object : WebChromeClient() {
                    override fun onConsoleMessage(msg: ConsoleMessage): Boolean {
                        Log.w("HomeTeslaWeb", "console: ${msg.message()} @${msg.lineNumber()}")
                        return true
                    }
                }
                addJavascriptInterface(HomeBridge(), "EcotripCarBridge")
                loadUrl("file:///android_asset/home/tesla-fluxo.html")
            }
            r.addView(web, FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        }
        web?.apply { visibility = View.VISIBLE; bringToFront() }
    }

    fun hide() { web?.visibility = View.GONE }

    fun feedHome(json: String) {
        val w = web ?: return
        w.post { w.evaluateJavascript("window.applyHome && window.applyHome($json)", null) }
    }

    fun feedFlow(json: String) {
        val w = web ?: return
        w.post { w.evaluateJavascript("window.applyFlow && window.applyFlow($json)", null) }
    }

    /** Ponte JS→Kotlin: ícones do header abrem os overlays Compose. */
    private class HomeBridge {
        private fun main(block: () -> Unit) = Handler(Looper.getMainLooper()).post(block)
        @JavascriptInterface fun openSettings() = main { onOpenSettings() }
        @JavascriptInterface fun openRecargas() = main { onOpenRecargas() }
        @JavascriptInterface fun openViagens() = main { onOpenViagens() }
    }
}

// ── pt-BR: milhar "." decimal "," ──
private val HT_PTBR = java.util.Locale("pt", "BR")
private fun htF(v: Float, dec: Int): String = String.format(HT_PTBR, "%,.${dec}f", v)

private fun socColorHex(soc: Int): String = when {
    soc < 30 -> "#FF5F1F"
    soc < 50 -> "#FFB648"
    else     -> "#28C98A"
}

/** JSON pro applyHome: header + navegação + grade de viagem (a partir do HomeData). */
private fun buildTeslaHomeJson(hd: HomeData): String {
    val o = JSONObject()
    o.put("temp", hd.outsideTempC)
    o.put("version", "v" + BuildConfig.VERSION_NAME)
    o.put("dist", htF(hd.distKm, 1))
    o.put("time", hd.timeStr)
    o.put("avg", hd.avgSpeedKmh)
    o.put("cons", htF(hd.kwh100, 1))
    o.put("kwh", htF(hd.netKwh, 1))
    o.put("regen", "regen " + htF(hd.regenKwh, 1) + " kWh")
    o.put("cost", "R$ " + htF(hd.costBrl, 2))
    o.put("costkm", "R$ " + htF(hd.costPerKm, 3) + " / km")
    val fuelTxt = if (hd.modeEv) htF(hd.fuelL, 1) + " L · EV" else htF(hd.fuelL, 1) + " L"
    o.put("fuel", fuelTxt)
    o.put("soc", "SOC ${hd.startSocPct}% → ${hd.socPct}%")
    o.put("navActive", hd.navActive)
    if (hd.navActive) {
        o.put("navName", hd.navName)
        o.put("navEta", hd.navEtaClock)
        o.put("navDist", htF(hd.navDistKm, 1) + " km")
        o.put("navSoc", "${hd.navArrivalSoc}%")
        o.put("navSocColor", socColorHex(hd.navArrivalSoc))
    }
    return o.toString()
}

// Escala provisória rotação→kW do motor traseiro (não há chave de potência
// traseira; só rear_motor_speed). Calibrar com o log TeslaFlow. Placeholder.
private const val REAR_KW_PER_RPM = 0.008

// Lê rear_motor_speed (rotação do eixo traseiro). Cacheia pra não bloquear cada tick.
private fun readRearMotorSpeed(): Double {
    return try {
        CarDataManager.getInstance()
            .fetchCurrent(CarConstants.CAR_EV_INFO_REAR_MOTOR_SPEED.value)
            ?.trim()?.toDoubleOrNull() ?: 0.0
    } catch (_: Exception) { 0.0 }
}

// Leitura de diagnóstico das chaves de powertrain ainda não confirmadas — só loga
// os valores crus pra confirmar a semântica no veículo (task do handoff).
private var _lastFlowDiag = 0L
private fun diagPowertrain(rawFrontKw: Double, speed: Double) {
    val now = System.currentTimeMillis()
    if (now - _lastFlowDiag < 3000) return
    _lastFlowDiag = now
    val car = CarDataManager.getInstance()
    fun rd(k: String): String? = try { car.fetchCurrent(k)?.trim() } catch (_: Exception) { null }
    try {
        val hcu = rd(CarConstants.CAR_EV_INFO_HCU_POWER_TRAIN_STATE.value)
        val drv = rd(CarConstants.CAR_EV_INFO_ENERGY_DRIVE_STATE.value)
        val eng = rd(CarConstants.CAR_BASIC_ENGINE_STATE.value)
        val rear = rd(CarConstants.CAR_EV_INFO_REAR_MOTOR_SPEED.value)
        val mspd = rd(CarConstants.CAR_EV_INFO_MOTOR_SPEED.value)
        val rec = rd(CarConstants.CAR_EV_INFO_ENERGY_RECOVERY_INFO.value)
        val eax = rd(CarConstants.CAR_CONFIGURE_E_AXLE.value)
        Log.w("TeslaFlow", "speed=${Math.round(speed)} rawFrontKw=${Math.round(rawFrontKw)} " +
            "hcu_power_train_state=$hcu energy_drive_state=$drv engine_state=$eng " +
            "rear_motor_speed=$rear motor_speed=$mspd energy_recovery_info=$rec e_axle=$eax")
    } catch (_: Exception) {}
}

/** JSON pro applyFlow a partir do snapshot in-process. Sinais confirmados (soc,
 *  socKm, frontKw, charging, térmico ligado); rear/série/engineKw em melhor-esforço
 *  até confirmar a semântica dos inteiros no veículo. */
private fun buildTeslaFlowJson(): String {
    val snap = try {
        LocalApiServer.current?.snapshotJson()?.let { JSONObject(it) } ?: JSONObject()
    } catch (_: Exception) { JSONObject() }
    val soc = snap.optInt("soc_pct", 0)
    val socKm = snap.optInt("ev_remain_km", 0)
    val rawFront = snap.optDouble("motor_power_kw", 0.0)
    val speed = snap.optDouble("speed_kmh", 0.0)
    val rpm = snap.optDouble("engine_rpm", 0.0)
    val chargingState = snap.optInt("charging_state", 0)
    val engineOn = rpm > 0
    // Potência ÀS RODAS só existe com o carro em movimento — parado, roda não gira,
    // não há tração/regen (o que o carro consome parado é carga auxiliar, não vai pra
    // roda). Trava em 0 abaixo de ~1 km/h + zona morta p/ ruído.
    val moving = speed >= 1.0
    val frontKw = if (!moving || kotlin.math.abs(rawFront) < 1.0) 0.0 else rawFront
    // ESTIMATIVA de kW do térmico por rpm (sem telemetria de potência térmica) — refinar após confirmar.
    val engineKw = if (engineOn) (rpm / 60.0).coerceIn(5.0, 90.0) else 0.0
    // Heurística de série: térmico ligado sem tração elétrica dianteira — refinar com hcu_power_train_state.
    val series = engineOn && kotlin.math.abs(frontKw) < 2.0
    val charging = if (chargingState == 1) "ac" else "none"

    // Eixo traseiro (AWD): sem chave de potência → deriva da rotação (atividade) e
    // do sinal do motor dianteiro (regen quando frontKw<0). Só com o carro andando.
    // Magnitude estimada por REAR_KW_PER_RPM — calibrar com o log.
    val rearSpeed = readRearMotorSpeed()
    val rearActive = moving && kotlin.math.abs(rearSpeed) > 100.0
    val rearKw = if (!rearActive) 0.0 else {
        val mag = (kotlin.math.abs(rearSpeed) * REAR_KW_PER_RPM).coerceIn(1.0, 130.0)
        if (frontKw < -0.5) -mag else mag   // regen se o conjunto está regenerando
    }
    diagPowertrain(rawFront, speed)
    return JSONObject()
        .put("soc", soc)
        .put("socKm", socKm)
        .put("engineKw", Math.round(engineKw))
        .put("frontKw", Math.round(frontKw))
        .put("rearKw", Math.round(rearKw))
        .put("seriesMode", series)
        .put("charging", charging)
        .toString()
}

/**
 * "Renderiza" o overlay do home Tesla: mostra o WebView (fora do Compose) e o
 * alimenta (viagem + powertrain). Some ao sair de composição.
 */
@Composable
fun HomeTeslaWebLayout(
    hd: HomeData,
    onOpenSettings: () -> Unit,
    onOpenRecargas: () -> Unit = {},
    onOpenViagens: () -> Unit = {},
) {
    val ctx = LocalContext.current
    val hdState = rememberUpdatedState(hd)

    DisposableEffect(Unit) {
        HomeTeslaWebHost.onOpenSettings = onOpenSettings
        HomeTeslaWebHost.onOpenRecargas = onOpenRecargas
        HomeTeslaWebHost.onOpenViagens = onOpenViagens
        HomeTeslaWebHost.show(ctx)
        onDispose { HomeTeslaWebHost.hide() }
    }

    LaunchedEffect(Unit) {
        while (true) {
            val home = withContext(Dispatchers.Default) { buildTeslaHomeJson(hdState.value) }
            HomeTeslaWebHost.feedHome(home)
            val flow = withContext(Dispatchers.Default) { buildTeslaFlowJson() }
            HomeTeslaWebHost.feedFlow(flow)
            delay(700L)
        }
    }
}
