package br.com.redesurftank.ecotrip.managers

import android.content.Context
import android.content.pm.PackageManager
import rikka.shizuku.Shizuku

/**
 * Concede permissões runtime "dangerous" via Shizuku (nível adb) num head-unit
 * sem UI pra tocar nos diálogos do Android. Ex.: RECORD_AUDIO pra escuta ao vivo
 * — declarada no manifest mas nunca concedida (o app só pede localização em
 * runtime). Reaproveita o newProcess(reflexão) que o UpdateManager usa pro
 * install silencioso.
 */
object ShizukuPerms {
    private const val TAG = "ShizukuPerms"

    /** Garante [permission]. Se já concedida, no-op. Senão tenta `pm grant` via Shizuku. */
    fun ensureGranted(ctx: Context, permission: String): Boolean {
        if (ctx.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED) return true
        return try {
            if (!Shizuku.pingBinder()) {
                AppLogger.w(TAG, "Shizuku binder não vivo — não dá pra conceder $permission")
                return false
            }
            if (Shizuku.checkSelfPermission() != PackageManager.PERMISSION_GRANTED) {
                AppLogger.w(TAG, "Shizuku sem permissão — não dá pra conceder $permission")
                return false
            }
            // newProcess é private no Shizuku v13 — via reflexão (igual UpdateManager).
            val newProcess = Shizuku::class.java.getDeclaredMethod(
                "newProcess",
                Array<String>::class.java,
                Array<String>::class.java,
                String::class.java,
            ).also { it.isAccessible = true }
            val proc = newProcess.invoke(
                null,
                arrayOf("pm", "grant", ctx.packageName, permission),
                null as Array<String>?,
                null as String?,
            ) as Process
            val err  = proc.errorStream.bufferedReader().readText()
            val exit = proc.waitFor()
            val ok   = ctx.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
            AppLogger.i(TAG, "pm grant $permission exit=$exit ok=$ok err=${err.trim()}")
            ok
        } catch (e: Exception) {
            AppLogger.w(TAG, "ensureGranted($permission) exceção: ${e.message}")
            false
        }
    }
}
