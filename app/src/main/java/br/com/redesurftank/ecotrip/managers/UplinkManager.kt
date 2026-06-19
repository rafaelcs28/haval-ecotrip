package br.com.redesurftank.ecotrip.managers

import android.content.pm.PackageManager
import android.util.Log

/**
 * Lê qual uplink de internet o head unit está roteando para o hotspot, a partir
 * do state file do HotRouter (tool havalshisuku, PR #90):
 *
 *   /data/local/tmp/hotrouter.state  →  "ESTADO|epoch"  (WLAN | 4G | OFF)
 *     WLAN = WLAN externa (Starlink) · 4G = 4G da OEM · OFF = HotRouter desligado.
 *
 * O arquivo é de posse do shell (0771 em /data/local/tmp); o EcoTrip lê via
 * Shizuku (mesmo uid shell) com `cat`. Throttle ~8s — o estado muda devagar.
 */
object UplinkManager {
    // "WLAN" (Starlink) · "4G" · "OFF" · "?" (sem leitura/desconhecido)
    @Volatile
    var latest: String = "?"
        private set

    private const val STATE_FILE = "/data/local/tmp/hotrouter.state"
    private var lastRead = 0L

    fun current(): String {
        maybeRefresh()
        return latest
    }

    private fun maybeRefresh() {
        val now = System.currentTimeMillis()
        if (now - lastRead < 8000) return
        lastRead = now
        try {
            if (!rikka.shizuku.Shizuku.pingBinder()) return
            if (rikka.shizuku.Shizuku.checkSelfPermission() != PackageManager.PERMISSION_GRANTED) return
            val newProcess = rikka.shizuku.Shizuku::class.java.getDeclaredMethod(
                "newProcess",
                Array<String>::class.java,
                Array<String>::class.java,
                String::class.java,
            ).also { it.isAccessible = true }
            val proc = newProcess.invoke(
                null, arrayOf("cat", STATE_FILE), null as Array<String>?, null as String?,
            ) as Process
            val out = proc.inputStream.bufferedReader().readText().trim()
            proc.waitFor()
            val st = out.substringBefore("|").trim().uppercase()
            latest = when (st) {
                "WLAN" -> "WLAN"
                "4G" -> "4G"
                "OFF" -> "OFF"
                else -> "?"
            }
        } catch (e: Exception) {
            Log.w("UplinkManager", "leitura falhou: ${e.message}")
        }
    }
}
