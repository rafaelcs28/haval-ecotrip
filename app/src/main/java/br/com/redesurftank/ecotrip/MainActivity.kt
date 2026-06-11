package br.com.redesurftank.ecotrip

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import br.com.redesurftank.ecotrip.managers.BackupManager
import br.com.redesurftank.ecotrip.managers.CarDataManager
import br.com.redesurftank.ecotrip.managers.MqttManager
import br.com.redesurftank.ecotrip.managers.TripManager
import br.com.redesurftank.ecotrip.managers.UpdateManager
import br.com.redesurftank.ecotrip.services.CarTelemetryService
import br.com.redesurftank.ecotrip.ui.screens.AutoTripsScreen
import br.com.redesurftank.ecotrip.ui.screens.ChargeHistoryScreen
import br.com.redesurftank.ecotrip.ui.screens.ConsumptionScreen
import br.com.redesurftank.ecotrip.ui.screens.HomeClaudeLayout
import br.com.redesurftank.ecotrip.ui.screens.HomeData
import br.com.redesurftank.ecotrip.ui.screens.HomeEuropeanLayout
import br.com.redesurftank.ecotrip.ui.screens.HomeTeslaLayout
import br.com.redesurftank.ecotrip.ui.screens.InteractiveCar
import br.com.redesurftank.ecotrip.ui.theme.EcotripTheme

class MainActivity : ComponentActivity() {

    private val locationPermLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { grants ->
        val granted = grants[Manifest.permission.ACCESS_FINE_LOCATION] == true ||
                      grants[Manifest.permission.ACCESS_COARSE_LOCATION] == true
        if (granted) TripManager.getInstance().startGps()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Diagnóstico de tela: loga resolução física + insets de system bars do
        // head unit (rodar `adb logcat -s EcotripScreen`). Área útil = full - insets.
        window.decorView.post {
            val tag = "EcotripScreen"
            val dm = resources.displayMetrics
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
                val b = windowManager.currentWindowMetrics.bounds
                android.util.Log.i(tag, "full(currentWindowMetrics)=${b.width()}x${b.height()} density=${dm.density} dpi=${dm.densityDpi}")
            } else {
                val real = android.util.DisplayMetrics()
                @Suppress("DEPRECATION") windowManager.defaultDisplay.getRealMetrics(real)
                android.util.Log.i(tag, "full(realMetrics)=${real.widthPixels}x${real.heightPixels} density=${dm.density} dpi=${dm.densityDpi}")
            }
            val insets = androidx.core.view.ViewCompat.getRootWindowInsets(window.decorView)
            if (insets != null) {
                val sb = insets.getInsets(androidx.core.view.WindowInsetsCompat.Type.systemBars())
                val st = insets.getInsets(androidx.core.view.WindowInsetsCompat.Type.statusBars())
                val nv = insets.getInsets(androidx.core.view.WindowInsetsCompat.Type.navigationBars())
                android.util.Log.i(tag, "systemBars L=${sb.left} T=${sb.top} R=${sb.right} B=${sb.bottom}")
                android.util.Log.i(tag, "statusBar T=${st.top} B=${st.bottom} | navBar T=${nv.top} B=${nv.bottom} L=${nv.left} R=${nv.right}")
                android.util.Log.i(tag, "areaUtil=${window.decorView.width - sb.left - sb.right}x${window.decorView.height - sb.top - sb.bottom} (decor=${window.decorView.width}x${window.decorView.height})")
            } else {
                android.util.Log.i(tag, "rootWindowInsets=null (insets ainda não aplicados)")
            }
        }

        // Preview dos layouts da home no emulador (só debug): renderiza com dados
        // de exemplo e NÃO inicia managers/serviços. am start ... -e preview 0|1|2
        val preview = intent.getStringExtra("preview")?.toIntOrNull()
        if (BuildConfig.DEBUG && preview != null) {
            val d = HomeData.sample
            val now = System.currentTimeMillis()
            val sampleCharges = listOf(
                br.com.redesurftank.ecotrip.managers.ChargeHistoryEntry(now - 3_600_000L, 5400, 12.4f, 38f, 78f),
                br.com.redesurftank.ecotrip.managers.ChargeHistoryEntry(now - 2 * 86_400_000L, 7200, 18.9f, 20f, 90f),
                br.com.redesurftank.ecotrip.managers.ChargeHistoryEntry(now - 5 * 86_400_000L, 3600, 8.2f, 55f, 80f),
            )
            val sampleTrips = listOf(
                br.com.redesurftank.ecotrip.managers.AutoTripEntry(
                    startMs = now - 3_600_000L, endMs = now - 1_800_000L, startSocPct = 78f, endSocPct = 62f,
                    startFuelPct = 50f, endFuelPct = 50f, distKm = 23.4f, timeSec = 1800, energyKwh = 4.1f,
                    regenKwh = 0.8f, netKwh = 3.3f, fuelL = 0f, name = "Casa → Trabalho", maxSpeedKmh = 82f, outsideTempC = 27f,
                ),
                br.com.redesurftank.ecotrip.managers.AutoTripEntry(
                    startMs = now - 2 * 86_400_000L, endMs = now - 2 * 86_400_000L + 2_400_000L, startSocPct = 90f, endSocPct = 70f,
                    startFuelPct = 50f, endFuelPct = 48f, distKm = 41.2f, timeSec = 2400, energyKwh = 7.0f,
                    regenKwh = 1.5f, netKwh = 5.5f, fuelL = 0.6f, maxSpeedKmh = 98f, outsideTempC = 24f,
                ),
            )
            setContent {
                EcotripTheme {
                    when (preview) {
                        0 -> HomeTeslaLayout(d) { m -> InteractiveCar(d, m) }
                        1 -> HomeEuropeanLayout(d)
                        3 -> ChargeHistoryScreen(entries = sampleCharges, onClearHistory = {}, onBack = {})
                        4 -> AutoTripsScreen(entries = sampleTrips, onClear = {}, onBack = {})
                        else -> HomeClaudeLayout(d) { m -> InteractiveCar(d, m) }
                    }
                }
            }
            return
        }

        CarDataManager.getInstance().init(this)
        TripManager.getInstance().init(this)
        MqttManager.getInstance().init(this)
        BackupManager.getInstance().init(this)
        UpdateManager.getInstance().init(this)

        // Garante que o foreground service esteja rodando — Application.onCreate
        // já tenta iniciá-lo, mas em alguns cenários (ex.: relaunch via Intent
        // após o processo ter sido morto) é redundante chamar aqui.
        CarTelemetryService.start(this)

        // Localização para telemetria de auto-trips
        val hasFine = ContextCompat.checkSelfPermission(
            this, Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED
        if (hasFine) {
            TripManager.getInstance().startGps()
        } else {
            locationPermLauncher.launch(arrayOf(
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION,
            ))
        }

        setContent {
            EcotripTheme {
                ConsumptionScreen()
            }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        TripManager.getInstance().onSessionEnd()
        MqttManager.getInstance().destroy()
        CarDataManager.getInstance().destroy()
    }
}
