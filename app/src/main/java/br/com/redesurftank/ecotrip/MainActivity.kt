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

        // Raiz = FrameLayout com o ComposeView + (por cima) o WebView overlay do
        // Controles, gerenciado por ControlesWebHost. O WebView fica FORA da
        // árvore de desenho do Compose (irmão do ComposeView) — senão renderiza
        // preto no WebView acelerado deste ROM (Android 9).
        val root = android.widget.FrameLayout(this)
        val compose = androidx.compose.ui.platform.ComposeView(this).apply {
            setContent { EcotripTheme { ConsumptionScreen() } }
        }
        root.addView(
            compose,
            android.widget.FrameLayout.LayoutParams(
                android.widget.FrameLayout.LayoutParams.MATCH_PARENT,
                android.widget.FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )
        br.com.redesurftank.ecotrip.ui.screens.HomeTeslaWebHost.attach(root)
        br.com.redesurftank.ecotrip.ui.screens.ControlesWebHost.attach(root)
        setContentView(root)

        // Iniciado pelo boot: envia o app para segundo plano se a pref BOOT_MINIMIZED
        // estiver ativa (default true). moveTaskToBack não destrói a Activity —
        // serviço foreground continua, o app abre ao tocar na barra de tarefas.
        if (intent?.getBooleanExtra("from_boot", false) == true) {
            val prefs = try { createDeviceProtectedStorageContext() } catch (_: Exception) { this }
                .getSharedPreferences(br.com.redesurftank.ecotrip.models.SharedPreferencesKeys.PREFS_NAME, android.content.Context.MODE_PRIVATE)
            if (prefs.getBoolean(br.com.redesurftank.ecotrip.models.SharedPreferencesKeys.BOOT_MINIMIZED, true)) {
                moveTaskToBack(true)
            }
        }

        // ── Player de mídia (tela Veículo): lê a sessão de mídia ativa e empurra
        // o estado pro WebView (window.applyMedia). Requer "Acesso a notificações". ──
        media = br.com.redesurftank.ecotrip.managers.MediaControllerHelper(applicationContext).also { h ->
            br.com.redesurftank.ecotrip.ui.screens.ControlesWebHost.media = h
            h.onChanged = { br.com.redesurftank.ecotrip.ui.screens.ControlesWebHost.feedMediaFromHelper() }
            val comp = br.com.redesurftank.ecotrip.managers.MediaControllerHelper.defaultListenerComponent(this)
            if (!br.com.redesurftank.ecotrip.managers.MediaControllerHelper.isNotificationAccessGranted(this, comp)) {
                br.com.redesurftank.ecotrip.managers.MediaControllerHelper.requestNotificationAccess(this)
            }
            h.start()
        }
    }

    private var media: br.com.redesurftank.ecotrip.managers.MediaControllerHelper? = null

    // ── Gesto de 2 dedos (global, não-consumido): na tela favorita, abre a
    // Controles. Quando a Controles está em foco, o próprio WebView trata o
    // swipe (e sai pelos limites via AppNav). ──
    private var twoActive = false
    private var twoDownX = 0f
    private var twoLastX = 0f
    override fun dispatchTouchEvent(ev: android.view.MotionEvent): Boolean {
        when (ev.actionMasked) {
            android.view.MotionEvent.ACTION_POINTER_DOWN -> if (ev.pointerCount == 2) {
                twoActive = true; twoDownX = (ev.getX(0) + ev.getX(1)) / 2f; twoLastX = twoDownX
            }
            android.view.MotionEvent.ACTION_MOVE -> if (twoActive && ev.pointerCount >= 2) {
                twoLastX = (ev.getX(0) + ev.getX(1)) / 2f
            }
            android.view.MotionEvent.ACTION_POINTER_UP,
            android.view.MotionEvent.ACTION_UP,
            android.view.MotionEvent.ACTION_CANCEL -> {
                if (twoActive) {
                    val dx = twoLastX - twoDownX
                    if (kotlin.math.abs(dx) > 80 &&
                        !br.com.redesurftank.ecotrip.ui.screens.ControlesWebHost.isShowing()) {
                        br.com.redesurftank.ecotrip.ui.screens.ControlesWebHost.requestEnter(if (dx < 0) 1 else -1)
                    }
                    twoActive = false
                }
            }
        }
        return super.dispatchTouchEvent(ev)
    }

    override fun onResume() {
        super.onResume()
        media?.start()   // re-tenta após o usuário conceder "acesso a notificações"
    }

    override fun onDestroy() {
        super.onDestroy()
        media?.stop()
        TripManager.getInstance().onSessionEnd()
        MqttManager.getInstance().destroy()
        CarDataManager.getInstance().destroy()
    }
}
