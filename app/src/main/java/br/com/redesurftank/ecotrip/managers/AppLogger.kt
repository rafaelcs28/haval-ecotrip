package br.com.redesurftank.ecotrip.managers

import android.content.Context
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

    // ── Persistência mínima: WARN e ERROR em disco ────────────────────────────
    //
    // O buffer é de 300 linhas e some com o app. O problema é que a receita de
    // recuperação de quase tudo aqui é REINICIAR — e reiniciar apaga justamente a
    // prova do que quebrou. Em 18/09 o Shizuku caiu no meio de uma viagem; quando
    // fui apurar o motivo, não havia mais nada pra ler em lugar nenhum.
    //
    // Só WARN e ERROR: são ~150 das 467 chamadas e é onde mora a causa. INFO em
    // disco viraria escrita constante num head unit que já vive no limite.
    //
    // Append num arquivo só, aparado no boot pra não crescer sem teto. A gravação
    // é fire-and-forget e engole exceção: log que derruba o app é pior que log
    // nenhum.
    private const val ARQ = "eventos.log"
    private const val MAX_BYTES = 256 * 1024
    @Volatile private var dir: java.io.File? = null

    /// Liga a persistência. Chamar no boot do app, antes de tudo que loga.
    fun initDisco(ctx: Context) {
        try {
            val d = java.io.File(ctx.filesDir, "logs").apply { mkdirs() }
            dir = d
            val f = java.io.File(d, ARQ)
            // Apara no boot, não a cada escrita: medir tamanho toda linha é custo
            // por linha; uma vez por boot é custo por boot.
            if (f.exists() && f.length() > MAX_BYTES) {
                val manter = f.readText().takeLast(MAX_BYTES / 2)
                f.writeText(manter)
            }
            grava("---- boot ----")
        } catch (_: Exception) { dir = null }
    }

    /// Últimas [linhas] do arquivo — pra `cmd/dumplog` alcançar o que veio ANTES
    /// do reinício, que é o que o buffer em memória nunca teve.
    fun doDisco(linhas: Int = 120): String = try {
        val f = dir?.let { java.io.File(it, ARQ) }
        if (f != null && f.exists()) f.readLines().takeLast(linhas).joinToString("\n") else ""
    } catch (_: Exception) { "" }

    private fun grava(linha: String) {
        val d = dir ?: return
        try {
            java.io.File(d, ARQ).appendText(
                SimpleDateFormat("dd/MM HH:mm:ss", Locale.getDefault()).format(Date())
                    + " " + linha + "\n")
        } catch (_: Exception) {}
    }

    private fun add(level: LogLevel, tag: String, msg: String) {
        val entry = LogEntry(level, tag, msg, fmt.format(Date()))
        val current = _entries.value
        _entries.value = if (current.size >= MAX_ENTRIES) {
            current.drop(1) + entry
        } else {
            current + entry
        }
        if (level == LogLevel.WARN || level == LogLevel.ERROR) grava("$level $tag $msg")
    }
}
