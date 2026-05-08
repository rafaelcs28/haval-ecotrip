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
private const val THREE_HOURS_MS = 3 * 3600_000L

enum class TripId { A, B }

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
    // km/L equivalente combinando combustível + energia elétrica (requer preços configurados)
    val combinedKmL: Float get() {
        if (priceGasolinePerL <= 0f || priceEnergyPerKwh <= 0f || distKm < 0.1f) return 0f
        val eqFuelL = netKwh * priceEnergyPerKwh / priceGasolinePerL
        val totalFuelL = fuelL + eqFuelL
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
) {
    val netKwh: Float get() = energyKwh - regenKwh
    val kmPerL: Float get() = if (fuelL > 0.001f) distKm / fuelL else 0f
    val kwhPer100km: Float get() = if (distKm > 0.1f) (netKwh / distKm) * 100f else 0f
    val avgSpeedKmh: Float get() = if (timeSec > 0L) distKm / (timeSec / 3600f) else 0f
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
    val combinedKmL: Float get() {
        if (priceGasolinePerL <= 0f || priceEnergyPerKwh <= 0f || windowKm < 0.1f) return 0f
        val eqFuelL = netKwh * priceEnergyPerKwh / priceGasolinePerL
        val totalFuelL = fuelL + eqFuelL
        return if (totalFuelL > 0.001f) windowKm / totalFuelL else 0f
    }
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

typealias TripListener = (snapA: TripSnapshot, snapB: TripSnapshot, rolling: RollingSnapshot) -> Unit

private class TripAccum {
    var fuelL: Float = 0f       // persisted across sessions
    var sessionFuelL: Float = 0f // current session only (instant-rate × km)
    var energyKwh: Float = 0f
    var regenKwh: Float = 0f
    var distKm: Float = 0f
    var timeSec: Long = 0L
    // session-start baselines (energy, regen, dist — not fuel)
    var sessStartEnergy: Float = 0f
    var sessStartRegen: Float = 0f
    var sessStartDist: Float = 0f
    var sessStartMs: Long = 0L
    // high-water marks for reset detection (energy, regen, dist — not fuel)
    var hwEnergy: Float = 0f
    var hwRegen: Float = 0f
    var hwDist: Float = 0f
    // Sentinel: false until first onDist() of the session establishes the real baseline.
    // Prevents phantom km when the app restarts and curDist is 0 while the journey odometer
    // is already at a large accumulated value (e.g. 50 km from the previous trip).
    var sessDistReady: Boolean = false
    // raw chart samples: (kmStep, netKwh, fuelL)
    val rawSamples: MutableList<Triple<Float, Float, Float>> = mutableListOf()
    // Per-tick energy baselines used ONLY by the block chart.
    // Unlike sessStartEnergy/Regen these are NOT reset by checkpointSession(),
    // so each sample stores the incremental kWh since the previous odometer tick.
    var blockPrevEnergy: Float = 0f
    var blockPrevRegen:  Float = 0f
    // SOC and fuel % bookmarks — captured independently so whichever arrives first
    // doesn't block the other from being correctly recorded.
    var startSocPct:       Float   = 0f
    var startFuelPct:      Float   = 0f
    var startSocCaptured:  Boolean = false
    var startFuelCaptured: Boolean = false
    // Gear pause tracking — timer runs ONLY while gear is D, N or R; paused for P/empty/unknown
    var gearPauseStartMs: Long = 0L   // >0 = timestamp when non-driving gear started this session
    var totalPausedMs:    Long = 0L   // cumulative ms paused this session
}

class TripManager private constructor() {

    companion object {
        @Volatile private var instance: TripManager? = null
        fun getInstance() = instance ?: synchronized(this) {
            instance ?: TripManager().also { instance = it }
        }

        private const val CHART_BLOCKS      = 50
        private const val CHART_BLOCK_KM    = 1f
        private const val CHART_WINDOW_KM   = CHART_BLOCK_KM * CHART_BLOCKS  // 50km
        private const val DEFAULT_TANK_L    = 51f
        private const val FUEL_PCT_THRESHOLD = 1f
    }

    private lateinit var prefs: SharedPreferences
    private val listeners = mutableListOf<TripListener>()
    private val lock = Any()
    private val gson = Gson()

    private var tankCapacityL     = DEFAULT_TANK_L
    private var maxHistoryEntries = 50
    private var priceGasolinePerL = 6.0f   // R$/L — default para gasolina no Brasil
    private var priceEnergyPerKwh = 0.9f   // R$/kWh — default tarifário residencial
    private val tripHistory       = mutableListOf<TripHistoryEntry>()

    private val tripA = TripAccum()
    private val tripB = TripAccum()

    // ── Lifetime — nunca zera ────────────────────────────────────────────────────
    private var lifeFuelL:     Float = 0f
    private var lifeEnergyKwh: Float = 0f
    private var lifeRegenKwh:  Float = 0f
    private var lifeDistKm:    Float = 0f
    private var lifeTimeSec:   Long  = 0L
    // Recarga — integração P×Δt (independente de sessão de condução)
    private var lifeChargeKwh:        Float   = 0f
    private var lifeChargeSec:        Long    = 0L
    private var currentChargePowerKw: Float   = 0f
    private var isChargingNow:        Boolean = false
    private var chargeTickCount:      Int     = 0
    private var lastChargeTickMs:     Long    = 0L   // wall clock do último tick de carga

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
            if (!isCharging && wasCharging) {
                // Fim de recarga — persiste imediatamente (não espera próximo tick)
                saveToPrefs()
                AppLogger.i(TAG, "Recarga concluída — chargeKwh=$lifeChargeKwh chargeSec=$lifeChargeSec")
            }
        }
    }

    fun init(context: Context) {
        val ctx = try {
            context.createDeviceProtectedStorageContext()
        } catch (e: Exception) {
            context
        }
        prefs = ctx.getSharedPreferences(SharedPreferencesKeys.PREFS_NAME, Context.MODE_PRIVATE)
        loadFromPrefs()
    }

    fun addListener(l: TripListener)    = synchronized(lock) { listeners.add(l) }
    fun removeListener(l: TripListener) = synchronized(lock) { listeners.remove(l) }

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

            for (trip in listOf(tripA, tripB)) {
                trip.sessionFuelL     = 0f
                trip.sessStartMs      = now
                // sessDistReady = false: first onDist() establishes the real dist baseline
                trip.sessDistReady    = false
                // Start paused unless already in a driving gear (D/N/R) — covers P, empty, unknown
                trip.gearPauseStartMs = if (isDrivingGear(currentGear)) 0L else now
                trip.totalPausedMs    = 0L

                if (!sessionEndedCleanly && (trip.sessStartEnergy > 0f || trip.sessStartRegen > 0f)) {
                    // Crash/update recovery: restore energy baselines from last checkpoint.
                    // sessStartEnergy & sessStartRegen were loaded from prefs in loadFromPrefs().
                    trip.hwEnergy = trip.sessStartEnergy
                    trip.hwRegen  = trip.sessStartRegen
                    Log.i(TAG, "Session recovery — restoring energy baseline: startE=${trip.sessStartEnergy} startR=${trip.sessStartRegen}")
                } else {
                    // Fresh (clean) session start: current car readings become new baseline.
                    trip.sessStartEnergy = curEnergy
                    trip.sessStartRegen  = curRegen
                    trip.hwEnergy        = curEnergy
                    trip.hwRegen         = curRegen
                }
                // Block chart baselines always start from current reading (crash or clean).
                trip.blockPrevEnergy = curEnergy
                trip.blockPrevRegen  = curRegen
            }

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
            for (trip in listOf(tripA, tripB)) {
                // Finalize any ongoing P pause
                val extraPauseMs = if (trip.gearPauseStartMs > 0L) (now - trip.gearPauseStartMs) else 0L
                val pausedMs     = trip.totalPausedMs + extraPauseMs
                // Capturar deltas antes de aplicar (usados também pelo lifetime)
                val dEnergyEnd = max(0f, curEnergy - trip.sessStartEnergy)
                val dRegenEnd  = max(0f, curRegen  - trip.sessStartRegen)
                val dDistEnd   = if (trip.sessDistReady) max(0f, curDist - trip.sessStartDist) else 0f
                val dTimeEnd   = ((now - trip.sessStartMs - pausedMs) / 1000L).coerceAtLeast(0L)

                trip.fuelL     += trip.sessionFuelL
                trip.energyKwh += dEnergyEnd
                trip.regenKwh  += dRegenEnd
                // Só acumula distância se o baseline foi estabelecido nesta sessão.
                // Evita phantom km quando o app reinicia e sessStartDist=0 (padrão não persistido).
                if (trip.sessDistReady) trip.distKm += dDistEnd
                trip.timeSec      += dTimeEnd
                trip.sessionFuelL   = 0f
                trip.gearPauseStartMs = 0L
                trip.totalPausedMs    = 0L

                // Lifetime — ponto 6: flush final do fim de sessão (apenas trip A)
                // lifeFuelL: NÃO adicionar — sessionFuelL já foi acumulado em onFuelPct()
                if (trip === tripA) {
                    lifeEnergyKwh += dEnergyEnd
                    lifeRegenKwh  += dRegenEnd
                    lifeDistKm    += dDistEnd
                    lifeTimeSec   += dTimeEnd
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
     * Since lifetime time piggybacks on Trip A's delta (which uses the same pausedMs),
     * this fix automatically applies to the lifetime timer as well.
     */
    fun onGear(gear: String) {
        synchronized(lock) {
            val wasDriving = isDrivingGear(currentGear)
            val isDriving  = isDrivingGear(gear)
            currentGear = gear
            if (!sessionActive) return
            val now = System.currentTimeMillis()
            for (trip in listOf(tripA, tripB)) {
                if (wasDriving && !isDriving) {
                    // Left a driving gear (D/N/R) → pause timer
                    if (trip.gearPauseStartMs == 0L) trip.gearPauseStartMs = now
                } else if (!wasDriving && isDriving) {
                    // Entered a driving gear → resume timer
                    if (trip.gearPauseStartMs > 0L) {
                        trip.totalPausedMs   += (now - trip.gearPauseStartMs)
                        trip.gearPauseStartMs = 0L
                    }
                }
            }
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
                    // Idem: SOC só faz sentido em (0, 100]
                    if (value <= 0f || value > 100f) {
                        Log.w(TAG, "SOC ignorado (fora de range): $value")
                        return
                    }
                    latestSocPct = value
                    prefs.edit().putFloat(SharedPreferencesKeys.LATEST_SOC_PCT, value).apply()
                    captureStartIfNeeded()
                }
                CarConstants.CAR_EV_INFO_CYCLE_ENERGY_CONSUME_INFO.value -> onEnergy(value)
                CarConstants.CAR_EV_INFO_ENERGY_RECOVERY_INFO.value      -> onRegen(value)
                CarConstants.CAR_BASIC_CUR_JOURNEY_ODOMETER.value        -> onDist(value)
                else -> return
            }
            notifyListeners()
        }
    }

    private fun captureStartIfNeeded() {
        // Capture SOC and fuel independently — each is locked once the first non-zero value
        // arrives for that type, so a late-arriving key doesn't overwrite the start bookmark.
        for (trip in listOf(tripA, tripB)) {
            if (!trip.startSocCaptured && latestSocPct > 0f) {
                trip.startSocPct      = latestSocPct
                trip.startSocCaptured = true
            }
            if (!trip.startFuelCaptured && latestFuelPct > 0f) {
                trip.startFuelPct      = latestFuelPct
                trip.startFuelCaptured = true
            }
        }
        if (!rollingStartCaptured) {
            if (latestSocPct > 0f)  rollingStartSocPct = latestSocPct
            if (latestFuelPct > 0f) rollingStartTankL  = latestFuelPct / 100f * tankCapacityL
            if (latestSocPct > 0f || latestFuelPct > 0f) rollingStartCaptured = true
        }
    }

    fun resetTrip(id: TripId, name: String = "") {
        synchronized(lock) {
            val trip = if (id == TripId.A) tripA else tripB
            val label = if (id == TripId.A) "Trip A" else "Trip B"
            val now = System.currentTimeMillis()

            // Save to history before clearing (only if trip has meaningful data)
            val snap = snapshot(trip)
            if (snap.distKm > 0.5f) {
                val entry = TripHistoryEntry(
                    name        = name.trim(),
                    label       = label,
                    timestampMs = now,
                    fuelL       = snap.fuelL,
                    energyKwh   = snap.energyKwh,
                    regenKwh    = snap.regenKwh,
                    distKm      = snap.distKm,
                    timeSec     = snap.timeSec,
                    startSocPct = snap.startSocPct,
                    endSocPct   = snap.currentSocPct,
                    startTankL  = snap.startTankL,
                    endTankL    = snap.currentTankL,
                    combinedKmL = snap.combinedKmL,
                )
                tripHistory.add(0, entry)
                while (tripHistory.size > maxHistoryEntries) tripHistory.removeAt(tripHistory.lastIndex)
                saveHistory()
            }

            // Lifetime — ponto 7: flush deltas inter-checkpoint para lifetime antes de zerar trip A
            // (dados entre o último checkpoint e o momento do reset que ainda não foram commitados)
            if (id == TripId.A && sessionActive) {
                lifeEnergyKwh += max(0f, curEnergy - trip.sessStartEnergy)
                lifeRegenKwh  += max(0f, curRegen  - trip.sessStartRegen)
                if (trip.sessDistReady) lifeDistKm += max(0f, curDist - trip.sessStartDist)
                val extraPauseMs = if (trip.gearPauseStartMs > 0L) (now - trip.gearPauseStartMs) else 0L
                val pausedMs = trip.totalPausedMs + extraPauseMs
                lifeTimeSec += ((now - trip.sessStartMs - pausedMs) / 1000L).coerceAtLeast(0L)
                // lifeFuelL: NÃO adicionar sessionFuelL — já está em lifeFuelL via onFuelPct()
            }

            // Zero all accumulators
            trip.fuelL        = 0f
            trip.sessionFuelL = 0f
            trip.energyKwh    = 0f
            trip.regenKwh     = 0f
            trip.distKm       = 0f
            trip.timeSec      = 0L

            // Move session baselines to current position so all deltas restart from zero
            trip.sessStartEnergy  = curEnergy
            trip.sessStartRegen   = curRegen
            trip.sessStartDist    = curDist
            trip.sessStartMs      = now
            trip.hwEnergy         = curEnergy
            trip.hwRegen          = curRegen
            trip.hwDist           = curDist
            trip.sessDistReady    = true   // curDist is known-good at manual reset time
            // Reset pause tracking — pause unless currently in a driving gear
            trip.gearPauseStartMs = if (isDrivingGear(currentGear)) 0L else now
            trip.totalPausedMs    = 0L

            // Reset start bookmarks for next trip — independently per type
            trip.startSocPct       = latestSocPct
            trip.startFuelPct      = latestFuelPct
            trip.startSocCaptured  = latestSocPct  > 0f
            trip.startFuelCaptured = latestFuelPct > 0f

            trip.blockPrevEnergy = curEnergy
            trip.blockPrevRegen  = curRegen
            trip.rawSamples.clear()
            saveToPrefs()
            notifyListeners()
            Log.i(TAG, "Trip $id reset — history size=${tripHistory.size}")
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
                    // Cap a 60s para não contar intervalos longos (ex: app suspenso)
                    val dtSec = ((now - lastChargeTickMs) / 1000L).coerceIn(1L, 60L)
                    lifeChargeKwh += currentChargePowerKw * dtSec / 3600f
                    lifeChargeSec += dtSec
                }
                lastChargeTickMs = now
                chargeTickCount++
                if (chargeTickCount >= 6) {   // ~30s = 6 ticks × 5s
                    chargeTickCount = 0
                    prefs.edit()
                        .putFloat(SharedPreferencesKeys.LIFETIME_CHARGE_KWH, lifeChargeKwh)
                        .putLong (SharedPreferencesKeys.LIFETIME_CHARGE_SEC,  lifeChargeSec)
                        .apply()   // async — ok para tick periódico (saveToPrefs().commit() cuida do fim)
                }
            } else {
                lastChargeTickMs = 0L   // reset para não contar tempo parado
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
        for (trip in listOf(tripA, tripB)) {
            // Fuel: merge session accumulator into base
            // (lifeFuelL já acumulado em onFuelPct — não adicionar aqui)
            trip.fuelL        += trip.sessionFuelL
            trip.sessionFuelL  = 0f

            // Energy: commit delta since last checkpoint, advance baseline
            val dEnergy = max(0f, curEnergy - trip.sessStartEnergy)
            trip.energyKwh      += dEnergy
            trip.sessStartEnergy = curEnergy
            trip.hwEnergy        = curEnergy   // reset high-water to current

            // Regen: same pattern
            val dRegen = max(0f, curRegen - trip.sessStartRegen)
            trip.regenKwh      += dRegen
            trip.sessStartRegen = curRegen
            trip.hwRegen        = curRegen

            // Distance: only if baseline was established this session
            var dDist = 0f
            if (trip.sessDistReady) {
                dDist = max(0f, curDist - trip.sessStartDist)
                trip.distKm       += dDist
                trip.sessStartDist = curDist
                trip.hwDist        = curDist
            }

            // Time: account for ongoing P-gear pause, then restart timer from now
            val extraPauseMs = if (trip.gearPauseStartMs > 0L) (now - trip.gearPauseStartMs) else 0L
            val pausedMs     = trip.totalPausedMs + extraPauseMs
            val deltaSec     = ((now - trip.sessStartMs - pausedMs) / 1000L).coerceAtLeast(0L)
            trip.timeSec      += deltaSec
            trip.sessStartMs   = now
            trip.totalPausedMs = 0L
            // If still in P, reset pause start so next window doesn't double-count
            if (trip.gearPauseStartMs > 0L) trip.gearPauseStartMs = now

            // Lifetime — ponto 5: acumula deltas do checkpoint (apenas trip A)
            if (trip === tripA) {
                lifeEnergyKwh += dEnergy
                lifeRegenKwh  += dRegen
                lifeDistKm    += dDist
                lifeTimeSec   += deltaSec
            }
        }
        saveToPrefs()
        Log.d(TAG, "Checkpoint — fuelA=${tripA.fuelL} distA=${tripA.distKm} energyA=${tripA.energyKwh}")
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
                for (trip in listOf(tripA, tripB)) trip.sessionFuelL += dFuelL
                lifeFuelL      += dFuelL   // lifetime: acumula direto (não passa por checkpoint)
                rollingAccFuel += dFuelL
                Log.d(TAG, "Fuel drop ${drop}% → ${dFuelL}L (pct=$value)")
            }
            drop < -5f -> {
                // Large increase = refuelling — just update baseline, don't subtract
                Log.i(TAG, "Refuel detected: ${-drop}% increase")
                prevFuelPct = value
            }
            // Small fluctuation (±5%) — ignore
        }
    }

    private fun onEnergy(value: Float) {
        val prev = curEnergy
        curEnergy = value
        if (!sessionActive) return
        for (trip in listOf(tripA, tripB)) {
            if (value < prev && value < trip.hwEnergy * 0.9f) {
                if (trip === tripA) lifeEnergyKwh += trip.hwEnergy - trip.sessStartEnergy   // ponto 2
                trip.energyKwh += trip.hwEnergy - trip.sessStartEnergy
                trip.sessStartEnergy = value
                trip.hwEnergy = value
            } else {
                trip.hwEnergy = max(trip.hwEnergy, value)
            }
        }
    }

    private fun onRegen(value: Float) {
        val prev = curRegen
        curRegen = value
        if (!sessionActive) return
        for (trip in listOf(tripA, tripB)) {
            if (value < prev && value < trip.hwRegen * 0.9f) {
                if (trip === tripA) lifeRegenKwh += trip.hwRegen - trip.sessStartRegen   // ponto 3
                trip.regenKwh += trip.hwRegen - trip.sessStartRegen
                trip.sessStartRegen = value
                trip.hwRegen = value
            } else {
                trip.hwRegen = max(trip.hwRegen, value)
            }
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
            for (trip in listOf(tripA, tripB)) {
                if (!trip.sessDistReady) {
                    trip.sessStartDist   = value
                    trip.hwDist          = value
                    trip.sessDistReady   = true
                    // Re-anchor block baselines at the first real odometer reading
                    // so chart deltas start cleanly from here (not from session-start
                    // when the car may not have sent energy data yet).
                    trip.blockPrevEnergy = curEnergy
                    trip.blockPrevRegen  = curRegen
                }
            }
            return
        }

        val kmStep = value - prevRollingDist
        if (kmStep > 0f) {
            // Rolling energy/regen from deltas; fuel already accumulated in onFuelPct()
            val dEnergy = max(0f, curEnergy - prevRollingEnergy)
            val dRegen  = max(0f, curRegen  - prevRollingRegen)

            prevRollingDist   = value
            prevRollingEnergy = curEnergy
            prevRollingRegen  = curRegen

            rollingDistKm    += kmStep
            rollingAccEnergy += dEnergy
            rollingAccRegen  += dRegen
        }

        // Trip distance tracking + chart
        val fuelThisTick = pendingFuelL
        pendingFuelL = 0f
        for (trip in listOf(tripA, tripB)) {
            if (!trip.sessDistReady) {
                // First real odometer reading of this session — establish baseline from the
                // actual car value (not the stale curDist that was 0 after app restart).
                trip.sessStartDist = value
                trip.hwDist        = value
                trip.sessDistReady = true
                continue   // nothing to accumulate yet; next tick will start counting
            }
            if (value < prev && value < trip.hwDist * 0.9f) {
                if (trip === tripA) lifeDistKm += trip.hwDist - trip.sessStartDist   // ponto 4
                trip.distKm += trip.hwDist - trip.sessStartDist
                trip.sessStartDist = value
                trip.hwDist = value
            } else {
                trip.hwDist = max(trip.hwDist, value)
            }
            updateBlocks(trip, value, prev, fuelThisTick)
        }
    }

    private fun updateBlocks(trip: TripAccum, newDist: Float, prevDist: Float, fuelL: Float) {
        val kmStep = max(0f, newDist - prevDist)
        if (kmStep <= 0f) return
        // Incremental energy for this single odometer tick.
        // blockPrevEnergy/Regen advance every tick and are NOT reset by checkpointSession(),
        // so each sample holds the real delta for that ~1km segment.
        val dEnergy = max(0f, curEnergy - trip.blockPrevEnergy)
        val dRegen  = max(0f, curRegen  - trip.blockPrevRegen)
        val dNet    = max(0f, dEnergy - dRegen)
        trip.blockPrevEnergy = curEnergy
        trip.blockPrevRegen  = curRegen
        trip.rawSamples.add(Triple(kmStep, dNet, fuelL))
    }

    // ── Snapshots ─────────────────────────────────────────────────────────────

    private fun snapshot(trip: TripAccum): TripSnapshot {
        val sessionFuel   = if (sessionActive) trip.sessionFuelL else 0f
        val deltaEnergy   = if (sessionActive) max(0f, curEnergy - trip.sessStartEnergy) else 0f
        val deltaRegen    = if (sessionActive) max(0f, curRegen  - trip.sessStartRegen)  else 0f
        val deltaDist     = if (sessionActive && trip.sessDistReady) max(0f, curDist - trip.sessStartDist) else 0f
        val snapshotNow   = System.currentTimeMillis()
        val extraPauseMs  = if (sessionActive && trip.gearPauseStartMs > 0L) (snapshotNow - trip.gearPauseStartMs) else 0L
        val pausedMs      = trip.totalPausedMs + extraPauseMs
        val deltaTime     = if (sessionActive) ((snapshotNow - trip.sessStartMs - pausedMs) / 1000L).coerceAtLeast(0L) else 0L
        return TripSnapshot(
            fuelL             = (trip.fuelL     + sessionFuel).coerceAtLeast(0f),
            energyKwh         = (trip.energyKwh + deltaEnergy).coerceAtLeast(0f),
            regenKwh          = (trip.regenKwh  + deltaRegen).coerceAtLeast(0f),
            distKm            = (trip.distKm    + deltaDist).coerceAtLeast(0f),
            timeSec           = (trip.timeSec   + deltaTime).coerceAtLeast(0L),
            blocks            = bucketBlocks(trip.rawSamples),
            startSocPct       = trip.startSocPct,
            currentSocPct     = latestSocPct,
            startTankL        = (trip.startFuelPct / 100f * tankCapacityL).coerceAtLeast(0f),
            currentTankL      = (latestFuelPct    / 100f * tankCapacityL).coerceAtLeast(0f),
            priceGasolinePerL = priceGasolinePerL,
            priceEnergyPerKwh = priceEnergyPerKwh,
        )
    }

    private fun bucketBlocks(samples: List<Triple<Float, Float, Float>>): List<BlockSample> {
        val totalDist = samples.sumOf { it.first.toDouble() }.toFloat()
        val windowStart = if (totalDist <= CHART_WINDOW_KM) 0f else totalDist - CHART_WINDOW_KM

        val bucketNet  = FloatArray(CHART_BLOCKS)
        val bucketFuel = FloatArray(CHART_BLOCKS)
        val bucketKm   = FloatArray(CHART_BLOCKS)

        var cumDist = 0f
        for ((km, net, fuel) in samples) {
            val midPoint = cumDist + km / 2f
            if (midPoint >= windowStart) {
                val posInWindow = midPoint - windowStart
                val idx = (posInWindow / CHART_BLOCK_KM).toInt().coerceIn(0, CHART_BLOCKS - 1)
                bucketNet[idx]  += net
                bucketFuel[idx] += fuel
                bucketKm[idx]   += km
            }
            cumDist += km
        }

        return List(CHART_BLOCKS) { i ->
            val blockKm = bucketKm[i].takeIf { it > 0f } ?: CHART_BLOCK_KM
            val netPer100km = bucketNet[i] / blockKm * 100f
            BlockSample(windowStart + i * CHART_BLOCK_KM, netPer100km, bucketFuel[i])
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
        val snapA   = snapshot(tripA)
        val snapB   = snapshot(tripB)
        val rolling = rollingSnapshot()
        val copy    = synchronized(lock) { listeners.toList() }
        copy.forEach { it(snapA, snapB, rolling) }
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

    // ── Persistence ───────────────────────────────────────────────────────────

    private fun loadFromPrefs() {
        tripA.fuelL     = prefs.getFloat(SharedPreferencesKeys.TRIP_A_FUEL_L, 0f)
        tripA.energyKwh = prefs.getFloat(SharedPreferencesKeys.TRIP_A_ENERGY_KWH, 0f)
        tripA.regenKwh  = prefs.getFloat(SharedPreferencesKeys.TRIP_A_REGEN_KWH, 0f)
        tripA.distKm    = prefs.getFloat(SharedPreferencesKeys.TRIP_A_DISTANCE_KM, 0f)
        tripA.timeSec   = prefs.getLong (SharedPreferencesKeys.TRIP_A_TIME_SEC, 0L)

        tripB.fuelL     = prefs.getFloat(SharedPreferencesKeys.TRIP_B_FUEL_L, 0f)
        tripB.energyKwh = prefs.getFloat(SharedPreferencesKeys.TRIP_B_ENERGY_KWH, 0f)
        tripB.regenKwh  = prefs.getFloat(SharedPreferencesKeys.TRIP_B_REGEN_KWH, 0f)
        tripB.distKm    = prefs.getFloat(SharedPreferencesKeys.TRIP_B_DISTANCE_KM, 0f)
        tripB.timeSec   = prefs.getLong (SharedPreferencesKeys.TRIP_B_TIME_SEC, 0L)

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

        val histJson = prefs.getString(SharedPreferencesKeys.TRIP_HISTORY_JSON, null)
        if (!histJson.isNullOrEmpty()) {
            try {
                val type = object : TypeToken<List<TripHistoryEntry>>() {}.type
                val loaded: List<TripHistoryEntry> = gson.fromJson(histJson, type)
                tripHistory.clear()
                tripHistory.addAll(loaded)
            } catch (_: Exception) {}
        }

        deserializeRawSamples(prefs.getString(SharedPreferencesKeys.TRIP_A_RAW_SAMPLES_JSON, null), tripA)
        deserializeRawSamples(prefs.getString(SharedPreferencesKeys.TRIP_B_RAW_SAMPLES_JSON, null), tripB)

        tripA.startSocPct       = prefs.getFloat(SharedPreferencesKeys.TRIP_A_START_SOC_PCT,  0f)
        tripA.startFuelPct      = prefs.getFloat(SharedPreferencesKeys.TRIP_A_START_FUEL_PCT, 0f)
        tripA.startSocCaptured  = tripA.startSocPct  > 0f
        tripA.startFuelCaptured = tripA.startFuelPct > 0f
        tripB.startSocPct       = prefs.getFloat(SharedPreferencesKeys.TRIP_B_START_SOC_PCT,  0f)
        tripB.startFuelPct      = prefs.getFloat(SharedPreferencesKeys.TRIP_B_START_FUEL_PCT, 0f)
        tripB.startSocCaptured  = tripB.startSocPct  > 0f
        tripB.startFuelCaptured = tripB.startFuelPct > 0f

        // Session baselines: used for crash-recovery in onSessionStart()
        tripA.sessStartEnergy = prefs.getFloat(SharedPreferencesKeys.TRIP_A_SESS_START_ENERGY, 0f)
        tripA.sessStartRegen  = prefs.getFloat(SharedPreferencesKeys.TRIP_A_SESS_START_REGEN,  0f)
        tripB.sessStartEnergy = prefs.getFloat(SharedPreferencesKeys.TRIP_B_SESS_START_ENERGY, 0f)
        tripB.sessStartRegen  = prefs.getFloat(SharedPreferencesKeys.TRIP_B_SESS_START_REGEN,  0f)
    }

    private fun saveToPrefs() {
        prefs.edit()
            .putFloat(SharedPreferencesKeys.TRIP_A_FUEL_L,      tripA.fuelL)
            .putFloat(SharedPreferencesKeys.TRIP_A_ENERGY_KWH,  tripA.energyKwh)
            .putFloat(SharedPreferencesKeys.TRIP_A_REGEN_KWH,   tripA.regenKwh)
            .putFloat(SharedPreferencesKeys.TRIP_A_DISTANCE_KM, tripA.distKm)
            .putLong (SharedPreferencesKeys.TRIP_A_TIME_SEC,    tripA.timeSec)
            .putFloat(SharedPreferencesKeys.TRIP_B_FUEL_L,      tripB.fuelL)
            .putFloat(SharedPreferencesKeys.TRIP_B_ENERGY_KWH,  tripB.energyKwh)
            .putFloat(SharedPreferencesKeys.TRIP_B_REGEN_KWH,   tripB.regenKwh)
            .putFloat(SharedPreferencesKeys.TRIP_B_DISTANCE_KM, tripB.distKm)
            .putLong (SharedPreferencesKeys.TRIP_B_TIME_SEC,    tripB.timeSec)
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
            .putString(SharedPreferencesKeys.TRIP_A_RAW_SAMPLES_JSON, serializeRawSamples(tripA.rawSamples))
            .putString(SharedPreferencesKeys.TRIP_B_RAW_SAMPLES_JSON, serializeRawSamples(tripB.rawSamples))
            .putFloat(SharedPreferencesKeys.TRIP_A_START_SOC_PCT,  tripA.startSocPct)
            .putFloat(SharedPreferencesKeys.TRIP_A_START_FUEL_PCT, tripA.startFuelPct)
            .putFloat(SharedPreferencesKeys.TRIP_B_START_SOC_PCT,  tripB.startSocPct)
            .putFloat(SharedPreferencesKeys.TRIP_B_START_FUEL_PCT, tripB.startFuelPct)
            // Session baselines — restored after crash/update to avoid double-counting energy
            .putFloat(SharedPreferencesKeys.TRIP_A_SESS_START_ENERGY, tripA.sessStartEnergy)
            .putFloat(SharedPreferencesKeys.TRIP_A_SESS_START_REGEN,  tripA.sessStartRegen)
            .putFloat(SharedPreferencesKeys.TRIP_B_SESS_START_ENERGY, tripB.sessStartEnergy)
            .putFloat(SharedPreferencesKeys.TRIP_B_SESS_START_REGEN,  tripB.sessStartRegen)
            .commit()   // síncrono — garante que os valores estão no disco antes de o processo morrer
    }

    private fun serializeRawSamples(samples: List<Triple<Float, Float, Float>>): String =
        gson.toJson(samples.map { listOf(it.first, it.second, it.third) })

    private fun deserializeRawSamples(json: String?, trip: TripAccum) {
        if (json.isNullOrEmpty()) return
        try {
            val type = object : TypeToken<List<List<Float>>>() {}.type
            val raw: List<List<Float>> = gson.fromJson(json, type)
            trip.rawSamples.clear()
            raw.mapNotNullTo(trip.rawSamples) { row ->
                if (row.size >= 3) Triple(row[0], row[1], row[2]) else null
            }
        } catch (_: Exception) {}
    }

    private fun saveHistory() {
        prefs.edit()
            .putString(SharedPreferencesKeys.TRIP_HISTORY_JSON, gson.toJson(tripHistory))
            .commit()
    }
}
