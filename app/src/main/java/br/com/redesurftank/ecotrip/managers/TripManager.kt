package br.com.redesurftank.ecotrip.managers

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import br.com.redesurftank.ecotrip.models.CarConstants
import br.com.redesurftank.ecotrip.models.SharedPreferencesKeys
import com.google.gson.Gson
import com.google.gson.JsonParser
import com.google.gson.reflect.TypeToken
import kotlin.math.max

private const val TAG = "TripManager"
private const val THREE_HOURS_MS   = 3 * 3600_000L
private const val PENDING_POLL_MS  = 60_000L        // 1 min — intervalo de verificação de pendências

data class BlockSample(val kmStart: Float, val netKwhPer100km: Float, val fuelL: Float)

data class TripSnapshot(
    val fuelL: Float,
    val energyKwh: Float,
    val regenKwh: Float,
    val distKm: Float,
    val timeSec: Long,
    val blocks: List<BlockSample>,
    val startSocPct: Float = 0f,
    val currentSocPct: Float = 0f,
    val startTankL: Float = 0f,
    val currentTankL: Float = 0f,
    val priceGasolinePerL: Float = 0f,
    val priceEnergyPerKwh: Float = 0f,
) {
    val netKwh: Float get() = energyKwh - regenKwh
    val kmPerL: Float get() = if (fuelL > 0.001f) distKm / fuelL else 0f
    val kwhPer100km: Float get() = if (distKm > 0.1f) (netKwh / distKm) * 100f else 0f
    val avgSpeedKmh: Float get() = if (timeSec > 0L) distKm / (timeSec / 3600f) else 0f
    val costBrl: Float get() = fuelL * priceGasolinePerL + netKwh.coerceAtLeast(0f) * priceEnergyPerKwh
    val costPerKm: Float get() = if (distKm > 0.1f && costBrl > 0f) costBrl / distKm else 0f
    // km/L equivalente ECONÔMICO: converte kWh em "litros de gasolina equivalentes"
    // pela razão de custo (R$/kWh ÷ R$/L). Reflete a economia real do PHEV vs
    // ICE puro. Fallback pra equivalência energética (1 L = 8,9 kWh) só quando
    // os preços ainda não foram sincronizados do bridge.
    val combinedKmL: Float get() {
        if (distKm < 0.1f) return 0f
        val netPos = netKwh.coerceAtLeast(0f)
        val kwhAsL = if (priceGasolinePerL > 0f && priceEnergyPerKwh > 0f)
            netPos * priceEnergyPerKwh / priceGasolinePerL
        else
            netPos / 8.9f
        val totalFuelL = fuelL + kwhAsL
        return if (totalFuelL > 0.001f) distKm / totalFuelL else 0f
    }
}

data class TripHistoryEntry(
    val name: String = "",
    val label: String,
    val timestampMs: Long,
    val fuelL: Float,
    val energyKwh: Float,
    val regenKwh: Float,
    val distKm: Float,
    val timeSec: Long,
    val startSocPct: Float = 0f,
    val endSocPct: Float = 0f,
    val startTankL: Float = 0f,
    val endTankL: Float = 0f,
    val combinedKmL: Float = 0f,
    val costBrl: Float = 0f,        // custo total em R$ (calculado no momento do reset com preços vigentes)
) {
    val netKwh: Float get() = energyKwh - regenKwh
    val kmPerL: Float get() = if (fuelL > 0.001f) distKm / fuelL else 0f
    val kwhPer100km: Float get() = if (distKm > 0.1f) (netKwh / distKm) * 100f else 0f
    val avgSpeedKmh: Float get() = if (timeSec > 0L) distKm / (timeSec / 3600f) else 0f
    val costPerKm: Float get() = if (distKm > 0.1f && costBrl > 0f) costBrl / distKm else 0f
}

data class RollingSnapshot(
    val fuelL: Float,
    val energyKwh: Float,
    val regenKwh: Float,
    val windowKm: Float,
    val startSocPct: Float = 0f,
    val currentSocPct: Float = 0f,
    val startTankL: Float = 0f,
    val currentTankL: Float = 0f,
    val priceGasolinePerL: Float = 0f,
    val priceEnergyPerKwh: Float = 0f,
) {
    val netKwh: Float get() = energyKwh - regenKwh
    val netKwhPer100km: Float get() = if (windowKm > 0.1f) (netKwh / windowKm) * 100f else 0f
    val kmPerL: Float get() = if (fuelL > 0.001f) windowKm / fuelL else 0f
    val costBrl: Float get() = fuelL * priceGasolinePerL + netKwh.coerceAtLeast(0f) * priceEnergyPerKwh
    val costPerKm: Float get() = if (windowKm > 0.1f && costBrl > 0f) costBrl / windowKm else 0f
    // km/L equivalente ECONÔMICO: ver TripManager.combinedKmL pro mesmo princípio.
    val combinedKmL: Float get() {
        if (windowKm < 0.1f) return 0f
        val netPos = netKwh.coerceAtLeast(0f)
        val kwhAsL = if (priceGasolinePerL > 0f && priceEnergyPerKwh > 0f)
            netPos * priceEnergyPerKwh / priceGasolinePerL
        else
            netPos / 8.9f
        val totalFuelL = fuelL + kwhAsL
        return if (totalFuelL > 0.001f) windowKm / totalFuelL else 0f
    }
}

/**
 * Amostra da linha do tempo de uma sessão de recarga.
 * Gravada a cada ~30 s durante a recarga — usada para o gráfico de potência/energia na PWA.
 */
data class ChargeSample(
    val t:          Int,     // segundos desde o início da sessão
    val powerKw:    Float,   // potência de recarga em kW
    val sessionKwh: Float,   // energia acumulada na sessão (kWh)
    val socPct:     Float,   // SOC % do veículo neste instante
    val tempC:      Float?,  // temperatura externa em °C (null = sem leitura)
)

data class ChargeHistoryEntry(
    val timestampMs:  Long,
    val durationSec:  Long,
    val energyKwh:    Float,
    val startSocPct:  Float,
    val endSocPct:    Float,
    val avgTempC:     Float? = null,   // temperatura externa média durante a recarga
) {
    val avgPowerKw: Float get() = if (durationSec > 0) energyKwh / (durationSec / 3600f) else 0f
}

data class LifetimeSnapshot(
    val energyKwh: Float,
    val regenKwh:  Float,
    val netKwh:    Float,
    val distKm:    Float,
    val timeSec:   Long,
    val fuelL:     Float,
    val chargeKwh: Float,   // kWh injetados (lifetime de recargas)
    val chargeSec: Long,    // segundos conectado ao carregador
)

/**
 * Snapshot dos contadores lifetime salvo a cada transição P↔D/R.
 * Usado pela StatsScreen para calcular deltas por período.
 */
data class LifetimeCheckpoint(
    val timestampMs: Long,
    val energyKwh:   Float,
    val regenKwh:    Float,
    val distKm:      Float,
    val timeSec:     Long,
    val fuelL:       Float,
    val chargeKwh:   Float,
    val chargeSec:   Long,
)

/**
 * Viagem automática registrada entre duas transições P↔D/R.
 * Criada sem interação do usuário; lista separada dos trips manuais A/B.
 */
data class AutoTripEntry(
    val startMs:      Long,
    val endMs:        Long,
    val startSocPct:  Float,
    val endSocPct:    Float,
    val startFuelPct: Float,
    val endFuelPct:   Float,
    val distKm:       Float,
    val timeSec:      Long,
    val energyKwh:    Float,
    val regenKwh:     Float,
    val netKwh:       Float,
    val fuelL:        Float,
    val name:         String  = "",
    // campos adicionados em v2.54 — default Gson-safe para retrocompatibilidade
    val maxSpeedKmh:  Float   = 0f,
    val maxPowerPct:  Int     = 0,      // pico de potência do motor (%) durante a viagem
    val outsideTempC: Float?  = null,   // null = sem leitura disponível
    val startLat:     Double  = 0.0,
    val startLng:     Double  = 0.0,
    val endLat:       Double  = 0.0,
    val endLng:       Double  = 0.0,
    // v5.20 — tempo parado:
    //   parkedInPSec  = motor ligado em P (acumula durante toda a viagem)
    //   engineOffSec  = motor desligado entre resumes (só >0 em viagens continuadas)
    //   tempo total exibido = timeSec + parkedInPSec + engineOffSec
    val parkedInPSec: Long    = 0L,
    val engineOffSec: Long    = 0L,
)

/** Abastecimento auto-detectado pelo APK (pulo no fuel_l com carro parado).
 *  price_per_liter = 0 → o usuário preenche depois via PWA. Sync via MQTT
 *  retained pra sobreviver a falta de internet no momento do abastecimento. */
data class RefuelEntry(
    val timestampMs:    Long,
    val fuelLBefore:    Float,
    val fuelLAfter:     Float,
    val litersAdded:    Float,
    val odometerKm:     Float = 0f,
    val pricePerLiter:  Float = 0f,   // 0 = pendente, usuário preenche depois
)

typealias TripListener = (rolling: RollingSnapshot) -> Unit

class TripManager private constructor() {

    companion object {
        @Volatile private var instance: TripManager? = null
        fun getInstance() = instance ?: synchronized(this) {
            instance ?: TripManager().also { instance = it }
        }

        private const val DEFAULT_TANK_L    = 51f
        private const val FUEL_PCT_THRESHOLD = 1f
    }

    private lateinit var prefs: SharedPreferences
    private lateinit var appContext: android.content.Context
    private val samplesDir: java.io.File
        get() = java.io.File(appContext.filesDir, "autotrip_samples").also { it.mkdirs() }
    private val chargeSamplesDir: java.io.File
        get() = java.io.File(appContext.filesDir, "charge_samples").also { it.mkdirs() }
    private val listeners = mutableListOf<TripListener>()
    private val lock = Any()
    private val gson = Gson()

    // Polling periódico de pendências do bridge (rename / trip_finish) enquanto o app está ativo
    private val pendingPollHandler  = android.os.Handler(android.os.Looper.getMainLooper())
    private val pendingPollRunnable = object : Runnable {
        override fun run() {
            fetchAndApplyPendingRenames()                          // fire-and-forget; retorna rápido se fila vazia
            pendingPollHandler.postDelayed(this, PENDING_POLL_MS)  // reagenda independente de sessão ativa
        }
    }

    private var tankCapacityL     = DEFAULT_TANK_L
    private var maxHistoryEntries = 50
    private var priceGasolinePerL = 6.0f   // R$/L — default para gasolina no Brasil
    private var priceEnergyPerKwh = 0.9f   // R$/kWh — default tarifário residencial
    private val tripHistory       = mutableListOf<TripHistoryEntry>()

    // ── Lifetime — nunca zera ────────────────────────────────────────────────────
    private var lifeFuelL:     Float = 0f
    private var lifeEnergyKwh: Float = 0f
    private var lifeRegenKwh:  Float = 0f
    private var lifeDistKm:    Float = 0f
    private var lifeTimeSec:   Long  = 0L
    // Lifetime session baselines — track energy/regen/dist/time deltas within a session
    private var lifeSessStartEnergy: Float   = 0f
    private var lifeSessStartRegen:  Float   = 0f
    private var lifeSessStartDist:   Float   = 0f
    private var lifeSessStartMs:     Long    = 0L
    private var lifeSessDistReady:   Boolean = false
    private var lifeGearPauseStartMs: Long   = 0L
    private var lifeTotalPausedMs:    Long   = 0L
    private var lifeHwEnergy:        Float   = 0f
    private var lifeHwRegen:         Float   = 0f
    private var lifeHwDist:          Float   = 0f

