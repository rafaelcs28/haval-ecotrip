package br.com.redesurftank.ecotrip.receivers

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import br.com.redesurftank.ecotrip.MainActivity
import br.com.redesurftank.ecotrip.services.CarTelemetryService

private const val TAG = "BootReceiver"

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            "android.intent.action.QUICKBOOT_POWERON",
            "android.intent.action.LOCKED_BOOT_COMPLETED",
            Intent.ACTION_MY_PACKAGE_REPLACED -> {
                Log.i(TAG, "Boot/update received (${intent.action}) — launching Ecotrip")
                // Inicia o foreground service primeiro pra manter o processo vivo
                // mesmo se o sistema decidir não trazer a Activity pra frente.
                try { CarTelemetryService.start(context) } catch (e: Exception) {
                    Log.w(TAG, "Falha ao iniciar CarTelemetryService no boot: ${e.message}")
                }
                val launch = Intent(context, MainActivity::class.java).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                    putExtra("from_boot", true)
                }
                try { context.startActivity(launch) } catch (e: Exception) {
                    Log.w(TAG, "Falha ao lançar Activity: ${e.message}")
                }
            }
        }
    }
}
