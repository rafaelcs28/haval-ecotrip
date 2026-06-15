package br.com.redesurftank.ecotrip.managers

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.util.Log
import androidx.core.content.FileProvider
import br.com.redesurftank.ecotrip.BuildConfig
import org.json.JSONObject
import rikka.shizuku.Shizuku
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

private const val TAG = "UpdateManager"

data class ReleaseInfo(
    val tagName: String,       // e.g. "v1.2"
    val version: String,       // e.g. "1.2"
    val apkUrl: String,
    val releaseNotes: String,
)

class UpdateManager private constructor() {

    companion object {
        @Volatile private var instance: UpdateManager? = null
        fun getInstance() = instance ?: synchronized(this) {
            instance ?: UpdateManager().also { instance = it }
        }

        // Lista de releases (NÃO /releases/latest): o "latest" do GitHub pega a
        // release mais recente de QUALQUER app (incl. o do tablet, tag cluster-vX.Y).
        // Filtramos só as tags do CARRO ("vX.Y") em fetchLatestRelease().
        private val API_URL =
            "https://api.github.com/repos/${BuildConfig.GITHUB_REPO}/releases?per_page=100"
    }

    private var appContext: Context? = null

    fun init(context: Context) {
        appContext = context.applicationContext
    }

    private val executor  = Executors.newSingleThreadExecutor()
    private val scheduler = Executors.newSingleThreadScheduledExecutor()
    private var periodicFuture: ScheduledFuture<*>? = null

    var latestRelease: ReleaseInfo? = null
        private set

    var isUpdateAvailable: Boolean = false
        private set

    var isChecking: Boolean = false
        private set

    var downloadProgress: Int = -1   // -1 = idle, 0-100 = downloading
        private set

    var onUpdateStateChanged: (() -> Unit)? = null

    /**
     * Inicia verificação periódica a cada [intervalMinutes] minutos.
     * O primeiro check imediato é feito pelo chamador (checkForUpdate()); aqui só agenda
     * os seguintes. Seguro chamar múltiplas vezes — cancela o agendamento anterior.
     */
    fun startPeriodicCheck(intervalMinutes: Long = 10) {
        periodicFuture?.cancel(false)
        periodicFuture = scheduler.scheduleAtFixedRate(
            { checkForUpdate() },
            intervalMinutes,   // delay inicial = 1 intervalo (não duplica o check do startup)
            intervalMinutes,
            TimeUnit.MINUTES,
        )
        Log.d(TAG, "Periodic update check scheduled every ${intervalMinutes}min")
    }

    /** Check for a new release in the background. Safe to call multiple times. */
    fun checkForUpdate() {
        if (isChecking || downloadProgress >= 0) return   // already in progress
        executor.submit {
            isChecking = true
            onUpdateStateChanged?.invoke()
            try {
                val info = fetchLatestRelease() ?: return@submit
                latestRelease = info
                isUpdateAvailable = isNewer(info.version, BuildConfig.VERSION_NAME)
                if (isUpdateAvailable) {
                    AppLogger.i(TAG, "Update available: ${info.version} (current: ${BuildConfig.VERSION_NAME}}) — iniciando download automático")
                    val ctx = appContext
                    if (ctx != null) {
                        downloadAndInstall(ctx)   // auto-download sem interação do usuário
                    }
                } else {
                    Log.d(TAG, "Already on latest version (${BuildConfig.VERSION_NAME})")
                }
            } catch (e: Exception) {
                Log.w(TAG, "Update check failed: ${e.message}")
            } finally {
                isChecking = false
                onUpdateStateChanged?.invoke()
            }
        }
    }