    // Recarga — integração P×Δt (independente de sessão de condução)
    private var lifeChargeKwh:        Float   = 0f
    private var lifeChargeSec:        Long    = 0L
    // Checkpoints (para StatsScreen — um por transição P↔D/R e por driving_ready)
    private val checkpoints = mutableListOf<LifetimeCheckpoint>()
    // Auto-Trip tracking (driving_ready=1 inicia, driving_ready≠1 finaliza)
    private val autoTripHistory      = mutableListOf<AutoTripEntry>()
    /** startMs de trips já confirmados no bridge — impede re-envios desnecessários. */
    private val bridgeSyncedIds      = mutableSetOf<Long>()
    private var lastDrivingReadyState: Int = 0   // persiste para detectar reinício mid-trip
    private var minAutoTripDistKm:   Float = 0f  // filtro de distância mínima (display + save)
    /** Chamado na UI thread após cada trip automático salvo com sucesso. */
    var onAutoTripCompleted: ((AutoTripEntry) -> Unit)? = null
    var onChargeSessionCompleted: ((ChargeHistoryEntry) -> Unit)? = null
    var onRefuelDetected:         ((RefuelEntry) -> Unit)?        = null
    private var autoTripStartMs      = 0L
    private var autoTripStartSoc     = 0f
    private var autoTripStartFuel    = 0f
    private var autoTripStartEnergy  = 0f
    private var autoTripStartRegen   = 0f
    private var autoTripStartDist    = 0f
    private var autoTripStartFuelL   = 0f
    private var autoTripStartTime    = 0L
    // v5.20 — tempo parado
    private var autoTripStartPausedMs: Long = 0L  // snapshot de lifeTotalPausedMs no início
    private var autoTripEngineOffMs:   Long = 0L  // acumulador de gaps entre resumes (ms)
    // v5.26 — preserva a posição original quando há resume. O samples do trecho 1
    // pode ter sido deletado em disco pós-sync com o bridge — sem isso, endTrip
    // calcularia startLat com `firstOrNull` no telSamples só do trecho novo, e
    // perderia a referência da origem real (Casa, por exemplo).
    private var autoTripResumedStartLat: Double = 0.0
    private var autoTripResumedStartLng: Double = 0.0
    private var currentChargePowerKw: Float   = 0f
    private var isChargingNow:        Boolean = false
    private var chargeTickCount:      Int     = 0
    private var lastChargeTickMs:     Long    = 0L   // wall clock do último tick de carga
    // Sessão de recarga em andamento
    private var chargeSessionStartMs:   Long  = 0L
    private var chargeSessionStartSoc:  Float = 0f
    private var chargeSessionEnergyKwh: Float = 0f
    private var chargeSessionSec:       Long  = 0L
    private val chargeHistory = mutableListOf<ChargeHistoryEntry>()
    private val refuelHistory = mutableListOf<RefuelEntry>()
    // Temperatura externa durante a sessão de recarga
    private var chargeSessionTempSum:   Double = 0.0
    private var chargeSessionTempCount: Int    = 0
    // Linha do tempo da sessão de recarga (amostras a cada ~30 s)
    private val chargeSessionSamples = mutableListOf<ChargeSample>()

    // Rolling window "desde última partida"
    private var rollingAccFuel   = 0f
    private var rollingAccEnergy = 0f
    private var rollingAccRegen  = 0f
    private var rollingDistKm    = 0f
    private var lastShutdownMs   = 0L

    // Rolling baselines for energy/regen deltas. -1 = not yet established.
    private var prevRollingDist   = -1f
    private var prevRollingEnergy = -1f
    private var prevRollingRegen  = -1f

    // Current session raw values
    private var prevFuelPct  = -1f   // -1 = baseline not yet established
    private var pendingFuelL = 0f    // fuel consumed since last odometer tick (for chart)
    private var curEnergy    = 0f
    private var curRegen     = 0f
    private var curDist      = 0f
    private var sessionActive = false

    // Checkpoint counter — checkpointSession() is called every 5 ticks (~5s)
    private var checkpointTickCount = 0

    // Current gear — used to pause trip timer while in P
    var currentGear: String = ""
        private set

    // Latest SOC and fuel % readings (for start/current bookmarks)
    private var latestSocPct  = 0f
    private var latestFuelPct = 0f

    // ── Telemetria em tempo real ──────────────────────────────────────────────
    private var telemetryRecorder: TelemetryRecorder? = null
    private var latestSpeedKmh:     Float  = 0f
    private var latestEngineRpm:    Int    = 0
    private var latestBattPowerPct: Int    = 0  // % potência bateria (−100=regen, +100=consumo)
    private var latestOutsideTempC:    Float? = null  // null = sem leitura ainda
    private var autoTripMaxSpeed:      Float  = 0f    // máxima durante viagem em andamento
    private var autoTripMaxPowerPct:   Int    = 0     // pico de potência do motor (%) durante viagem

    // Rolling start bookmarks
    private var rollingStartSocPct:  Float   = 0f
    private var rollingStartTankL:   Float   = 0f
    private var rollingStartCaptured: Boolean = false

    fun getLifetimeSnapshot(): LifetimeSnapshot = synchronized(lock) {
        LifetimeSnapshot(
            energyKwh = lifeEnergyKwh,
            regenKwh  = lifeRegenKwh,
            netKwh    = (lifeEnergyKwh - lifeRegenKwh).coerceAtLeast(0f),
            distKm    = lifeDistKm,
            timeSec   = lifeTimeSec,
            fuelL     = lifeFuelL,
            chargeKwh = lifeChargeKwh,
            chargeSec = lifeChargeSec,
        )
    }

    /**
     * Chamado pelo ConsumptionScreen sempre que charging_state, battery_voltage ou
     * charge_current mudam. Atualiza a potência instantânea usada pela integração
     * de energia no tickTime(). Liga/desliga o acumulador via isChargingNow.
     */
    fun onChargingUpdate(isCharging: Boolean, powerKw: Float) {
        synchronized(lock) {
            val wasCharging = isChargingNow
            isChargingNow        = isCharging
            currentChargePowerKw = if (isCharging) maxOf(0f, powerKw) else 0f

            if (isCharging && !wasCharging) {
                if (chargeSessionEnergyKwh > 0f) {
                    // App reiniciou com o carro ainda carregando — retoma sessão persistida.
                    // chargeSessionStartSoc e chargeSessionStartMs já foram restaurados pelo loadFromPrefs.
                    AppLogger.i(TAG, "Recarga retomada após reinício — ${chargeSessionEnergyKwh}kWh acumulados, SOC original=${chargeSessionStartSoc}%")
                } else {
                    // Sessão genuinamente nova
                    chargeSessionStartMs   = System.currentTimeMillis()
                    chargeSessionStartSoc  = latestSocPct
                    chargeSessionEnergyKwh = 0f
                    chargeSessionSec       = 0L
                    chargeSessionTempSum   = 0.0
                    chargeSessionTempCount = 0
                    chargeSessionSamples.clear()
                    AppLogger.i(TAG, "Recarga iniciada — SOC=${latestSocPct}%")
                }
            } else if (!isCharging && wasCharging) {
                // Fim de recarga — salva sessão se suficientemente significativa
                if (chargeSessionSec >= 60L && chargeSessionEnergyKwh >= 0.05f) {
                    val avgTempC = if (chargeSessionTempCount > 0)
                        (chargeSessionTempSum / chargeSessionTempCount).toFloat()
                    else null
                    // Camada 2: fallback SOC delta. Se a integração P×t ficou
                    // muito atrás do que o SOC indica (ex app suspenso por
                    // horas), usa o cálculo via SOC. PACK_KWH ≈ 34, eficiência
                    // ~90% (perda interna pack DC). Pega o MAIOR dos dois.
                    val socDelta = (latestSocPct - chargeSessionStartSoc).coerceAtLeast(0f)
                    val energyFromSoc = (socDelta / 100f) * 34f * 0.92f
                    val finalEnergyKwh = maxOf(chargeSessionEnergyKwh, energyFromSoc)
                    if (energyFromSoc > chargeSessionEnergyKwh * 1.5f) {
                        AppLogger.w(TAG, "Energy via P×t (${chargeSessionEnergyKwh}kWh) muito menor que SOC delta (${energyFromSoc}kWh) — usando o maior (provável sleep do app)")
                    }
                    val entry = ChargeHistoryEntry(
                        timestampMs = System.currentTimeMillis(),
                        durationSec = chargeSessionSec,
                        energyKwh   = finalEnergyKwh,
                        startSocPct = chargeSessionStartSoc,
                        endSocPct   = latestSocPct,
                        avgTempC    = avgTempC,
                    )
                    chargeHistory.add(0, entry)
                    while (chargeHistory.size > 50) chargeHistory.removeAt(chargeHistory.lastIndex)
                    saveChargeHistory()
                    AppLogger.i(TAG, "Recarga concluída — ${chargeSessionEnergyKwh}kWh em ${chargeSessionSec}s SOC ${chargeSessionStartSoc}→${latestSocPct}% avgTemp=${avgTempC}°C samples=${chargeSessionSamples.size}")
                    onChargeSessionCompleted?.invoke(entry)

                    // Envia linha do tempo para o bridge (fire-and-forget)
                    val samplesSnapshot = chargeSessionSamples.toList()
                    val entryTs         = entry.timestampMs
                    if (samplesSnapshot.isNotEmpty() && ::appContext.isInitialized) {
                        val bridgeUrl = getBridgeHttpUrl()
                        if (bridgeUrl.isNotBlank()) {
                            try { java.io.File(chargeSamplesDir, "$entryTs.json").writeText(gson.toJson(samplesSnapshot)) } catch (_: Exception) {}
                            telemetryRecorder?.postChargeSamples(bridgeUrl, getBridgeToken(), entryTs, samplesSnapshot, avgTempC) {
                                try { java.io.File(chargeSamplesDir, "$entryTs.json").delete() } catch (_: Exception) {}
                            }
                        }
                    }
                }
                // Reset temp/sample tracking
                chargeSessionTempSum   = 0.0
                chargeSessionTempCount = 0
                chargeSessionSamples.clear()
                // Limpa sessão persistida — próxima carga começa do zero
                chargeSessionEnergyKwh = 0f
                chargeSessionSec       = 0L
                chargeSessionStartSoc  = 0f
                chargeSessionStartMs   = 0L
                if (::prefs.isInitialized) prefs.edit()
                    .putFloat(SharedPreferencesKeys.CHARGE_SESSION_ENERGY_KWH, 0f)
                    .putLong (SharedPreferencesKeys.CHARGE_SESSION_SEC,        0L)
                    .putFloat(SharedPreferencesKeys.CHARGE_SESSION_START_SOC,  0f)
                    .putLong (SharedPreferencesKeys.CHARGE_SESSION_START_MS,   0L)
                    .apply()
                // Persiste lifetime imediatamente (não espera próximo tick)
                saveToPrefs()
                AppLogger.i(TAG, "Estado de recarga off — chargeKwh=$lifeChargeKwh chargeSec=$lifeChargeSec")
            }
        }
    }

    fun getChargeHistory(): List<ChargeHistoryEntry> = synchronized(lock) { chargeHistory.toList() }
    fun getRefuelHistory(): List<RefuelEntry>        = synchronized(lock) { refuelHistory.toList() }

    /** Janela máxima (ms) entre fim de uma viagem e o engate da próxima pra permitir
     *  continuação. 60min cobre almoços e recargas curtas. */
    private val RESUME_WINDOW_MS = 60L * 60_000L

    /**
     * Retorna a última viagem se ela for elegível pra continuação:
     *  - Última viagem terminou há menos de RESUME_WINDOW_MS (60min)
     *  - Distância ≥ 0.5 km (filtra triviais)
     *  - Arquivo local de samples ainda existe (não foi sincronizada e limpa)
     *  - Se já houver viagem ativa, ela deve estar "fresca" (<5min, <1km) — banner
     *    aparece no início da nova viagem, oferecendo conversão em continuação.
     */
    fun getResumableLastTrip(): AutoTripEntry? = synchronized(lock) {
        val last = autoTripHistory.lastOrNull()
        if (last == null) {
            AppLogger.d(TAG, "getResumableLastTrip: histórico vazio")
            return@synchronized null
        }
        // Gap = intervalo entre o FIM da viagem anterior e o INÍCIO da próxima.
        // Se já há nova viagem em curso: gap = autoTripStartMs - last.endMs.
        // Se ainda não começou: gap = agora - last.endMs.
        val newTripStartOrNow = if (autoTripStartMs != 0L) autoTripStartMs else System.currentTimeMillis()
        val gapMs = newTripStartOrNow - last.endMs
        if (gapMs < 0 || gapMs > RESUME_WINDOW_MS) {
            AppLogger.d(TAG, "getResumableLastTrip: gap fora da janela (${gapMs/60_000}min, máx=${RESUME_WINDOW_MS/60_000}min)")
            return@synchronized null
        }
        if (last.distKm < 0.1f) {
            AppLogger.d(TAG, "getResumableLastTrip: última viagem trivial (${"%.2f".format(last.distKm)}km)")
            return@synchronized null
        }
        // Samples file é OPCIONAL — se sumiu (já enviado pro bridge e limpo), aceita
        // mesmo assim. resumeLastTrip() trata file-not-found ok (samples vazios →
        // GPS terá gap no período entre as paradas, mas a viagem em si é restaurada).
        AppLogger.i(TAG, "getResumableLastTrip: elegível — viagem ${last.startMs} (${"%.1f".format(last.distKm)}km, gap=${gapMs/60_000}min)")
        last
    }

