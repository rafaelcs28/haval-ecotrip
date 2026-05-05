package br.com.redesurftank.ecotrip

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import br.com.redesurftank.ecotrip.managers.CarDataManager
import br.com.redesurftank.ecotrip.managers.MqttManager
import br.com.redesurftank.ecotrip.managers.TripManager
import br.com.redesurftank.ecotrip.ui.screens.ConsumptionScreen
import br.com.redesurftank.ecotrip.ui.theme.EcotripTheme

class MainActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        CarDataManager.getInstance().init(this)
        TripManager.getInstance().init(this)
        MqttManager.getInstance().init(this)

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
