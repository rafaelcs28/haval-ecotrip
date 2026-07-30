package br.com.redesurftank.ecotrip.managers

import android.util.Log
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

enum class LogLevel { DEBUG, INFO, WARN, ERROR }

data class LogEntry(val level: LogLevel, val tag: String, val msg: String, val time: String)

object AppLogger {

    private const val MAX_ENTRIES = 300
    private val fmt = SimpleDateFormat("HH:mm:ss", Locale.getDefault())

    private val _entries = MutableStateFlow<List<LogEntry>>(emptyList())
    val entries: StateFlow<List<LogEntry>> = _entries

    /// O logcat do head unit é COLETADO E ENVIADO pra nuvem GWM pelo sistema do
    /// carro, e isso consome o pacote de dados — 2 GB em menos de um mês. Espelhar
    /// cada linha nossa ali fazia o app pagar esse custo: 467 pontos de log, com o
    /// MqttManager publicando a cada 5-30s.
    ///
    /// Desligado por padrão. O buffer em memória continua igual, então a LogScreen
    /// e o cmd/dumplog não perdem NADA — só o carro deixa de ter o que mandar.
    /// Reativável em runtime por `cmd/logcat 1` quando precisar depurar por adb.
    @Volatile var logcatEnabled: Boolean = false

    fun d(tag: String, msg: String) { add(LogLevel.DEBUG, tag, msg); if (logcatEnabled) Log.d(tag, msg) }
    fun i(tag: String, msg: String) { add(LogLevel.INFO,  tag, msg); if (logcatEnabled) Log.i(tag, msg) }
    fun w(tag: String, msg: String) { add(LogLevel.WARN,  tag, msg); if (logcatEnabled) Log.w(tag, msg) }
    fun e(tag: String, msg: String) { add(LogLevel.ERROR, tag, msg); if (logcatEnabled) Log.e(tag, msg) }

    /// Overload com throwable: os Log.e(TAG, msg, e) migrados precisam dele. A
    /// stacktrace entra no buffer, então continua visível no dumplog.
    fun e(tag: String, msg: String, t: Throwable) {
        add(LogLevel.ERROR, tag, "$msg: ${t::class.simpleName}: ${t.message}")
        if (logcatEnabled) Log.e(tag, msg, t)
    }
    fun w(tag: String, msg: String, t: Throwable) {
        add(LogLevel.WARN, tag, "$msg: ${t::class.simpleName}: ${t.message}")
        if (logcatEnabled) Log.w(tag, msg, t)
    }

    fun clear() { _entries.value = emptyList() }

    private fun add(level: LogLevel, tag: String, msg: String) {
        val entry = LogEntry(level, tag, msg, fmt.format(Date()))
        val current = _entries.value
        _entries.value = if (current.size >= MAX_ENTRIES) {
            current.drop(1) + entry
        } else {
            current + entry
        }
    }
}