    /**
     * Restaura a última viagem como ativa. Os baselines voltam pros valores
     * originais (subtraindo o acumulado da viagem dos contadores lifetime),
     * o gap de motor desligado é somado em autoTripEngineOffMs, e os samples
     * antigos são pré-carregados no recorder pra serem concatenados aos novos.
     * Quando a viagem (agora estendida) terminar, ela é salva com o mesmo
     * startMs original — o bridge faz UPSERT, sem duplicação.
     */
    fun resumeLastTrip(): Boolean {
        val last = getResumableLastTrip() ?: return false
        synchronized(lock) {
            // Pop do histórico — a viagem volta a ser "em andamento"
            autoTripHistory.removeAll { it.startMs == last.startMs }
            // Remove de bridgeSyncedIds: se a viagem foi sincronizada antes (caso
            // típico — sync rodou após o primeiro trecho), o filtro
            // syncAutoTripsTobridge ignoraria a versão estendida (mesmo startMs).
            // Forçar re-sync garante que o bridge receba a viagem combinada.
            if (bridgeSyncedIds.remove(last.startMs)) {
                persistSyncedIds()
                AppLogger.i(TAG, "Viagem ${last.startMs} removida de bridgeSyncedIds — será re-sincronizada ao fim")
            }

            // Restaura baselines: o ponto inicial da viagem (em lifeXxx) era
            // (lifeAtualNoFimDaViagem - acumuladoNaViagem). Mas lifeAtual pode
            // ter mudado pouco entre o fim da viagem e agora (motor off → poucos
            // updates). Reverte usando os valores atuais menos os totais da viagem.
            autoTripStartMs     = last.startMs
            autoTripStartSoc    = last.startSocPct
            autoTripStartFuel   = last.startFuelPct
            autoTripStartDist   = lifeDistKm   - last.distKm
            autoTripStartTime   = lifeTimeSec  - last.timeSec
            autoTripStartEnergy = lifeEnergyKwh - last.energyKwh
            autoTripStartRegen  = lifeRegenKwh  - last.regenKwh
            autoTripStartFuelL  = lifeFuelL    - last.fuelL
            autoTripMaxSpeed    = last.maxSpeedKmh
            autoTripMaxPowerPct = last.maxPowerPct
            // Preserva a posição original da viagem — endTrip vai usar isso em
            // vez de recalcular a partir do telSamples (que perdeu o trecho 1
            // se o arquivo de samples foi deletado pós-sync).
            autoTripResumedStartLat = last.startLat
            autoTripResumedStartLng = last.startLng

            // Soma o gap atual (motor off) ao acumulador. Preserva engineOffSec
            // anterior caso esta viagem já tenha sido continuada antes.
            val gapMs = (System.currentTimeMillis() - last.endMs).coerceAtLeast(0L)
            autoTripEngineOffMs = (last.engineOffSec * 1000L) + gapMs

            // Reseta autoTripStartPausedMs pro snapshot atual menos o parkedInPSec
            // da viagem original — mantém continuidade do contador de P-time.
            val now = System.currentTimeMillis()
            val curPausedMs = lifeTotalPausedMs + (if (lifeGearPauseStartMs > 0L) now - lifeGearPauseStartMs else 0L)
            autoTripStartPausedMs = curPausedMs - (last.parkedInPSec * 1000L)

            // Recarrega samples antigos no recorder pra concatenar com novos
            val samplesFile = java.io.File(samplesDir, "${last.startMs}.json")
            val preloaded = try {
                if (samplesFile.exists()) {
                    val type = object : TypeToken<List<TelemetrySample>>() {}.type
                    gson.fromJson<List<TelemetrySample>>(samplesFile.readText(), type) ?: emptyList()
                } else emptyList()
            } catch (_: Exception) { emptyList() }
            val inProgressFile = java.io.File(samplesDir, "${autoTripStartMs}_inprogress.json")
            telemetryRecorder?.startRecording(autoTripStartMs, preloaded, inProgressFile)

            // Re-publica histórico atualizado (a viagem some) e baselines
            prefs.edit()
                .putString(SharedPreferencesKeys.AUTO_TRIP_HISTORY_JSON, gson.toJson(autoTripHistory))
                .putLong  (SharedPreferencesKeys.AUTO_TRIP_START_MS,       autoTripStartMs)
                .putFloat (SharedPreferencesKeys.AUTO_TRIP_START_SOC,      autoTripStartSoc)
                .putFloat (SharedPreferencesKeys.AUTO_TRIP_START_FUEL,     autoTripStartFuel)
                .putFloat (SharedPreferencesKeys.AUTO_TRIP_START_ENERGY,   autoTripStartEnergy)
                .putFloat (SharedPreferencesKeys.AUTO_TRIP_START_REGEN,    autoTripStartRegen)
                .putFloat (SharedPreferencesKeys.AUTO_TRIP_START_DIST,     autoTripStartDist)
                .putFloat (SharedPreferencesKeys.AUTO_TRIP_START_FUEL_L,   autoTripStartFuelL)
                .putLong  (SharedPreferencesKeys.AUTO_TRIP_START_TIME_SEC, autoTripStartTime)
                .putFloat (SharedPreferencesKeys.AUTO_TRIP_MAX_SPEED,      autoTripMaxSpeed)
                .putLong  (SharedPreferencesKeys.AUTO_TRIP_START_PAUSED_MS,autoTripStartPausedMs)
                .putLong  (SharedPreferencesKeys.AUTO_TRIP_ENGINE_OFF_MS,  autoTripEngineOffMs)
                .putFloat (SharedPreferencesKeys.AUTO_TRIP_RESUMED_START_LAT, autoTripResumedStartLat.toFloat())
                .putFloat (SharedPreferencesKeys.AUTO_TRIP_RESUMED_START_LNG, autoTripResumedStartLng.toFloat())
                .apply()
        }
        AppLogger.i(TAG, "Viagem ${last.startMs} retomada — gap=${(System.currentTimeMillis() - last.endMs) / 60000}min · start preservado=(${autoTripResumedStartLat},${autoTripResumedStartLng})")
        return true
    }

    /** Para MqttManager: energia injetada na sessão de recarga corrente. */
    fun getChargeSessionEnergyKwh(): Float = synchronized(lock) { chargeSessionEnergyKwh }

    fun clearChargeHistory() {
        synchronized(lock) {
            chargeHistory.clear()
            if (::prefs.isInitialized) prefs.edit().remove(SharedPreferencesKeys.CHARGE_HISTORY_JSON).apply()
        }
    }

    /** Para MqttManager: última posição GPS conhecida do veículo. */
    fun getLastGps(): Pair<Double, Double> =
        Pair(telemetryRecorder?.latestLat ?: 0.0, telemetryRecorder?.latestLng ?: 0.0)

    /** Para StatsScreen: baseline de período (último checkpoint ≤ startMs). */
    fun getLifetimeBaselineAt(startMs: Long): LifetimeCheckpoint? = synchronized(lock) {
        checkpoints.filter { it.timestampMs <= startMs }.maxByOrNull { it.timestampMs }
    }

    /** Para AutoTripsScreen: lista de viagens automáticas (mais recentes primeiro). */
    fun getAutoTripHistory(): List<AutoTripEntry> = synchronized(lock) {
        autoTripHistory.reversed()
    }

    /**
     * Para AutoTripsScreen: snapshot ao vivo da viagem em andamento.
     * Retorna null quando o carro está parado (autoTripStartMs == 0).
     */
    fun getInProgressAutoTrip(): AutoTripEntry? = synchronized(lock) {
        if (autoTripStartMs == 0L) return@synchronized null
        val now    = System.currentTimeMillis()
        val energy = (lifeEnergyKwh - autoTripStartEnergy).coerceAtLeast(0f)
        val regen  = (lifeRegenKwh  - autoTripStartRegen ).coerceAtLeast(0f)
        // Tempo em P durante a viagem = pause acumulado atual − snapshot do início.
        // Inclui o intervalo em andamento se ainda em P (lifeGearPauseStartMs > 0).
        val curPausedMs = lifeTotalPausedMs + (if (lifeGearPauseStartMs > 0L) now - lifeGearPauseStartMs else 0L)
        val parkedInPMs = (curPausedMs - autoTripStartPausedMs).coerceAtLeast(0L)
        AutoTripEntry(
            startMs      = autoTripStartMs,
            endMs        = now,
            startSocPct  = autoTripStartSoc,
            endSocPct    = latestSocPct,
            startFuelPct = autoTripStartFuel,
            endFuelPct   = latestFuelPct,
            distKm       = (lifeDistKm  - autoTripStartDist  ).coerceAtLeast(0f),
            timeSec      = (lifeTimeSec - autoTripStartTime  ).coerceAtLeast(0L),
            energyKwh    = energy,
            regenKwh     = regen,
            netKwh       = (energy - regen).coerceAtLeast(0f),
            fuelL        = (lifeFuelL   - autoTripStartFuelL ).coerceAtLeast(0f),
            maxSpeedKmh  = autoTripMaxSpeed,
            maxPowerPct  = autoTripMaxPowerPct,
            outsideTempC = latestOutsideTempC,
            parkedInPSec = parkedInPMs / 1000L,
            engineOffSec = autoTripEngineOffMs / 1000L,
        )
    }

    /** Persiste o set de IDs sincronizados nas SharedPreferences (thread-safe). */
    private fun persistSyncedIds() {
        if (!::prefs.isInitialized) return
        val snapshot = synchronized(lock) { bridgeSyncedIds.toList() }
        prefs.edit()
            .putString(SharedPreferencesKeys.BRIDGE_SYNCED_TRIP_IDS, gson.toJson(snapshot))
            .apply()
    }

    /**
     * Sincroniza apenas as viagens ainda não confirmadas com o bridge (iPhone PWA).
     * Chamado ao abrir a aba de viagens automáticas ou ao tocar no botão de sync.
     * [forceAll] = true limpa o set de já-sincronizados e reenvia tudo (botão manual).
     * [onResult] chamado na Main thread com o número de trips enviadas com sucesso,
     *   ou -1 se a URL não estiver configurada.
     */
    fun syncAutoTripsTobridge(
        forceAll: Boolean = false,
        onResult: ((Int) -> Unit)? = null,
    ) {
        val bridgeUrl = getBridgeHttpUrl()
        if (bridgeUrl.isBlank()) {
            AppLogger.w(TAG, "syncAutoTripsTobridge: Bridge URL não configurado")
            android.os.Handler(android.os.Looper.getMainLooper()).post { onResult?.invoke(-1) }
            return
        }
        if (forceAll) {
            synchronized(lock) { bridgeSyncedIds.clear() }
            AppLogger.i(TAG, "syncAutoTripsTobridge: forceAll — IDs limpos, reenviando tudo")
        }
        val historySize: Int
        val unsynced = synchronized(lock) {
            historySize = autoTripHistory.size
            autoTripHistory
                .filter { it.startMs !in bridgeSyncedIds }
                .map    { entry -> entry.startMs.toString() to gson.toJson(entry) }
        }
        if (historySize == 0) {
            AppLogger.i(TAG, "syncAutoTripsTobridge: autoTripHistory vazio — nenhuma viagem gravada ainda")
            android.os.Handler(android.os.Looper.getMainLooper()).post { onResult?.invoke(-2) }
            return
        }
        if (unsynced.isEmpty()) {
            AppLogger.i(TAG, "syncAutoTripsTobridge: todas as ${historySize} trips já sincronizadas com $bridgeUrl")
            android.os.Handler(android.os.Looper.getMainLooper()).post { onResult?.invoke(0) }
            return
        }
        AppLogger.i(TAG, "syncAutoTripsTobridge: enviando ${unsynced.size} trips para $bridgeUrl")
        telemetryRecorder?.bulkPostTrips(
            bridgeUrl   = bridgeUrl,
            bridgeToken = getBridgeToken(),
            trips       = unsynced,
            onAllDone = { ok, fail ->
                // -3 = todas as tentativas falharam (rede indisponível ou URL errada)
                val result = when {
                    ok > 0   -> ok   // pelo menos 1 enviada com sucesso
                    fail > 0 -> -3   // tentou mas todas falharam
                    else     -> 0    // nada para enviar
                }
                AppLogger.i(TAG, "syncAutoTripsTobridge: ok=$ok fail=$fail → result=$result")
                onResult?.invoke(result)
            },
            samplesProvider = { tripIdStr ->
                // Inclui amostras salvas em disco, se disponíveis
                try {
                    val f = java.io.File(samplesDir, "$tripIdStr.json")
                    if (f.exists()) f.readText() else "[]"
                } catch (_: Exception) { "[]" }
            },
        ) { tripIdStr ->
            val ms = tripIdStr.toLongOrNull() ?: return@bulkPostTrips
            synchronized(lock) { bridgeSyncedIds.add(ms) }
            persistSyncedIds()
            // NÃO apaga samples aqui — preserva pra preload em caso de resume
            // (janela de 60min). Cleanup acontece no boot via cleanOldSamples().
        }
    }

