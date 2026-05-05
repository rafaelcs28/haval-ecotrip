package br.com.redesurftank.ecotrip.managers

import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.core.content.FileProvider
import br.com.redesurftank.ecotrip.BuildConfig
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors

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

        private val API_URL =
            "https://api.github.com/repos/${BuildConfig.GITHUB_REPO}/releases/latest"
    }

    private val executor = Executors.newSingleThreadExecutor()

    var latestRelease: ReleaseInfo? = null
        private set

    var isUpdateAvailable: Boolean = false
        private set

    var downloadProgress: Int = -1   // -1 = idle, 0-100 = downloading
        private set

    var onUpdateStateChanged: (() -> Unit)? = null

    /** Call once at app start to check for a new release in the background. */
    fun checkForUpdate() {
        executor.submit {
            try {
                val info = fetchLatestRelease() ?: return@submit
                latestRelease = info
                isUpdateAvailable = isNewer(info.version, BuildConfig.VERSION_NAME)
                if (isUpdateAvailable) {
                    AppLogger.i(TAG, "Update available: ${info.version} (current: ${BuildConfig.VERSION_NAME})")
                } else {
                    Log.d(TAG, "Already on latest version (${BuildConfig.VERSION_NAME})")
                }
                onUpdateStateChanged?.invoke()
            } catch (e: Exception) {
                Log.w(TAG, "Update check failed: ${e.message}")
            }
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
                AppLogger.i(TAG, "APK downloaded: ${apkFile.length()} bytes — launching installer")

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
        val json = JSONObject(body)
        val tag  = json.optString("tag_name") ?: return null
        val version = tag.trimStart('v')
        val notes   = json.optString("body", "")

        val assets = json.optJSONArray("assets")
        val apkUrl = (0 until (assets?.length() ?: 0))
            .mapNotNull { assets!!.optJSONObject(it) }
            .firstOrNull { it.optString("name").endsWith(".apk") }
            ?.optString("browser_download_url")
            ?: return null

        return ReleaseInfo(tag, version, apkUrl, notes)
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
