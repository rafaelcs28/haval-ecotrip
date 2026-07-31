package br.com.redesurftank.ecotrip.managers

import android.content.Context
import android.content.pm.PackageManager
import android.provider.Settings
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

    /// Concede ao PRÓPRIO app o "desenhar sobre outros apps", via Shizuku.
    ///
    /// Necessário porque SYSTEM_ALERT_WINDOW é APPOP, não permissão runtime — o
    /// `pm grant` acima não resolve. E o head unit do Haval não expõe a tela de
    /// Ajustes que concederia isso na mão (verificado em 31/07), então sem este
    /// caminho o botão flutuante seria impossível nesse hardware.
    ///
    /// Mesmo mecanismo que o app de referência do head unit já usa pra liberar a
    /// chain OUTPUT do iptables: Shizuku que o dono instalou e autorizou.
    ///
    /// Tenta os dois nomes do appop porque firmware antigo aceita só um deles;
    /// errar o nome apenas devolve "Unknown operation".
    fun concederOverlay(ctx: Context): Boolean {
        if (Settings.canDrawOverlays(ctx)) return true
        for (op in listOf("SYSTEM_ALERT_WINDOW", "android:system_alert_window")) {
            val out = runShell("appops", "set", ctx.packageName, op, "allow")
            AppLogger.i(TAG, "appops $op → ${out.trim().ifEmpty { "(sem saída)" }}")
            if (Settings.canDrawOverlays(ctx)) { AppLogger.i(TAG, "overlay liberado via $op"); return true }
        }
        // Em algumas builds o binário `appops` não existe e só `cmd appops` responde.
        val out2 = runShell("cmd", "appops", "set", ctx.packageName, "SYSTEM_ALERT_WINDOW", "allow")
        AppLogger.i(TAG, "cmd appops → ${out2.trim().ifEmpty { "(sem saída)" }}")
        val ok = Settings.canDrawOverlays(ctx)
        if (!ok) AppLogger.w(TAG, "não foi possível liberar o overlay por appops")
        return ok
    }

    /** Roda um comando shell como UID do Shizuku (adb). Retorna stdout+stderr (ou "error: ..."). */
    fun runShell(vararg cmd: String): String {
        return try {
            if (!Shizuku.pingBinder() || Shizuku.checkSelfPermission() != PackageManager.PERMISSION_GRANTED)
                return "error: shizuku indisponível"
            val newProcess = Shizuku::class.java.getDeclaredMethod(
                "newProcess",
                Array<String>::class.java,
                Array<String>::class.java,
                String::class.java,
            ).also { it.isAccessible = true }
            val proc = newProcess.invoke(null, arrayOf(*cmd), null as Array<String>?, null as String?) as Process
            val out = proc.inputStream.bufferedReader().readText()
            val err = proc.errorStream.bufferedReader().readText()
            proc.waitFor()
            (out + err).trim()
        } catch (e: Exception) {
            "error: ${e.message}"
        }
    }
}