    /** Para AutoTripsScreen: limpar histórico de viagens automáticas e reset do controle de sync. */
    fun clearAutoTripHistory() {
        synchronized(lock) {
            autoTripHistory.clear()
            bridgeSyncedIds.clear()
        }
        if (::prefs.isInitialized) prefs.edit()
            .putString(SharedPreferencesKeys.AUTO_TRIP_HISTORY_JSON, "[]")
            .putString(SharedPreferencesKeys.BRIDGE_SYNCED_TRIP_IDS, "[]")
            .apply()
        // Apaga todos os arquivos de amostras salvas em disco
        try { samplesDir.listFiles()?.forEach { it.delete() } } catch (_: Exception) {}
    }

    /** Zera todos os contadores lifetime e limpa os checkpoints de stats. */
    fun resetLifetime() {
        synchronized(lock) {
            lifeFuelL     = 0f
            lifeEnergyKwh = 0f
            lifeRegenKwh  = 0f
            lifeDistKm    = 0f
            lifeTimeSec   = 0L
            lifeChargeKwh = 0f
            lifeChargeSec = 0L
            checkpoints.clear()
            // Também zera a sessão de recarga em andamento
            chargeSessionEnergyKwh = 0f
            chargeSessionSec       = 0L
            chargeSessionStartSoc  = 0f
            chargeSessionStartMs   = 0L
        }
        if (::prefs.isInitialized) prefs.edit()
            .putFloat (SharedPreferencesKeys.LIFETIME_FUEL_L,             0f)
            .putFloat (SharedPreferencesKeys.LIFETIME_ENERGY_KWH,         0f)
            .putFloat (SharedPreferencesKeys.LIFETIME_REGEN_KWH,          0f)
            .putFloat (SharedPreferencesKeys.LIFETIME_DISTANCE_KM,        0f)
            .putLong  (SharedPreferencesKeys.LIFETIME_TIME_SEC,           0L)
            .putFloat (SharedPreferencesKeys.LIFETIME_CHARGE_KWH,         0f)
            .putLong  (SharedPreferencesKeys.LIFETIME_CHARGE_SEC,         0L)
            .putString(SharedPreferencesKeys.LIFETIME_CHECKPOINTS_JSON, "[]")
            .putFloat (SharedPreferencesKeys.CHARGE_SESSION_ENERGY_KWH,  0f)
            .putLong  (SharedPreferencesKeys.CHARGE_SESSION_SEC,         0L)
            .putFloat (SharedPreferencesKeys.CHARGE_SESSION_START_SOC,   0f)
            .putLong  (SharedPreferencesKeys.CHARGE_SESSION_START_MS,    0L)
            .apply()
        AppLogger.i(TAG, "Lifetime resetado pelo usuário.")
    }

    /**
     * Busca nomes pendentes no bridge e aplica localmente.
     * Chamada automaticamente ao iniciar a sessão (WiFi com bridge acessível).
     * Fire-and-forget: falhas são apenas logadas, sem retry imediato.
     */
    fun fetchAndApplyPendingRenames() {
        val bridgeUrl = getBridgeHttpUrl()
        if (bridgeUrl.isBlank()) return
        telemetryRecorder?.fetchPendingRenames(bridgeUrl, getBridgeToken()) { tasks ->
            if (tasks.isEmpty()) return@fetchPendingRenames
            val appliedIds = mutableListOf<String>()
            for (task in tasks) {
                try {
                    when (task.type) {
                        "auto" -> {
                            val startMs = task.tripId.toLongOrNull() ?: continue
                            renameAutoTripEntry(startMs, task.name)
                            appliedIds.add(task.id)
                            AppLogger.i(TAG, "Rename auto-trip ${task.tripId} → '${task.name}'")
                        }
                        "manual" -> {
                            val tsMs = task.tripId.toLongOrNull() ?: continue
                            renameTripHistoryEntry(tsMs, task.name)
                            appliedIds.add(task.id)
                            AppLogger.i(TAG, "Rename manual trip ${task.tripId} → '${task.name}'")
                        }
                    }
                } catch (_: Exception) {}
            }
            if (appliedIds.isNotEmpty()) {
                telemetryRecorder?.ackRenames(getBridgeHttpUrl(), getBridgeToken(), appliedIds)
            }
        }
    }

    /** Renomeia uma viagem automática identificada pelo startMs. */
    fun renameAutoTripEntry(startMs: Long, name: String) {
        synchronized(lock) {
            val idx = autoTripHistory.indexOfFirst { it.startMs == startMs }
            if (idx < 0) return
            autoTripHistory[idx] = autoTripHistory[idx].copy(name = name.trim())
            if (::prefs.isInitialized)
                prefs.edit().putString(SharedPreferencesKeys.AUTO_TRIP_HISTORY_JSON, gson.toJson(autoTripHistory)).apply()
        }
    }

    fun getMinAutoTripDist(): Float = synchronized(lock) { minAutoTripDistKm }
    fun setMinAutoTripDist(km: Float) {
        synchronized(lock) { minAutoTripDistKm = km.coerceAtLeast(0f) }
        if (::prefs.isInitialized)
            prefs.edit().putFloat(SharedPreferencesKeys.MIN_AUTO_TRIP_DIST_KM, km.coerceAtLeast(0f)).apply()
    }

    /** Para StatsScreen: preços de combustível e energia. */
    fun getPrices(): Pair<Float, Float> = synchronized(lock) {
        Pair(priceGasolinePerL, priceEnergyPerKwh)
    }

    fun init(context: Context) {
        val ctx = try {
            context.createDeviceProtectedStorageContext()
        } catch (e: Exception) {
            context
        }
        appContext = ctx
        prefs = ctx.getSharedPreferences(SharedPreferencesKeys.PREFS_NAME, Context.MODE_PRIVATE)
        loadFromPrefs()

        // Retenção ao iniciar: remove viagens >90 dias e arquivos de amostras >7 dias
        val cutoff90d = System.currentTimeMillis() - 90L * 24 * 3_600_000L
        val cutoff7d  = System.currentTimeMillis() -  7L * 24 * 3_600_000L
        synchronized(lock) {
            val before = autoTripHistory.size
            autoTripHistory.removeAll { it.endMs < cutoff90d }
            if (autoTripHistory.size < before) {
                prefs.edit().putString(SharedPreferencesKeys.AUTO_TRIP_HISTORY_JSON, gson.toJson(autoTripHistory)).apply()
                AppLogger.i(TAG, "Retenção: ${before - autoTripHistory.size} viagem(ns) >90 dias removida(s)")
            }
        }
        try {
            samplesDir.listFiles()?.forEach { f ->
                val ts = (if (f.name.endsWith("_inprogress.json"))
                    f.name.removeSuffix("_inprogress.json")
                else f.nameWithoutExtension).toLongOrNull() ?: return@forEach
                if (ts < cutoff7d) { f.delete(); AppLogger.i(TAG, "Amostras expiradas apagadas: ${f.name}") }
            }
        } catch (_: Exception) {}

        // Bootstrap: garante pelo menos 1 checkpoint para StatsScreen funcionar imediatamente
        synchronized(lock) {
            if (checkpoints.isEmpty()) saveGearTransitionCheckpoint()
        }
        // Inicializa recorder de telemetria (GPS ativado depois via startGps())
        telemetryRecorder = TelemetryRecorder(ctx)

        // Se havia um auto-trip em andamento antes do reinício, retoma a gravação.
        // Carrega as amostras já gravadas em disco (flush a cada 60 s) para preservar a rota.
        // Arquivos _inprogress de outras sessões (orphans) são apagados.
        if (autoTripStartMs > 0L) {
            // Sempre passa flushFile válido — mesmo se o arquivo _inprogress sumiu,
            // o recorder começa a persistir do zero pra não perder os próximos samples.
            val inProgressFile = java.io.File(samplesDir, "${autoTripStartMs}_inprogress.json")
            val preloaded: List<TelemetrySample> = if (inProgressFile.exists()) {
                try {
                    val type = object : TypeToken<List<TelemetrySample>>() {}.type
                    gson.fromJson<List<TelemetrySample>>(inProgressFile.readText(), type) ?: emptyList()
                } catch (_: Exception) { emptyList() }
            } else emptyList()
            telemetryRecorder?.startRecording(autoTripStartMs, preloaded, inProgressFile)
            AppLogger.i(TAG, "AutoTrip retomado após reinício: ${preloaded.size} amostras carregadas do disco (inProgressExistia=${inProgressFile.exists()})")
        }
        // Limpa arquivos _inprogress órfãos (sessões anteriores abandonadas)
        try {
            samplesDir.listFiles { f -> f.name.endsWith("_inprogress.json") }?.forEach { f ->
                val ts = f.name.removeSuffix("_inprogress.json").toLongOrNull() ?: run { f.delete(); return@forEach }
                if (ts != autoTripStartMs) f.delete()
            }
        } catch (_: Exception) {}

        // Limpa samples de viagens já sincronizadas E mais antigas que a janela de
        // resume (60min) + folga de 30min. Mantém samples recentes pra permitir
        // preload em caso de resume. Não toca _inprogress (gerenciado acima).
        try {
            val ageCutoffMs = 90L * 60_000L  // 90min
            val now = System.currentTimeMillis()
            samplesDir.listFiles { f -> f.name.matches(Regex("^\\d+\\.json$")) }?.forEach { f ->
                val ts = f.name.removeSuffix(".json").toLongOrNull() ?: return@forEach
                if (ts == autoTripStartMs) return@forEach   // viagem em andamento — preserva
                val ageMs = now - f.lastModified()
                if (ageMs > ageCutoffMs && bridgeSyncedIds.contains(ts)) f.delete()
            }
        } catch (_: Exception) {}

        // Sincroniza trips pendentes ao iniciar — silencioso, sem forceAll
        syncAutoTripsTobridge(forceAll = false)
        // Aplica renames feitos no iPhone (fila do bridge) — fire-and-forget
        fetchAndApplyPendingRenames()
        // Inicia polling periódico: verifica pendências a cada 60s enquanto o app estiver ativo
        pendingPollHandler.postDelayed(pendingPollRunnable, PENDING_POLL_MS)
    }

    /** Inicia GPS para telemetria. Chame após permissão concedida. */
    fun startGps() {
        telemetryRecorder?.startGps()
    }

    fun addListener(l: TripListener)    = synchronized(lock) { listeners.add(l) }
    fun removeListener(l: TripListener) = synchronized(lock) { listeners.remove(l) }

    /** Para MqttManager.markChanged(): snapshot instantâneo sem acionar listeners. */
    fun currentRolling():    RollingSnapshot = synchronized(lock) { rollingSnapshot() }

    fun getTankCapacity(): Float = synchronized(lock) { tankCapacityL }

    fun setTankCapacity(liters: Float) {
        synchronized(lock) {
            tankCapacityL = liters.coerceIn(20f, 120f)
            prefs.edit().putFloat(SharedPreferencesKeys.TANK_CAPACITY_L, tankCapacityL).apply()
            Log.i(TAG, "Tank capacity set to ${tankCapacityL}L")
        }
    }

    fun getPriceGasoline(): Float = synchronized(lock) { priceGasolinePerL }
    fun setPriceGasoline(v: Float) {
        synchronized(lock) {
            priceGasolinePerL = v.coerceIn(0.5f, 50f)
            prefs.edit().putFloat(SharedPreferencesKeys.PRICE_GASOLINE_PER_L, priceGasolinePerL).apply()
        }
    }

    fun getPriceEnergy(): Float = synchronized(lock) { priceEnergyPerKwh }
    fun setPriceEnergy(v: Float) {
        synchronized(lock) {
            priceEnergyPerKwh = v.coerceIn(0.1f, 20f)
            prefs.edit().putFloat(SharedPreferencesKeys.PRICE_ENERGY_PER_KWH, priceEnergyPerKwh).apply()
        }
    }

    fun getHistory(): List<TripHistoryEntry> = synchronized(lock) { tripHistory.toList() }

    fun clearHistory() {
        synchronized(lock) {
            tripHistory.clear()
            prefs.edit().remove(SharedPreferencesKeys.TRIP_HISTORY_JSON).apply()
        }
    }

