package br.com.redesurftank.ecotripcluster

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.webkit.JavascriptInterface
import android.webkit.WebView
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.Toast
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.FileProvider
import org.json.JSONArray
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

class MainActivity : AppCompatActivity() {

    private lateinit var web: WebView
    private val prefs by lazy { getSharedPreferences("cluster", Context.MODE_PRIVATE) }

    // Exposto ao JS como window.AndroidCfg — o android-shim.js lê URL + senha daqui.
    inner class Cfg {
        @JavascriptInterface fun getBridgeUrl(): String =
            prefs.getString("bridgeUrl", "https://mqttrafael.duckdns.org") ?: ""
        @JavascriptInterface fun getPassword(): String =
            prefs.getString("password", "") ?: ""
        // Tema do cluster: "light" | "dark" (padrão dark)
        @JavascriptInterface fun getTheme(): String =
            prefs.getString("theme", "dark") ?: "dark"
        // LAN direta: URL ws:// do carro descoberta via mDNS (vazio = não achou)
        @JavascriptInterface fun getLanWsUrl(): String = lanWsUrl
        // Navegação: abre o seletor de apps de mapa do Android (Waze/Google Maps/etc.)
        @JavascriptInterface fun openNav() {
            runOnUiThread {
                try {
                    val i = Intent(Intent.ACTION_VIEW, Uri.parse("geo:0,0?q="))
                    startActivity(Intent.createChooser(i, "Navegar com"))
                } catch (_: Exception) {}
            }
        }
    }

    // ── Descoberta LAN do carro (mDNS _havalobd._tcp → ws://host:port/ws/state) ──
    @Volatile private var lanWsUrl: String = ""
    private var nsd: NsdManager? = null
    private var discoveryListener: NsdManager.DiscoveryListener? = null
    private var multicastLock: WifiManager.MulticastLock? = null
    @Volatile private var resolving = false

    private fun startLanDiscovery() {
        try {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            multicastLock = wifi.createMulticastLock("haval-cluster-mdns").apply {
                setReferenceCounted(true); acquire()
            }
            nsd = getSystemService(Context.NSD_SERVICE) as NsdManager
            val listener = object : NsdManager.DiscoveryListener {
                override fun onDiscoveryStarted(s: String?) {}
                override fun onDiscoveryStopped(s: String?) {}
                override fun onStartDiscoveryFailed(s: String?, e: Int) {}
                override fun onStopDiscoveryFailed(s: String?, e: Int) {}
                override fun onServiceLost(info: NsdServiceInfo?) { lanWsUrl = "" }
                override fun onServiceFound(info: NsdServiceInfo) {
                    if (info.serviceType.contains("_havalobd")) resolveService(info)
                }
            }
            discoveryListener = listener
            nsd?.discoverServices("_havalobd._tcp.", NsdManager.PROTOCOL_DNS_SD, listener)
        } catch (_: Exception) {}
    }

    private fun resolveService(info: NsdServiceInfo) {
        if (resolving) return
        resolving = true
        try {
            nsd?.resolveService(info, object : NsdManager.ResolveListener {
                override fun onResolveFailed(i: NsdServiceInfo?, e: Int) { resolving = false }
                override fun onServiceResolved(i: NsdServiceInfo) {
                    resolving = false
                    val host = i.host?.hostAddress ?: return
                    lanWsUrl = "ws://$host:${i.port}/ws/state"
                }
            })
        } catch (_: Exception) { resolving = false }
    }

    private fun stopLanDiscovery() {
        try { discoveryListener?.let { nsd?.stopServiceDiscovery(it) } } catch (_: Exception) {}
        try { multicastLock?.let { if (it.isHeld) it.release() } } catch (_: Exception) {}
    }

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        web = WebView(this).apply {
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.mediaPlaybackRequiresUserGesture = false
            settings.databaseEnabled = true
            // Ignora o tamanho de fonte/zoom do sistema (senão o cluster infla e corta)
            settings.textZoom = 100
            settings.useWideViewPort = true
            settings.loadWithOverviewMode = true
            // file:// → fetch p/ o bridge (https) sem bloqueio de CORS
            settings.allowFileAccess = true
            settings.allowContentAccess = true
            @Suppress("DEPRECATION")
            settings.allowFileAccessFromFileURLs = true
            @Suppress("DEPRECATION")
            settings.allowUniversalAccessFromFileURLs = true
            setBackgroundColor(0xFF000000.toInt())
            addJavascriptInterface(Cfg(), "AndroidCfg")
        }
        WebView.setWebContentsDebuggingEnabled(true)