    /**
     * Força um check síncrono e retorna diagnóstico em texto (pra debug remoto via
     * cmd/check_update). Roda na thread do chamador — bloqueia até o fetch terminar.
     * Se houver versão nova, dispara o download/install (assíncrono) antes de retornar.
     */
    fun forceCheckDiag(): String {
        val current = BuildConfig.VERSION_NAME
        return try {
            val info = fetchLatestRelease()
                ?: return "current=$current latest=? — fetchLatestRelease retornou null (GitHub API falhou: rede/rate-limit)"
            latestRelease = info
            val newer = isNewer(info.version, current)
            isUpdateAvailable = newer
            onUpdateStateChanged?.invoke()
            if (newer) {
                val ctx = appContext
                if (ctx != null) {
                    if (downloadProgress >= 0) {
                        "current=$current latest=${info.version} NOVA — download já em andamento (${downloadProgress}%)"
                    } else {
                        downloadAndInstall(ctx)
                        "current=$current latest=${info.version} NOVA — download iniciado (apk=${info.apkUrl})"
                    }
                } else {
                    "current=$current latest=${info.version} NOVA — mas appContext null (init não rodou)"
                }
            } else {
                "current=$current latest=${info.version} — já na mais nova"
            }
        } catch (e: Exception) {
            "current=$current — erro: ${e::class.simpleName}: ${e.message}"
        }
    }

    /** Downloads the APK and triggers the system installer. */
    fun downloadAndInstall(context: Context) {
        val release = latestRelease ?: return
        if (downloadProgress >= 0) return   // already downloading
        executor.submit {
            try {
                downloadProgress = 0
                onUpdateStateChanged?.invoke()

                val cacheDir = File(context.cacheDir, "apk").also { it.mkdirs() }
                val apkFile  = File(cacheDir, "ecotrip-update.apk")

                val conn = URL(release.apkUrl).openConnection() as HttpURLConnection
                conn.connectTimeout = 30_000
                conn.readTimeout    = 60_000
                conn.connect()

                val total = conn.contentLength.toLong()
                var downloaded = 0L

                conn.inputStream.use { input ->
                    FileOutputStream(apkFile).use { output ->
                        val buf = ByteArray(8192)
                        var n: Int
                        while (input.read(buf).also { n = it } >= 0) {
                            output.write(buf, 0, n)
                            downloaded += n
                            if (total > 0) {
                                val pct = (downloaded * 100L / total).toInt()
                                if (pct != downloadProgress) {
                                    downloadProgress = pct
                                    onUpdateStateChanged?.invoke()
                                }
                            }
                        }
                    }
                }

                downloadProgress = 100
                onUpdateStateChanged?.invoke()
                AppLogger.i(TAG, "APK downloaded: ${apkFile.length()} bytes")

                // Verifica a versão REAL do APK baixado antes de instalar. A
                // browser_download_url do GitHub às vezes serve um APK velho em cache
                // (CDN stale): instalar mesmo assim repete download→install→versão não
                // muda→killProcess a cada 10min, um loop de reinstalação.
                val pkgInfo = context.packageManager.getPackageArchiveInfo(apkFile.absolutePath, 0)
                val apkVersion = pkgInfo?.versionName
                if (apkVersion == null) {
                    AppLogger.e(TAG, "APK baixado ilegível (getPackageArchiveInfo null) — abortando install")
                    return@submit
                }
                if (apkVersion != release.version) {
                    AppLogger.w(TAG, "APK baixado é v$apkVersion mas release esperava v${release.version} (CDN stale?) — abortando install p/ evitar loop")
                    return@submit
                }
                AppLogger.i(TAG, "APK v$apkVersion confere com a release — trying silent install")

                val silentOk = tryShizukuInstall(apkFile.absolutePath)
                if (silentOk) {
                    AppLogger.i(TAG, "Instalação silenciosa concluída — encerrando processo para iniciar nova versão")
                    Thread.sleep(300)
                    android.os.Process.killProcess(android.os.Process.myPid())
                    return@submit
                }

                // Shizuku indisponível ou falhou — fallback para instalador do sistema
                AppLogger.i(TAG, "Silent install não disponível — abrindo instalador do sistema")
                val uri = FileProvider.getUriForFile(
                    context,
                    "${context.packageName}.fileprovider",
                    apkFile,
                )
                val intent = Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, "application/vnd.android.package-archive")
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                context.startActivity(intent)
            } catch (e: Exception) {
                AppLogger.e(TAG, "Download/install failed: ${e.message}")
            } finally {
                downloadProgress = -1
                onUpdateStateChanged?.invoke()
            }
        }
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    /**
     * Tenta instalar [apkPath] silenciosamente usando o shell do Shizuku (adb-level).
     * Retorna true se o install teve sucesso (exit 0 + "Success" na saída).
     * Retorna false se Shizuku não está disponível, sem permissão, ou se o install falhou.
     *
     * Nota: Shizuku.newProcess() é private no v13 — invocamos via reflexão.
     */
    private fun tryShizukuInstall(apkPath: String): Boolean {
        return try {
            if (!Shizuku.pingBinder()) {
                Log.w(TAG, "Shizuku binder not alive — skipping silent install")
                return false
            }
            if (Shizuku.checkSelfPermission() != PackageManager.PERMISSION_GRANTED) {
                Log.w(TAG, "Shizuku permission not granted — skipping silent install")
                return false
            }
            // newProcess é private no Shizuku v13 API — acessamos via reflexão
            val newProcessMethod = Shizuku::class.java.getDeclaredMethod(
                "newProcess",
                Array<String>::class.java,
                Array<String>::class.java,
                String::class.java,
            ).also { it.isAccessible = true }

            val process = newProcessMethod.invoke(
                null,
                arrayOf("pm", "install", "-r", "-t", apkPath),
                null as Array<String>?,
                null as String?,
            ) as Process

            val output = process.inputStream.bufferedReader().readText()
            val errOut = process.errorStream.bufferedReader().readText()
            val exit   = process.waitFor()
            AppLogger.i(TAG, "pm install exit=$exit stdout=${output.trim()} stderr=${errOut.trim()}")
            exit == 0 && output.trim().startsWith("Success")
        } catch (e: Exception) {
            Log.w(TAG, "tryShizukuInstall exception: ${e.message}")
            false
        }
    }