    /**
     * Deleta uma entrada do histórico pelo timestamp ISO (mesmo formato publicado no MQTT).
     * Persiste imediatamente. Retorna true se alguma entrada foi removida.
     */
    fun deleteHistoryEntry(isoTimestamp: String): Boolean = synchronized(lock) {
        val fmt = java.text.SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", java.util.Locale.getDefault())
        val removed = tripHistory.removeIf { entry ->
            try { fmt.format(java.util.Date(entry.timestampMs)) == isoTimestamp } catch (_: Exception) { false }
        }
        if (removed) saveHistory()
        removed
    }

    /**
     * Deleta uma entrada do histórico diretamente pelo objeto (por timestampMs único).
     * Persiste imediatamente. Retorna true se removida.
     */
    fun deleteHistoryEntry(entry: TripHistoryEntry): Boolean = synchronized(lock) {
        val removed = tripHistory.removeIf { it.timestampMs == entry.timestampMs }
        if (removed) saveHistory()
        removed
    }

    fun renameTripHistoryEntry(timestampMs: Long, name: String) {
        synchronized(lock) {
            val idx = tripHistory.indexOfFirst { it.timestampMs == timestampMs }
            if (idx < 0) return
            tripHistory[idx] = tripHistory[idx].copy(name = name.trim())
            saveHistory()
        }
    }

    fun getMaxHistoryEntries(): Int = synchronized(lock) { maxHistoryEntries }

    fun setMaxHistoryEntries(count: Int) {
        synchronized(lock) {
            maxHistoryEntries = count.coerceIn(10, 500)
            prefs.edit().putInt(SharedPreferencesKeys.MAX_HISTORY_ENTRIES, maxHistoryEntries).apply()
            val trimmed = tripHistory.size > maxHistoryEntries
            while (tripHistory.size > maxHistoryEntries) tripHistory.removeAt(tripHistory.lastIndex)
            if (trimmed) saveHistory()
        }
    }

    fun onSessionStart() {
        synchronized(lock) {
            sessionActive = true
            val now = System.currentTimeMillis()
            // Read the flag BEFORE clearing it — tells us if last session ended cleanly.
            val sessionEndedCleanly = prefs.getBoolean(SharedPreferencesKeys.SESSION_ENDED_CLEANLY, false)

            if (lastShutdownMs > 0L && (now - lastShutdownMs) > THREE_HOURS_MS) {
                Log.i(TAG, "3h elapsed since shutdown — resetting rolling window")
                rollingAccFuel       = 0f
                rollingAccEnergy     = 0f
                rollingAccRegen      = 0f
                rollingDistKm        = 0f
                rollingStartSocPct   = 0f
                rollingStartTankL    = 0f
                rollingStartCaptured = false
            } else if (lastShutdownMs > 0L) {
                Log.i(TAG, "< 3h since shutdown — continuing rolling window")
            }

            prevFuelPct         = -1f
            pendingFuelL        = 0f
            checkpointTickCount = 0

            // Initialise lifetime session baselines
            lifeSessStartMs       = now
            lifeSessDistReady     = false
            lifeGearPauseStartMs  = if (isDrivingGear(currentGear)) 0L else now
            lifeTotalPausedMs     = 0L
            lifeSessStartEnergy   = curEnergy
            lifeSessStartRegen    = curRegen
            lifeHwEnergy          = curEnergy
            lifeHwRegen           = curRegen

            // Mark session as NOT cleanly ended.  If we crash during this session, the next
            // onSessionStart() will read false → crash recovery mode.
            prefs.edit().putBoolean(SharedPreferencesKeys.SESSION_ENDED_CLEANLY, false).apply()

            // Sentinels: first odometer reading of the session establishes baseline.
            prevRollingDist   = -1f
            prevRollingEnergy = -1f
            prevRollingRegen  = -1f
            Log.i(TAG, "Session started (cleanEnd=$sessionEndedCleanly) — dist=$curDist energy=$curEnergy regen=$curRegen")
        }
    }

    fun onSessionEnd() {
        synchronized(lock) {
            if (!sessionActive) return
            sessionActive = false
            val now = System.currentTimeMillis()
            // Flush final de sessão para lifetime
            val dEnergyEnd = max(0f, curEnergy - lifeSessStartEnergy)
            val dRegenEnd  = max(0f, curRegen  - lifeSessStartRegen)
            val dDistEnd   = if (lifeSessDistReady) max(0f, curDist - lifeSessStartDist) else 0f
            val extraPauseMsLife = if (lifeGearPauseStartMs > 0L) (now - lifeGearPauseStartMs) else 0L
            val pausedMsLife     = lifeTotalPausedMs + extraPauseMsLife
            val dTimeEnd   = ((now - lifeSessStartMs - pausedMsLife) / 1000L).coerceAtLeast(0L)
            lifeEnergyKwh += dEnergyEnd
            lifeRegenKwh  += dRegenEnd
            lifeDistKm    += dDistEnd
            lifeTimeSec   += dTimeEnd

            // Flush rolling final: capta energia/km do trecho parcial entre o último
            // tick do odômetro e o fim da sessão; o rolling precisa do mesmo para não sub-contar.
            if (prevRollingDist >= 0f) {
                val dEnergyRoll = max(0f, curEnergy - prevRollingEnergy)
                val dRegenRoll  = max(0f, curRegen  - prevRollingRegen)
                val dDistRoll   = max(0f, curDist   - prevRollingDist)
                if (dDistRoll > 0f) {
                    rollingDistKm    += dDistRoll
                    rollingAccEnergy += dEnergyRoll
                    rollingAccRegen  += dRegenRoll
                    AppLogger.i("TripManager",
                        "rolling flush @ session end: +${String.format("%.3f", dDistRoll)}km " +
                        "+${String.format("%.4f", dEnergyRoll)}kWh +${String.format("%.4f", dRegenRoll)}kWhR"
                    )
                }
            }

            lastShutdownMs = now
            // Mark as cleanly ended BEFORE saving so loadFromPrefs() will see true next time.
            prefs.edit().putBoolean(SharedPreferencesKeys.SESSION_ENDED_CLEANLY, true).apply()
            saveToPrefs()
            Log.i(TAG, "Session ended cleanly — trips + rolling persisted, shutdownMs=$lastShutdownMs")
        }
    }

    /** Returns true only when the car is in a driving gear — the only gears that count time. */
    private fun isDrivingGear(gear: String): Boolean = gear in setOf("D", "N", "R")

    /**
     * Called whenever the car reports a gear change.
     * Timer runs ONLY while gear is D, N or R.
     * Pauses for P, empty string (no signal yet) or any unknown value.
     * The lifetime timer uses the same pausedMs tracking so it pauses correctly in P.
     */
    fun onGear(gear: String) {
        synchronized(lock) {
            val wasDriving = isDrivingGear(currentGear)
            val isDriving  = isDrivingGear(gear)
            currentGear = gear

            // Checkpoint de marcha a cada P↔D/R (para StatsScreen — intra-viagem)
            // Auto-trips agora são controlados por onDrivingReady(), não pela marcha.
            when {
                wasDriving && !isDriving -> saveGearTransitionCheckpoint()  // D/N/R → P
                !wasDriving && isDriving -> saveGearTransitionCheckpoint()  // P → D/N/R
            }

            if (!sessionActive) return
            val now = System.currentTimeMillis()
            if (wasDriving && !isDriving) {
                if (lifeGearPauseStartMs == 0L) lifeGearPauseStartMs = now
            } else if (!wasDriving && isDriving) {
                if (lifeGearPauseStartMs > 0L) {
                    lifeTotalPausedMs   += (now - lifeGearPauseStartMs)
                    lifeGearPauseStartMs = 0L
                }
            }
        }
    }

    /**
     * Chamado pelo ConsumptionScreen ao receber CAR_BASIC_DRIVING_READY_STATE.
     * state=1 → carro ligado e pronto → inicia trip automático.
     * state≠1 → carro desligado → finaliza e salva trip automático.
     * O estado é persistido para que, após reinício do app, o contexto seja restaurado:
     * - se state=1 já estava carregado das prefs, não inicia novo trip (já está em andamento).
     * - se state muda 1→0 após reinício, onAutoTripEnd() usa os valores persistidos.
     */
    fun onDrivingReady(state: Int) {
        synchronized(lock) {
            val wasReady = lastDrivingReadyState == 1
            val isReady  = state == 1
            lastDrivingReadyState = state
            prefs.edit().putInt(SharedPreferencesKeys.LAST_DRIVING_READY_STATE, state).apply()

            when {
                !wasReady && isReady -> {   // 0→1: carro ligado — inicia trip automático
                    saveGearTransitionCheckpoint()
                    onAutoTripStart()
                }
                wasReady && !isReady -> {   // 1→0: carro desligado — finaliza trip automático
                    onAutoTripEnd()
                    saveGearTransitionCheckpoint()
                }
                // wasReady==isReady: estado repetido (ex: reconexão/restart) — sem ação
            }
        }
    }

    /** Salva checkpoint dos valores lifetime atuais. Chamado de dentro de synchronized(lock). */
    private fun saveGearTransitionCheckpoint() {
        checkpoints.add(LifetimeCheckpoint(
            timestampMs = System.currentTimeMillis(),
            energyKwh   = lifeEnergyKwh,
            regenKwh    = lifeRegenKwh,
            distKm      = lifeDistKm,
            timeSec     = lifeTimeSec,
            fuelL       = lifeFuelL,
            chargeKwh   = lifeChargeKwh,
            chargeSec   = lifeChargeSec,
        ))
        while (checkpoints.size > 1000) checkpoints.removeAt(0)
        prefs.edit()
            .putString(SharedPreferencesKeys.LIFETIME_CHECKPOINTS_JSON, gson.toJson(checkpoints))
            .apply()
    }

    /** Captura baseline do trip automático. Persiste para sobreviver reinício do app. */
    private fun onAutoTripStart() {
        autoTripStartMs     = System.currentTimeMillis()
        autoTripStartSoc    = latestSocPct
        autoTripStartFuel   = latestFuelPct
        autoTripStartEnergy = lifeEnergyKwh
        autoTripStartRegen  = lifeRegenKwh
        autoTripStartDist   = lifeDistKm
        autoTripStartFuelL  = lifeFuelL
        autoTripStartTime   = lifeTimeSec
        // Snapshot de lifeTotalPausedMs pra calcular o tempo em P durante a viagem
        autoTripStartPausedMs = lifeTotalPausedMs + (if (lifeGearPauseStartMs > 0L) System.currentTimeMillis() - lifeGearPauseStartMs else 0L)
        autoTripEngineOffMs   = 0L
        // Nova viagem (não-resume): zera o override de posição original
        autoTripResumedStartLat = 0.0
        autoTripResumedStartLng = 0.0
        // Persiste para que, se o app reiniciar durante a viagem, os dados não sejam perdidos
        prefs.edit()
            .putLong (SharedPreferencesKeys.AUTO_TRIP_START_MS,       autoTripStartMs)
            .putFloat(SharedPreferencesKeys.AUTO_TRIP_START_SOC,      autoTripStartSoc)
            .putFloat(SharedPreferencesKeys.AUTO_TRIP_START_FUEL,     autoTripStartFuel)
            .putFloat(SharedPreferencesKeys.AUTO_TRIP_START_ENERGY,   autoTripStartEnergy)
            .putFloat(SharedPreferencesKeys.AUTO_TRIP_START_REGEN,    autoTripStartRegen)
            .putFloat(SharedPreferencesKeys.AUTO_TRIP_START_DIST,     autoTripStartDist)
            .putFloat(SharedPreferencesKeys.AUTO_TRIP_START_FUEL_L,   autoTripStartFuelL)
            .putLong (SharedPreferencesKeys.AUTO_TRIP_START_TIME_SEC, autoTripStartTime)
            .putLong (SharedPreferencesKeys.AUTO_TRIP_START_PAUSED_MS,autoTripStartPausedMs)
            .putLong (SharedPreferencesKeys.AUTO_TRIP_ENGINE_OFF_MS,  0L)
            .putFloat(SharedPreferencesKeys.AUTO_TRIP_RESUMED_START_LAT, 0f)
            .putFloat(SharedPreferencesKeys.AUTO_TRIP_RESUMED_START_LNG, 0f)
            .apply()
        autoTripMaxSpeed    = 0f
        autoTripMaxPowerPct = 0
        val inProgressFile = java.io.File(samplesDir, "${autoTripStartMs}_inprogress.json")
        telemetryRecorder?.startRecording(autoTripStartMs, flushFile = inProgressFile)
        AppLogger.i(TAG, "AutoTrip iniciado — SOC=${latestSocPct}% fuel=${latestFuelPct}% temp=${latestOutsideTempC}°C")
    }

