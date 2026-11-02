package br.com.redesurftank.ecotrip.managers

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.SystemClock
import br.com.redesurftank.ecotrip.models.CarConstants
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class CameraTelemetryPublisher(
    private val sink: Sink,
    private val active: () -> Boolean,
    private val monotonicMs: () -> Long = SystemClock::elapsedRealtime,
    private val wallClockMs: () -> Long = System::currentTimeMillis,
    private val failureReporter: (String?) -> Unit = {},
) {
    data class Sample(
        val monotonicMs: Long,
        val wallClockMs: Long,
        val speedKmh: Float,
        val motorPowerKw: Float,
        val validityFlags: Int,
    )

    fun interface Sink { fun send(sample: Sample): Boolean }

    private data class Value(val number: Float, val monotonicMs: Long)
    @Volatile private var speed: Value? = null
    @Volatile private var motorPower: Value? = null
    @Volatile private var lastPublishMs = Long.MIN_VALUE
    private var failureLogged = false

    fun onCanValue(key: String, rawValue: String) {
        val value = rawValue.trim().toFloatOrNull()?.takeIf { it.isFinite() } ?: return
        val sample = Value(value, monotonicMs())
        when (key) {
            SPEED_KEY -> speed = sample
            MOTOR_POWER_KEY -> motorPower = sample
        }
    }

    @Synchronized
    fun publishIfDue(): Boolean {
        if (!active()) return false
        val now = monotonicMs()
        if (lastPublishMs != Long.MIN_VALUE && now - lastPublishMs < PERIOD_MS) return false
        var flags = 0
        val currentSpeed = speed?.takeIf { now - it.monotonicMs in 0..SOURCE_MAX_AGE_MS }
        val currentPower = motorPower?.takeIf { now - it.monotonicMs in 0..SOURCE_MAX_AGE_MS }
        if (currentSpeed != null) flags = flags or VALID_SPEED
        if (currentPower != null) flags = flags or VALID_MOTOR_POWER
        if (flags == 0) return false
        lastPublishMs = now
        return try {
            val sent = sink.send(Sample(
                now, wallClockMs(), currentSpeed?.number ?: 0f,
                currentPower?.number ?: 0f, flags,
            ))
            if (sent) failureLogged = false
            sent
        } catch (failure: Exception) {
            if (!failureLogged) {
                failureLogged = true
                failureReporter("telemetria: ${failure.message}")
            }
            false
        }
    }

    private class AndroidSink(private val context: Context) : Sink {
        override fun send(sample: Sample): Boolean {
            context.packageManager.getPackageInfo(CameraVideoContract.PACKAGE, 0)
            val intent = Intent(CameraVideoContract.ACTION_TELEMETRY_SAMPLE).apply {
                component = ComponentName(CameraVideoContract.PACKAGE, CameraVideoContract.SERVICE)
                putExtra(CameraVideoContract.EXTRA_MONOTONIC_MS, sample.monotonicMs)
                putExtra(CameraVideoContract.EXTRA_WALL_CLOCK_MS, sample.wallClockMs)
                putExtra(CameraVideoContract.EXTRA_SPEED_KMH, sample.speedKmh)
                putExtra(CameraVideoContract.EXTRA_MOTOR_POWER_KW, sample.motorPowerKw)
                putExtra(CameraVideoContract.EXTRA_VALIDITY_FLAGS, sample.validityFlags)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(intent)
            else context.startService(intent)
            return true
        }
    }

    companion object {
        const val SPEED_KEY = "car.basic.vehicle_speed"
        const val MOTOR_POWER_KEY = "car.ev_info.motor_power"
        private const val TAG = "CameraTelemetry"
        private const val PERIOD_MS = 200L
        private const val SOURCE_MAX_AGE_MS = 2_000L
        private const val VALID_SPEED = 1
        private const val VALID_MOTOR_POWER = 1 shl 1

        private data class Runtime(
            val publisher: CameraTelemetryPublisher,
            val listener: DataListener,
            val executor: java.util.concurrent.ScheduledExecutorService,
        )
        @Volatile private var runtime: Runtime? = null

        fun start(context: Context) {
            if (runtime != null) return
            val app = context.applicationContext
            val publisher = CameraTelemetryPublisher(
                AndroidSink(app), TripVideoBridge::isRecordingOrLiveActive,
                failureReporter = TripVideoBridge::noteUnavailable,
            )
            val listener: DataListener = { key, value ->
                if (key == CarConstants.CAR_BASIC_VEHICLE_SPEED.value ||
                    key == CarConstants.CAR_EV_INFO_MOTOR_POWER.value) {
                    publisher.onCanValue(key, value)
                }
            }
            val executor = Executors.newSingleThreadScheduledExecutor { runnable ->
                Thread(runnable, "camera-telemetry").apply { isDaemon = true }
            }
            CarDataManager.getInstance().addListener(listener)
            executor.scheduleAtFixedRate(
                { runCatching { publisher.publishIfDue() } },
                PERIOD_MS, PERIOD_MS, TimeUnit.MILLISECONDS,
            )
            runtime = Runtime(publisher, listener, executor)
        }

        fun stop() {
            val current = runtime ?: return
            runtime = null
            runCatching { CarDataManager.getInstance().removeListener(current.listener) }
            current.executor.shutdownNow()
        }
    }
}
