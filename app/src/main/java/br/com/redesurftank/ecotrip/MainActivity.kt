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
import br.com.redesurftank.ecotrip.ui.screens.ConsumptionScreen
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