    /** Finaliza e persiste viagem automática. Descarta trips < 60 s. Limpa baseline persistida. */
    private fun onAutoTripEnd() {
        if (autoTripStartMs == 0L) return  // sem baseline (app iniciou sem trip em andamento)

        val wallSec = (System.currentTimeMillis() - autoTripStartMs) / 1000L
        if (wallSec < 60L) {
            // Viagem muito curta (ex: carro ligado e desligado em segundos) — descarta
            autoTripStartMs = 0L
            prefs.edit().putLong(SharedPreferencesKeys.AUTO_TRIP_START_MS, 0L).apply()
            AppLogger.i(TAG, "AutoTrip descartado (${wallSec}s < 60s mínimo)")
            return
        }

        // Coleta amostras antes de criar a entry — GPS vem do primeiro/último sample com coords válidas
        val inProgressFile = java.io.File(samplesDir, "${autoTripStartMs}_inprogress.json")
        val telSamples = telemetryRecorder?.stopRecording() ?: emptyList()
        // Remove arquivo de flush em andamento — viagem finalizada com sucesso
        try { inProgressFile.delete() } catch (_: Exception) {}
        val startGps   = telSamples.firstOrNull { it.lat != 0.0 || it.lng != 0.0 }
        val endGps     = telSamples.lastOrNull  { it.lat != 0.0 || it.lng != 0.0 }

        val entry = AutoTripEntry(
            startMs      = autoTripStartMs,
            endMs        = System.currentTimeMillis(),
            startSocPct  = autoTripStartSoc,
            endSocPct    = latestSocPct,
            startFuelPct = autoTripStartFuel,
            endFuelPct   = latestFuelPct,
            distKm       = (lifeDistKm    - autoTripStartDist  ).coerceAtLeast(0f),
            timeSec      = (lifeTimeSec   - autoTripStartTime  ).coerceAtLeast(0L),
            energyKwh    = (lifeEnergyKwh - autoTripStartEnergy).coerceAtLeast(0f),
            regenKwh     = (lifeRegenKwh  - autoTripStartRegen ).coerceAtLeast(0f),
            netKwh       = ((lifeEnergyKwh - autoTripStartEnergy) - (lifeRegenKwh - autoTripStartRegen)).coerceAtLeast(0f),
            fuelL        = (lifeFuelL     - autoTripStartFuelL ).coerceAtLeast(0f),
            maxSpeedKmh  = autoTripMaxSpeed,
            maxPowerPct  = autoTripMaxPowerPct,
            outsideTempC = latestOutsideTempC,
            // Se a viagem foi retomada via resume, usa a posição ORIGINAL preservada
            // pelo resumeLastTrip — caso contrário cai no firstOrNull do telSamples.
            // Sem isso, viagens continuadas perdem o startLat real quando o arquivo
            // de samples do trecho 1 foi deletado em disco pós-sync com o bridge.
            startLat     = if (autoTripResumedStartLat != 0.0) autoTripResumedStartLat else (startGps?.lat ?: 0.0),
            startLng     = if (autoTripResumedStartLng != 0.0) autoTripResumedStartLng else (startGps?.lng ?: 0.0),
            endLat       = endGps?.lat   ?: 0.0,
            endLng       = endGps?.lng   ?: 0.0,
            parkedInPSec = run {
                val now = System.currentTimeMillis()
                val curPausedMs = lifeTotalPausedMs + (if (lifeGearPauseStartMs > 0L) now - lifeGearPauseStartMs else 0L)
                ((curPausedMs - autoTripStartPausedMs).coerceAtLeast(0L)) / 1000L
            },
            engineOffSec = autoTripEngineOffMs / 1000L,
        )
        autoTripHistory.add(entry)
        // Retenção: descarta viagens com mais de 90 dias
        val cutoff90d = System.currentTimeMillis() - 90L * 24 * 3_600_000L
        autoTripHistory.removeAll { it.endMs < cutoff90d }
        autoTripStartMs = 0L
        autoTripMaxSpeed = 0f
        autoTripStartPausedMs = 0L
        autoTripEngineOffMs   = 0L
        autoTripResumedStartLat = 0.0
        autoTripResumedStartLng = 0.0
        prefs.edit()
            .putString(SharedPreferencesKeys.AUTO_TRIP_HISTORY_JSON, gson.toJson(autoTripHistory))
            .putLong  (SharedPreferencesKeys.AUTO_TRIP_START_MS, 0L)
            .putFloat (SharedPreferencesKeys.AUTO_TRIP_MAX_SPEED, 0f)
            .putLong  (SharedPreferencesKeys.AUTO_TRIP_START_PAUSED_MS, 0L)
            .putLong  (SharedPreferencesKeys.AUTO_TRIP_ENGINE_OFF_MS, 0L)
            .putFloat (SharedPreferencesKeys.AUTO_TRIP_RESUMED_START_LAT, 0f)
            .putFloat (SharedPreferencesKeys.AUTO_TRIP_RESUMED_START_LNG, 0f)
            .apply()
        AppLogger.i(TAG, "AutoTrip salvo: ${entry.distKm}km ${entry.timeSec}s ${entry.netKwh}kWh max=${entry.maxSpeedKmh}km/h temp=${entry.outsideTempC}°C")
        onAutoTripCompleted?.invoke(entry)

        val bridgeUrl    = getBridgeHttpUrl()
        val tripId       = entry.startMs.toString()
        val entryStartMs = entry.startMs
        if (telSamples.isNotEmpty()) {
            try {
                java.io.File(samplesDir, "$tripId.json").writeText(gson.toJson(telSamples))
                AppLogger.i(TAG, "Amostras salvas em disco: ${telSamples.size} para trip $tripId")
            } catch (e: Exception) {
                AppLogger.e(TAG, "Erro ao salvar amostras em disco: ${e.message}")
            }
        }
        telemetryRecorder?.postTelemetry(bridgeUrl, getBridgeToken(), tripId, gson.toJson(entry), telSamples) {
            // Confirmação HTTP 2xx → apaga arquivo local e marca como sincronizado
            try { java.io.File(samplesDir, "$tripId.json").delete() } catch (_: Exception) {}
            synchronized(lock) { bridgeSyncedIds.add(entryStartMs) }
            persistSyncedIds()
            AppLogger.i(TAG, "Trip $tripId sincronizada com bridge — amostras enviadas")
        }
    }

    fun onDataChanged(key: String, rawValue: String) {
        val value = parseFloat(rawValue) ?: return
        synchronized(lock) {
            if (!sessionActive) {
                Log.i(TAG, "Auto-starting session on first data ($key)")
                onSessionStart()
            }
            when (key) {
                CarConstants.CAR_BASIC_REMAIN_FUEL_PERCENTAGE.value -> {
                    // Rejeita valores inválidos: o carro pode enviar -1 como "sensor não pronto".
                    // Fora do range (0, 100] é erro — não atualizar latestFuelPct nem acumular.
                    if (value <= 0f || value > 100f) {
                        Log.w(TAG, "Fuel pct ignorado (fora de range): $value")
                        return
                    }
                    latestFuelPct = value
                    prefs.edit().putFloat(SharedPreferencesKeys.LATEST_FUEL_PCT, value).apply()
                    onFuelPct(value)
                    captureStartIfNeeded()
                }
                CarConstants.CAR_EV_INFO_SOC_OF_BATTERY.value,
                CarConstants.CAR_EV_INFO_BATTERY_CHARGE_PERCENTAGE.value,
                CarConstants.CAR_EV_INFO_CUR_BATTERY_POWER_PERCENTAGE.value -> {
                    if (value <= 0f || value > 100f) {
                        Log.w(TAG, "SOC ignorado (fora de range): $value")
                        return
                    }
                    latestSocPct = value
                    telemetryRecorder?.latestSocPct = value.toInt()
                    prefs.edit().putFloat(SharedPreferencesKeys.LATEST_SOC_PCT, value).apply()
                    captureStartIfNeeded()
                }
                CarConstants.CAR_EV_INFO_CYCLE_ENERGY_CONSUME_INFO.value -> onEnergy(value)
                CarConstants.CAR_EV_INFO_ENERGY_RECOVERY_INFO.value      -> onRegen(value)
                CarConstants.CAR_BASIC_CUR_JOURNEY_ODOMETER.value        -> onDist(value)

                // Telemetria em tempo real — alimenta o TelemetryRecorder
                CarConstants.CAR_BASIC_VEHICLE_SPEED.value -> {
                    latestSpeedKmh = value
                    telemetryRecorder?.latestSpeedKmh = value
                    if (autoTripStartMs > 0L && value > autoTripMaxSpeed) {
                        autoTripMaxSpeed = value
                        // Persiste pra sobreviver a kill do app mid-trip. Só grava em
                        // novos picos — então o I/O é raro (~1 write por incremento real).
                        if (::prefs.isInitialized) {
                            prefs.edit().putFloat(SharedPreferencesKeys.AUTO_TRIP_MAX_SPEED, value).apply()
                        }
                    }
                }
                CarConstants.CAR_BASIC_OUTSIDE_TEMP.value -> {
                    latestOutsideTempC = value
                    // Acumula temperatura durante sessão de recarga (para média)
                    if (isChargingNow) {
                        chargeSessionTempSum   += value
                        chargeSessionTempCount++
                    }
                }
                CarConstants.CAR_BASIC_ENGINE_SPEED.value -> {
                    latestEngineRpm = value.toInt()
                    telemetryRecorder?.latestEngineRpm = value.toInt()
                }
                CarConstants.CAR_EV_INFO_ENERGY_OUTPUT_PERCENTAGE.value -> {
                    // % potência motor elétrico em tempo real (car.ev_info.energy_output_percentage)
                    // capturado a cada mudança + amostrado 1×/s pelo TelemetryRecorder
                    val pct = value.toInt()
                    latestBattPowerPct = pct
                    telemetryRecorder?.latestBattPowerPct = pct   // alimenta amostras da viagem
                    if (autoTripStartMs > 0L && pct > autoTripMaxPowerPct) autoTripMaxPowerPct = pct
                }

                else -> return
            }
            notifyListeners()
        }
    }

    /**
     * Atualiza potência do motor elétrico (kW) no TelemetryRecorder.
     * Chamado pelo ConsumptionScreen após calcular V×A/1000 com car.basic.battery_voltage
     * × car.ev_info.cur_charge_current. Separado de onDataChanged porque o valor é
     * calculado, não vem diretamente de uma chave do carro.
     */
    fun updateMotorPowerKw(kw: Float) {
        synchronized(lock) {
            telemetryRecorder?.latestMotorPowerKw = kw
        }
    }

    private fun captureStartIfNeeded() {
        if (!rollingStartCaptured) {
            if (latestSocPct > 0f)  rollingStartSocPct = latestSocPct
            if (latestFuelPct > 0f) rollingStartTankL  = latestFuelPct / 100f * tankCapacityL
            if (latestSocPct > 0f || latestFuelPct > 0f) rollingStartCaptured = true
        }
    }