        val root = FrameLayout(this)
        root.addView(web, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))

        // Botão de config discreto (canto superior direito)
        val cfgBtn = Button(this).apply {
            text = "⚙"
            alpha = 0.18f
            setOnClickListener { showSettings() }
        }
        val lp = FrameLayout.LayoutParams(140, 140).apply {
            gravity = Gravity.TOP or Gravity.END
            topMargin = 8; rightMargin = 8
        }
        root.addView(cfgBtn, lp)
        setContentView(root)

        loadCluster()
        startLanDiscovery()   // descobre o carro na LAN (ws:// direto, rápido)

        // Se ainda não configurou senha, abre o settings de cara.
        if (prefs.getString("password", "").isNullOrEmpty()) showSettings()
    }

    private fun loadCluster() {
        web.loadUrl("file:///android_asset/web/cluster.html")
    }

    private fun showSettings() {
        val ctx = this
        val container = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(48, 24, 48, 0)
        }
        val urlIn = EditText(ctx).apply {
            hint = "URL do bridge (https://...)"
            setText(prefs.getString("bridgeUrl", "https://mqttrafael.duckdns.org"))
            inputType = InputType.TYPE_TEXT_VARIATION_URI
        }
        val pwIn = EditText(ctx).apply {
            hint = "Senha do app (mesma do PWA)"
            setText(prefs.getString("password", ""))
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
        }
        container.addView(urlIn)
        container.addView(pwIn)
        val lanLbl = android.widget.TextView(ctx).apply {
            text = "LAN: " + (if (lanWsUrl.isNotEmpty()) lanWsUrl else "não encontrada (usando cloud)")
            textSize = 12f; setPadding(0, 16, 0, 0)
        }
        container.addView(lanLbl)

        AlertDialog.Builder(ctx)
            .setTitle("Configuração do Cluster (v" + installedVersion() + ")")
            .setView(container)
            .setPositiveButton("Salvar") { _, _ ->
                prefs.edit()
                    .putString("bridgeUrl", urlIn.text.toString().trim())
                    .putString("password", pwIn.text.toString())
                    .apply()
                loadCluster()   // recarrega com a nova config
            }
            .setNeutralButton("Atualizar app") { _, _ -> checkForUpdate() }
            .setNegativeButton("Cancelar", null)
            .show()
    }

    // ── Auto-update via GitHub Releases (tags "cluster-vX.Y") ───────────────────
    // per_page=100: as ~22 releases do carro (v5.x) vêm antes das do cluster, então
    // com 30 as cluster mais novas (v1.10+) ficavam de fora e o update não as via.
    private val GH_RELEASES =
        "https://api.github.com/repos/rafaelcs28/haval-ecotrip/releases?per_page=100"

    private fun toast(msg: String) = runOnUiThread {
        Toast.makeText(this, msg, Toast.LENGTH_LONG).show()
    }

    private fun installedVersion(): String =
        try { packageManager.getPackageInfo(packageName, 0).versionName ?: "0" } catch (_: Exception) { "0" }

    // compara "1.2" vs "1.10" numericamente (1.10 > 1.2)
    private fun isNewer(remote: String, local: String): Boolean {
        val r = remote.split(".").map { it.toIntOrNull() ?: 0 }
        val l = local.split(".").map { it.toIntOrNull() ?: 0 }
        for (i in 0 until maxOf(r.size, l.size)) {
            val a = r.getOrElse(i) { 0 }; val b = l.getOrElse(i) { 0 }
            if (a != b) return a > b
        }
        return false
    }

    private fun checkForUpdate() {
        toast("Verificando atualização…")
        Thread {
            try {
                val json = httpGet(GH_RELEASES)
                val arr = JSONArray(json)
                var bestVer: String? = null
                var bestUrl: String? = null
                for (i in 0 until arr.length()) {
                    val rel = arr.getJSONObject(i)
                    val tag = rel.optString("tag_name")               // ex: cluster-v1.1
                    if (!tag.startsWith("cluster-v")) continue
                    val ver = tag.removePrefix("cluster-v")
                    val assets = rel.optJSONArray("assets") ?: continue
                    var apk: String? = null
                    for (j in 0 until assets.length()) {
                        val a = assets.getJSONObject(j)
                        if (a.optString("name").endsWith(".apk")) { apk = a.optString("browser_download_url"); break }
                    }
                    if (apk == null) continue
                    if (bestVer == null || isNewer(ver, bestVer!!)) { bestVer = ver; bestUrl = apk }
                }
                if (bestVer == null || bestUrl == null) { toast("Nenhuma versão encontrada no GitHub."); return@Thread }
                val local = installedVersion()
                if (!isNewer(bestVer!!, local)) { toast("Já está na última versão ($local)."); return@Thread }
                toast("Baixando v$bestVer…")
                val apkFile = downloadApk(bestUrl!!)
                if (apkFile == null) { toast("Falha ao baixar a atualização."); return@Thread }
                runOnUiThread { promptInstall(apkFile) }
            } catch (e: Exception) {
                toast("Erro ao atualizar: ${e.message}")
            }
        }.start()
    }

    private fun httpGet(urlStr: String): String {
        val c = (URL(urlStr).openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 10000; readTimeout = 15000
            setRequestProperty("Accept", "application/vnd.github+json")
            setRequestProperty("User-Agent", "haval-cluster")
            instanceFollowRedirects = true
        }
        return c.inputStream.bufferedReader().use { it.readText() }
    }

    private fun downloadApk(urlStr: String): File? {
        return try {
            val c = (URL(urlStr).openConnection() as HttpURLConnection).apply {
                connectTimeout = 15000; readTimeout = 60000
                setRequestProperty("User-Agent", "haval-cluster")
                instanceFollowRedirects = true
            }
            val out = File(getExternalFilesDir(null), "update.apk")
            c.inputStream.use { input -> out.outputStream().use { input.copyTo(it) } }
            out
        } catch (_: Exception) { null }
    }

    private fun promptInstall(apk: File) {
        // Android O+: precisa da permissão "instalar apps desconhecidos" pra este app.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
            toast("Permita 'instalar apps desconhecidos' e toque em Atualizar de novo.")
            startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
            return
        }
        val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", apk)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) hideSystemBars()
    }

    private fun hideSystemBars() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.insetsController?.let {
                it.hide(android.view.WindowInsets.Type.systemBars())
                it.systemBarsBehavior =
                    android.view.WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        } else {
            @Suppress("DEPRECATION")
            web.systemUiVisibility = (
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                    or View.SYSTEM_UI_FLAG_FULLSCREEN
                    or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                    or View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                    or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                    or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION)
        }
    }

    override fun onDestroy() {
        stopLanDiscovery()
        web.destroy()
        super.onDestroy()
    }
}