    private fun fetchLatestRelease(): ReleaseInfo? {
        val conn = URL(API_URL).openConnection() as HttpURLConnection
        conn.connectTimeout = 10_000
        conn.readTimeout    = 10_000
        conn.setRequestProperty("Accept", "application/vnd.github+json")
        conn.setRequestProperty("User-Agent", "EcotripImpulse/${BuildConfig.VERSION_NAME}")
        if (conn.responseCode != 200) {
            Log.w(TAG, "GitHub API returned ${conn.responseCode}")
            return null
        }
        val body = conn.inputStream.bufferedReader().readText()
        val arr = org.json.JSONArray(body)
        // Considera SÓ releases do carro: tag "vX.Y". Ignora "cluster-vX.Y" (tablet)
        // e qualquer outra. Pega a de maior versão.
        val carTag = Regex("^v\\d")
        var best: ReleaseInfo? = null
        for (i in 0 until arr.length()) {
            val rel = arr.optJSONObject(i) ?: continue
            val tag = rel.optString("tag_name")
            if (!carTag.containsMatchIn(tag)) continue   // pula cluster-* e não-carro
            val version = tag.trimStart('v')
            val assets = rel.optJSONArray("assets")
            val apkUrl = (0 until (assets?.length() ?: 0))
                .mapNotNull { assets!!.optJSONObject(it) }
                .firstOrNull { it.optString("name").endsWith(".apk") }
                ?.optString("browser_download_url") ?: continue
            if (best == null || isNewer(version, best!!.version)) {
                best = ReleaseInfo(tag, version, apkUrl, rel.optString("body", ""))
            }
        }
        return best
    }

    /**
     * Returns true if [candidate] is strictly newer than [current].
     * Compares dot-separated integer segments, e.g. "1.2" > "1.1".
     */
    private fun isNewer(candidate: String, current: String): Boolean {
        val c = candidate.split(".").mapNotNull { it.toIntOrNull() }
        val b = current.split(".").mapNotNull   { it.toIntOrNull() }
        val len = maxOf(c.size, b.size)
        for (i in 0 until len) {
            val cv = c.getOrElse(i) { 0 }
            val bv = b.getOrElse(i) { 0 }
            if (cv > bv) return true
            if (cv < bv) return false
        }
        return false
    }
}