    fun tickTime() {
        synchronized(lock) {
            // Charging lifetime — integração P×Δt usando wall-clock
            // Roda independentemente de sessão de condução
            // tickTime() é chamado a cada 5s pelo ConsumptionScreen, mas usamos delta
            // real de tempo para não depender da frequência exata do chamador.
            if (isChargingNow && currentChargePowerKw > 0f) {
                val now = System.currentTimeMillis()
                if (lastChargeTickMs > 0L) {
                    // Cap a 10min — tolera sleeps curtos do app em background.
                    // Sleeps mais longos (ex carro estacionado carregando lento por
                    // 1h) são cobertos pelo fallback SOC delta no fim da sessão.
                    val dtSec = ((now - lastChargeTickMs) / 1000L).coerceIn(1L, 600L)
                    val dKwh  = currentChargePowerKw * dtSec / 3600f
                    lifeChargeKwh          += dKwh
                    lifeChargeSec          += dtSec
                    chargeSessionEnergyKwh += dKwh    // acumula também na sessão corrente
                    chargeSessionSec       += dtSec
                }
                lastChargeTickMs = now
                chargeTickCount++
                if (chargeTickCount >= 6) {   // ~30s = 6 ticks × 5s
                    chargeTickCount = 0
                    prefs.edit()
                        .putFloat(SharedPreferencesKeys.LIFETIME_CHARGE_KWH,       lifeChargeKwh)
                        .putLong (SharedPreferencesKeys.LIFETIME_CHARGE_SEC,        lifeChargeSec)
                        .putFloat(SharedPreferencesKeys.CHARGE_SESSION_ENERGY_KWH,  chargeSessionEnergyKwh)
                        .putLong (SharedPreferencesKeys.CHARGE_SESSION_SEC,         chargeSessionSec)
                        .putFloat(SharedPreferencesKeys.CHARGE_SESSION_START_SOC,   chargeSessionStartSoc)
                        .putLong (SharedPreferencesKeys.CHARGE_SESSION_START_MS,    chargeSessionStartMs)
                        .apply()   // async — ok para tick periódico (saveToPrefs().commit() cuida do fim)
                    // Grava amostra da linha do tempo de recarga
                    chargeSessionSamples.add(ChargeSample(
                        t          = chargeSessionSec.toInt(),
                        powerKw    = currentChargePowerKw,
                        sessionKwh = chargeSessionEnergyKwh,
                        socPct     = latestSocPct,
                        tempC      = latestOutsideTempC,
                    ))
                    // Limite de ~500 amostras ≈ 250 min (mais que suficiente para qualquer recarga)
                    while (chargeSessionSamples.size > 500) chargeSessionSamples.removeAt(0)
                }
            } else {
                lastChargeTickMs = 0L   // reset para não contar tempo parado
            }

            // Auto-recuperação: viagem ativa (driving_ready=1 → autoTripStartMs!=0) mas a
            // sessão caiu — ex.: o carro reportou car.basic.power_mode=0 espúrio (sem
            // desligar de fato) ou o APK perdeu o evento de volta a 1/2/3. Sem isso, a
            // distância/tempo da viagem CONGELAM (current_trip trava no último valor).
            // Religa re-baselinando nos valores atuais (não duplica; o trecho da brecha
            // não é recuperado, mas a viagem volta a contar e não trava mais).
            if (!sessionActive && autoTripStartMs != 0L) {
                val now = System.currentTimeMillis()
                sessionActive        = true
                lifeSessStartMs      = now
                lifeSessStartEnergy  = curEnergy
                lifeSessStartRegen   = curRegen
                lifeSessStartDist    = curDist
                lifeSessDistReady    = curDist > 0f
                lifeTotalPausedMs    = 0L
                lifeGearPauseStartMs = if (isDrivingGear(currentGear)) 0L else now
                prevRollingDist = -1f; prevRollingEnergy = -1f; prevRollingRegen = -1f
                checkpointTickCount  = 0
                AppLogger.w(TAG, "Sessão religada (self-heal): driving_ready ativo mas sessionActive=false (power_mode espúrio)")
            }

            if (sessionActive) {
                checkpointTickCount++
                if (checkpointTickCount >= 5) {
                    checkpointSession()
                    checkpointTickCount = 0
                }
                notifyListeners()
            }
        }
    }

    /**
     * Persists the current session's progress into base accumulators every ~5s.
     * This guarantees that a crash or app update does not lose session data:
     * the next session start will recover from the last checkpoint via
     * SESSION_ENDED_CLEANLY=false + stored sessStartEnergy/Regen.
     */
    private fun checkpointSession() {
        if (!sessionActive) return
        val now = System.currentTimeMillis()

        // Lifetime checkpoint: commit deltas since last checkpoint
        val dEnergy = max(0f, curEnergy - lifeSessStartEnergy)
        val dRegen  = max(0f, curRegen  - lifeSessStartRegen)
        val dDist   = if (lifeSessDistReady) max(0f, curDist - lifeSessStartDist) else 0f
        val extraPauseMs = if (lifeGearPauseStartMs > 0L) (now - lifeGearPauseStartMs) else 0L
        val pausedMs     = lifeTotalPausedMs + extraPauseMs
        val deltaSec     = ((now - lifeSessStartMs - pausedMs) / 1000L).coerceAtLeast(0L)
        lifeEnergyKwh += dEnergy
        lifeRegenKwh  += dRegen
        lifeDistKm    += dDist
        lifeTimeSec   += deltaSec

        lifeSessStartEnergy = curEnergy
        lifeSessStartRegen  = curRegen
        if (lifeSessDistReady) lifeSessStartDist = curDist
        lifeSessStartMs     = now
        lifeTotalPausedMs   = 0L
        if (lifeGearPauseStartMs > 0L) lifeGearPauseStartMs = now

        saveToPrefs()
        Log.d(TAG, "Checkpoint — lifeEnergy=$lifeEnergyKwh lifeDist=$lifeDistKm")
    }

    fun resetRolling() {
        synchronized(lock) {
            rollingAccFuel    = 0f
            rollingAccEnergy  = 0f
            rollingAccRegen   = 0f
            rollingDistKm     = 0f
            prevRollingDist   = -1f
            prevRollingEnergy = -1f
            prevRollingRegen  = -1f
            rollingStartSocPct   = latestSocPct
            rollingStartTankL    = latestFuelPct / 100f * tankCapacityL
            rollingStartCaptured = latestSocPct > 0f || latestFuelPct > 0f
            saveToPrefs()
            notifyListeners()
            Log.i(TAG, "Rolling window reset")
        }
    }

    // ── Per-channel handlers ──────────────────────────────────────────────────

    private fun onFuelPct(value: Float) {
        if (prevFuelPct < 0f) {
            prevFuelPct = value
            return
        }
        val drop = prevFuelPct - value
        when {
            drop >= FUEL_PCT_THRESHOLD -> {
                // Real consumption: convert % drop to litres
                val dFuelL = drop / 100f * tankCapacityL
                prevFuelPct   = value
                pendingFuelL += dFuelL
                lifeFuelL      += dFuelL   // lifetime: acumula direto (não passa por checkpoint)
                rollingAccFuel += dFuelL
                Log.d(TAG, "Fuel drop ${drop}% → ${dFuelL}L (pct=$value)")
            }
            drop < -5f -> {
                // Large increase = refuelling — just update baseline, don't subtract
                Log.i(TAG, "Refuel detected: ${-drop}% increase")
                val fuelLBefore = prevFuelPct / 100f * tankCapacityL
                val fuelLAfter  = value / 100f * tankCapacityL
                val litersAdded = (fuelLAfter - fuelLBefore).coerceAtLeast(0f)
                prevFuelPct = value
                // Registra como abastecimento auto-detectado se ≥5L (filtra ruído).
                // price_per_liter fica 0 — usuário preenche depois via PWA.
                if (litersAdded >= 5f) {
                    val entry = RefuelEntry(
                        timestampMs   = System.currentTimeMillis(),
                        fuelLBefore   = fuelLBefore,
                        fuelLAfter    = fuelLAfter,
                        litersAdded   = litersAdded,
                        odometerKm    = MqttManager.getInstance().latestOdometerKm,
                    )
                    refuelHistory.add(0, entry)
                    // Retenção: descarta abastecimentos com mais de 1 ano
                    val cutoff1y = System.currentTimeMillis() - 365L * 24 * 3_600_000L
                    refuelHistory.removeAll { it.timestampMs < cutoff1y }
                    if (::prefs.isInitialized) {
                        prefs.edit()
                            .putString(SharedPreferencesKeys.REFUEL_HISTORY_JSON, gson.toJson(refuelHistory))
                            .apply()
                    }
                    AppLogger.i(TAG, "Abastecimento registrado: ${"%.1f".format(litersAdded)}L (${"%.1f".format(fuelLBefore)}→${"%.1f".format(fuelLAfter)})")
                    onRefuelDetected?.invoke(entry)
                }
            }
            // Small fluctuation (±5%) — ignore
        }
    }

    private fun onEnergy(value: Float) {
        val prev = curEnergy
        curEnergy = value
        if (!sessionActive) return
        if (value < prev && value < lifeHwEnergy * 0.9f) {
            // Counter reset detected — commit delta up to high-water mark
            lifeEnergyKwh += lifeHwEnergy - lifeSessStartEnergy
            if (prevRollingEnergy >= 0f) {
                rollingAccEnergy += max(0f, lifeHwEnergy - prevRollingEnergy)
                prevRollingEnergy = value
            }
            lifeSessStartEnergy = value
            lifeHwEnergy = value
        } else {
            lifeHwEnergy = max(lifeHwEnergy, value)
        }
    }

    private fun onRegen(value: Float) {
        val prev = curRegen
        curRegen = value
        if (!sessionActive) return
        if (value < prev && value < lifeHwRegen * 0.9f) {
            lifeRegenKwh += lifeHwRegen - lifeSessStartRegen
            if (prevRollingRegen >= 0f) {
                rollingAccRegen += max(0f, lifeHwRegen - prevRollingRegen)
                prevRollingRegen = value
            }
            lifeSessStartRegen = value
            lifeHwRegen = value
        } else {
            lifeHwRegen = max(lifeHwRegen, value)
        }
    }

    private fun onDist(value: Float) {
        val prev = curDist
        curDist = value
        if (!sessionActive) return

        // First reading of session: establish rolling baseline + trip dist baseline.
        // The trip baseline MUST be established here so that onSessionEnd() never
        // uses sessStartDist=0 (default) and adds phantom km.
        if (prevRollingDist < 0f) {
            prevRollingDist   = value
            prevRollingEnergy = curEnergy
            prevRollingRegen  = curRegen
            // Establish lifetime dist baseline at first real odometer reading
            if (!lifeSessDistReady) {
                lifeSessStartDist = value
                lifeHwDist        = value
                lifeSessDistReady = true
            }
            return
        }

        val kmStep = value - prevRollingDist
        if (kmStep > 0f) {
            // Rolling energy/regen from deltas; fuel already accumulated in onFuelPct()
            val dEnergy = max(0f, curEnergy - prevRollingEnergy)
            val dRegen  = max(0f, curRegen  - prevRollingRegen)

            prevRollingDist = value
            // High-watermark: nunca deixa o baseline cair.
            // Se curEnergy sofreu um dip entre dois ticks (ruído ou medição) e depois
            // sobe de novo, sem o HW o delta posterior seria maior do que o real
            // (overcounting). Com HW, o baseline só avança, nunca recua.
            prevRollingEnergy = maxOf(prevRollingEnergy, curEnergy)
            prevRollingRegen  = maxOf(prevRollingRegen,  curRegen)

            rollingDistKm    += kmStep
            rollingAccEnergy += dEnergy
            rollingAccRegen  += dRegen

            AppLogger.d("TripManager",
                "rolling tick: km+=${String.format("%.3f", kmStep)} " +
                "dE=${String.format("%.4f", dEnergy)} dR=${String.format("%.4f", dRegen)} " +
                "accE=${String.format("%.3f", rollingAccEnergy)} accR=${String.format("%.3f", rollingAccRegen)} " +
                "dist=${String.format("%.2f", rollingDistKm)} " +
                "→ ${String.format("%.2f", if (rollingDistKm > 0.1f) (rollingAccEnergy - rollingAccRegen) / rollingDistKm * 100f else 0f)} kWh/100km"
            )
        }

        // Lifetime distance tracking
        pendingFuelL = 0f
        if (!lifeSessDistReady) {
            lifeSessStartDist = value
            lifeHwDist        = value
            lifeSessDistReady = true
        } else if (value < prev && value < lifeHwDist * 0.9f) {
            lifeDistKm += lifeHwDist - lifeSessStartDist
            lifeSessStartDist = value
            lifeHwDist = value
        } else {
            lifeHwDist = max(lifeHwDist, value)
        }
    }

    private fun rollingSnapshot() = RollingSnapshot(
        fuelL             = rollingAccFuel.coerceAtLeast(0f),
        energyKwh         = rollingAccEnergy.coerceAtLeast(0f),
        regenKwh          = rollingAccRegen.coerceAtLeast(0f),
        windowKm          = rollingDistKm.coerceAtLeast(0f),
        startSocPct       = rollingStartSocPct,
        currentSocPct     = latestSocPct,
        startTankL        = rollingStartTankL,
        currentTankL      = (latestFuelPct / 100f * tankCapacityL).coerceAtLeast(0f),
        priceGasolinePerL = priceGasolinePerL,
        priceEnergyPerKwh = priceEnergyPerKwh,
    )

    private fun notifyListeners() {
        val rolling = rollingSnapshot()
        val copy    = synchronized(lock) { listeners.toList() }
        copy.forEach { it(rolling) }
    }

    // ── Parsing ───────────────────────────────────────────────────────────────

    private fun parseFloat(raw: String): Float? {
        val trimmed = raw.trim()
        trimmed.toFloatOrNull()?.let { return it }
        return try {
            val obj = JsonParser.parseString(trimmed).asJsonObject
            obj.get("value")?.asFloat ?: obj.get("metric")?.asFloat
        } catch (_: Exception) { null }
    }

    /**
     * Retorna a URL HTTP do bridge para envio de telemetria.
     * Prioridade: campo BRIDGE_URL configurado explicitamente → derivação do host MQTT (fallback).
     * O campo explícito é necessário quando o broker MQTT é externo (cloud) e o bridge
     * roda localmente (ex.: Mac Mini / Raspberry Pi na rede local).
     */
    private fun getBridgeToken(): String =
        prefs.getString(SharedPreferencesKeys.BRIDGE_TOKEN, "") ?: ""

