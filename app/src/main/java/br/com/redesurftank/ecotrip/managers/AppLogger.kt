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

    fun d(tag: String, msg: String) { add(LogLevel.DEBUG, tag, msg); Log.d(tag, msg) }
    fun i(tag: String, msg: String) { add(LogLevel.INFO,  tag, msg); Log.i(tag, msg) }
    fun w(tag: String, msg: String) { add(LogLevel.WARN,  tag, msg); Log.w(tag, msg) }
    fun e(tag: String, msg: String) { add(LogLevel.ERROR, tag, msg); Log.e(tag, msg) }

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