    private fun getBridgeHttpUrl(): String {
        // 1. URL explícita configurada pelo usuário (campo nas configurações)
        val explicit = prefs.getString(SharedPreferencesKeys.BRIDGE_URL, "") ?: ""
        if (explicit.isNotBlank()) return explicit.trimEnd('/')

        // 2. Deriva do IP do Home Assistant (mesmo host, porta 3000) — padrão de fábrica
        val haUrl = prefs.getString(SharedPreferencesKeys.HA_EXPORT_URL, "") ?: ""
        if (haUrl.isNotBlank()) {
            try {
                val host = java.net.URL(haUrl).host
                if (host.isNotBlank()) return "http://$host:3000"
            } catch (_: Exception) {}
        }

        // 3. Último recurso: deriva do host MQTT (só funciona se broker e bridge forem o mesmo servidor)
        val raw = prefs.getString(SharedPreferencesKeys.MQTT_HOST, "") ?: ""
        if (raw.isBlank()) return ""
        val host = raw
            .removePrefix("mqtts://").removePrefix("mqtt://").removePrefix("tcp://")
            .substringBefore(":").trim()
        return if (host.isNotBlank()) "http://$host:3000" else ""
    }

    // ── Persistence ───────────────────────────────────────────────────────────

    private fun loadFromPrefs() {
        // Restaura últimas leituras válidas do carro para não zerar após reinício do app
        latestFuelPct = prefs.getFloat(SharedPreferencesKeys.LATEST_FUEL_PCT, 0f)
        latestSocPct  = prefs.getFloat(SharedPreferencesKeys.LATEST_SOC_PCT,  0f)

        lifeFuelL     = prefs.getFloat(SharedPreferencesKeys.LIFETIME_FUEL_L,      0f)
        lifeEnergyKwh = prefs.getFloat(SharedPreferencesKeys.LIFETIME_ENERGY_KWH,  0f)
        lifeRegenKwh  = prefs.getFloat(SharedPreferencesKeys.LIFETIME_REGEN_KWH,   0f)
        lifeDistKm    = prefs.getFloat(SharedPreferencesKeys.LIFETIME_DISTANCE_KM, 0f)
        lifeTimeSec   = prefs.getLong (SharedPreferencesKeys.LIFETIME_TIME_SEC,    0L)
        lifeChargeKwh = prefs.getFloat(SharedPreferencesKeys.LIFETIME_CHARGE_KWH,  0f)
        lifeChargeSec = prefs.getLong (SharedPreferencesKeys.LIFETIME_CHARGE_SEC,   0L)

        // Restaura sessão de recarga ativa se o app reiniciou enquanto o carro estava carregando
        chargeSessionEnergyKwh = prefs.getFloat(SharedPreferencesKeys.CHARGE_SESSION_ENERGY_KWH, 0f)
        chargeSessionSec       = prefs.getLong (SharedPreferencesKeys.CHARGE_SESSION_SEC,         0L)
        chargeSessionStartSoc  = prefs.getFloat(SharedPreferencesKeys.CHARGE_SESSION_START_SOC,   0f)
        chargeSessionStartMs   = prefs.getLong (SharedPreferencesKeys.CHARGE_SESSION_START_MS,    0L)

        val cpJson = prefs.getString(SharedPreferencesKeys.LIFETIME_CHECKPOINTS_JSON, null)
        if (!cpJson.isNullOrEmpty()) {
            try {
                val type = object : TypeToken<List<LifetimeCheckpoint>>() {}.type
                checkpoints.addAll(gson.fromJson<List<LifetimeCheckpoint>>(cpJson, type))
                AppLogger.i(TAG, "loadFromPrefs: ${checkpoints.size} checkpoints de lifetime carregados")
            } catch (e: Exception) {
                AppLogger.e(TAG, "loadFromPrefs: ERRO ao parsear lifetime_checkpoints_json — ${e.message}")
            }
        }

        val atJson = prefs.getString(SharedPreferencesKeys.AUTO_TRIP_HISTORY_JSON, null)
        if (!atJson.isNullOrEmpty()) {
            try {
                val type = object : TypeToken<List<AutoTripEntry>>() {}.type
                autoTripHistory.addAll(gson.fromJson<List<AutoTripEntry>>(atJson, type))
                AppLogger.i(TAG, "loadFromPrefs: ${autoTripHistory.size} auto-trips carregados")
            } catch (e: Exception) {
                AppLogger.e(TAG, "loadFromPrefs: ERRO ao parsear auto_trip_history_json — ${e.message}")
            }
        } else {
            AppLogger.i(TAG, "loadFromPrefs: auto_trip_history_json ausente/vazio — sem histórico gravado")
        }

        // IDs de viagens já sincronizadas com o bridge
        val syncJson = prefs.getString(SharedPreferencesKeys.BRIDGE_SYNCED_TRIP_IDS, null)
        if (!syncJson.isNullOrEmpty()) {
            try {
                val type = object : TypeToken<List<Long>>() {}.type
                bridgeSyncedIds.addAll(gson.fromJson<List<Long>>(syncJson, type))
            } catch (_: Exception) {}
        }

        // Recupera estado de condução e baseline de trip em andamento (resistência a reinício)
        lastDrivingReadyState = prefs.getInt (SharedPreferencesKeys.LAST_DRIVING_READY_STATE, 0)
        autoTripStartMs       = prefs.getLong(SharedPreferencesKeys.AUTO_TRIP_START_MS, 0L)
        if (autoTripStartMs > 0L) {
            autoTripStartSoc    = prefs.getFloat(SharedPreferencesKeys.AUTO_TRIP_START_SOC,      0f)
            autoTripStartFuel   = prefs.getFloat(SharedPreferencesKeys.AUTO_TRIP_START_FUEL,     0f)
            autoTripStartEnergy = prefs.getFloat(SharedPreferencesKeys.AUTO_TRIP_START_ENERGY,   0f)
            autoTripStartRegen  = prefs.getFloat(SharedPreferencesKeys.AUTO_TRIP_START_REGEN,    0f)
            autoTripStartDist   = prefs.getFloat(SharedPreferencesKeys.AUTO_TRIP_START_DIST,     0f)
            autoTripStartFuelL  = prefs.getFloat(SharedPreferencesKeys.AUTO_TRIP_START_FUEL_L,   0f)
            autoTripStartTime     = prefs.getLong (SharedPreferencesKeys.AUTO_TRIP_START_TIME_SEC, 0L)
            autoTripMaxSpeed      = prefs.getFloat(SharedPreferencesKeys.AUTO_TRIP_MAX_SPEED,      0f)
            autoTripStartPausedMs = prefs.getLong (SharedPreferencesKeys.AUTO_TRIP_START_PAUSED_MS,0L)
            autoTripEngineOffMs   = prefs.getLong (SharedPreferencesKeys.AUTO_TRIP_ENGINE_OFF_MS,  0L)
            autoTripResumedStartLat = prefs.getFloat(SharedPreferencesKeys.AUTO_TRIP_RESUMED_START_LAT, 0f).toDouble()
            autoTripResumedStartLng = prefs.getFloat(SharedPreferencesKeys.AUTO_TRIP_RESUMED_START_LNG, 0f).toDouble()
            AppLogger.i(TAG, "AutoTrip em andamento recuperado do disco — startMs=$autoTripStartMs maxSpd=${autoTripMaxSpeed} resumedStart=(${autoTripResumedStartLat},${autoTripResumedStartLng})")
        }

        val chargeHistJson = prefs.getString(SharedPreferencesKeys.CHARGE_HISTORY_JSON, null)
        if (!chargeHistJson.isNullOrEmpty()) {
            try {
                val type = object : TypeToken<List<ChargeHistoryEntry>>() {}.type
                val loaded: List<ChargeHistoryEntry> = gson.fromJson(chargeHistJson, type)
                chargeHistory.clear()
                chargeHistory.addAll(loaded)
            } catch (_: Exception) {}
        }

        val refuelHistJson = prefs.getString(SharedPreferencesKeys.REFUEL_HISTORY_JSON, null)
        if (!refuelHistJson.isNullOrEmpty()) {
            try {
                val type = object : TypeToken<List<RefuelEntry>>() {}.type
                val loaded: List<RefuelEntry> = gson.fromJson(refuelHistJson, type)
                refuelHistory.clear()
                refuelHistory.addAll(loaded)
            } catch (_: Exception) {}
        }

        rollingAccFuel      = prefs.getFloat(SharedPreferencesKeys.ROLLING_FUEL_L,        0f)
        rollingAccEnergy    = prefs.getFloat(SharedPreferencesKeys.ROLLING_ENERGY_KWH,    0f)
        rollingAccRegen     = prefs.getFloat(SharedPreferencesKeys.ROLLING_REGEN_KWH,     0f)
        rollingDistKm       = prefs.getFloat(SharedPreferencesKeys.ROLLING_DISTANCE_KM,   0f)
        lastShutdownMs      = prefs.getLong (SharedPreferencesKeys.ROLLING_SHUTDOWN_MS,   0L)
        rollingStartSocPct  = prefs.getFloat(SharedPreferencesKeys.ROLLING_START_SOC_PCT, 0f)
        rollingStartTankL   = prefs.getFloat(SharedPreferencesKeys.ROLLING_START_TANK_L,  0f)
        rollingStartCaptured = rollingStartSocPct > 0f || rollingStartTankL > 0f
        tankCapacityL     = prefs.getFloat(SharedPreferencesKeys.TANK_CAPACITY_L,       DEFAULT_TANK_L)
        maxHistoryEntries = prefs.getInt  (SharedPreferencesKeys.MAX_HISTORY_ENTRIES,   50)
        priceGasolinePerL = prefs.getFloat(SharedPreferencesKeys.PRICE_GASOLINE_PER_L,  6.0f)
        priceEnergyPerKwh = prefs.getFloat(SharedPreferencesKeys.PRICE_ENERGY_PER_KWH,  0.9f)
        minAutoTripDistKm = prefs.getFloat(SharedPreferencesKeys.MIN_AUTO_TRIP_DIST_KM,  0f)

        val histJson = prefs.getString(SharedPreferencesKeys.TRIP_HISTORY_JSON, null)
        if (!histJson.isNullOrEmpty()) {
            try {
                val type = object : TypeToken<List<TripHistoryEntry>>() {}.type
                val loaded: List<TripHistoryEntry> = gson.fromJson(histJson, type)
                tripHistory.clear()
                tripHistory.addAll(loaded)
            } catch (_: Exception) {}
        }

    }

    private fun saveToPrefs() {
        prefs.edit()
            .putFloat(SharedPreferencesKeys.LIFETIME_FUEL_L,      lifeFuelL)
            .putFloat(SharedPreferencesKeys.LIFETIME_ENERGY_KWH,  lifeEnergyKwh)
            .putFloat(SharedPreferencesKeys.LIFETIME_REGEN_KWH,   lifeRegenKwh)
            .putFloat(SharedPreferencesKeys.LIFETIME_DISTANCE_KM, lifeDistKm)
            .putLong (SharedPreferencesKeys.LIFETIME_TIME_SEC,    lifeTimeSec)
            .putFloat(SharedPreferencesKeys.LIFETIME_CHARGE_KWH,  lifeChargeKwh)
            .putLong (SharedPreferencesKeys.LIFETIME_CHARGE_SEC,   lifeChargeSec)
            .putFloat(SharedPreferencesKeys.ROLLING_FUEL_L,        rollingAccFuel)
            .putFloat(SharedPreferencesKeys.ROLLING_ENERGY_KWH,    rollingAccEnergy)
            .putFloat(SharedPreferencesKeys.ROLLING_REGEN_KWH,     rollingAccRegen)
            .putFloat(SharedPreferencesKeys.ROLLING_DISTANCE_KM,   rollingDistKm)
            .putLong (SharedPreferencesKeys.ROLLING_SHUTDOWN_MS,   lastShutdownMs)
            .putFloat(SharedPreferencesKeys.ROLLING_START_SOC_PCT, rollingStartSocPct)
            .putFloat(SharedPreferencesKeys.ROLLING_START_TANK_L,  rollingStartTankL)
            .commit()   // síncrono — garante que os valores estão no disco antes de o processo morrer
    }

    private fun saveHistory() {
        prefs.edit()
            .putString(SharedPreferencesKeys.TRIP_HISTORY_JSON, gson.toJson(tripHistory))
            .commit()
    }

    private fun saveChargeHistory() {
        if (!::prefs.isInitialized) return
        prefs.edit()
            .putString(SharedPreferencesKeys.CHARGE_HISTORY_JSON, gson.toJson(chargeHistory))
            .apply()
    }
}
