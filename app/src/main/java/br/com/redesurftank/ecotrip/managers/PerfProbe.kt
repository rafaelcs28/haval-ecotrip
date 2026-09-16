package br.com.redesurftank.ecotrip.managers

import android.content.Context
import android.os.Debug
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/// Medidor de CPU e RAM do PRÓPRIO processo, ligado sob demanda pelo app iOS.
///
/// Existe pra responder com dado uma pergunta de arquitetura: vale mover a leitura do
/// CAN pro Impulse "por performance"? Sem medição, isso é palpite — e trocar um
/// sistema que funciona por um acoplamento novo sem evidência é o tipo de otimização
/// que sai caro.
///
/// Fica DESLIGADO por padrão: um medidor que roda sempre é ele mesmo um custo.
object PerfProbe {
    private const val TAG = "PerfProbe"
    private const val INTERVALO_S = 2L

    private val exec = Executors.newSingleThreadScheduledExecutor { r ->
        Thread(r, "perf-probe").apply { isDaemon = true }
    }
    private var tarefa: ScheduledFuture<*>? = null
    private var ctx: Context? = null

    @Volatile var ativo = false; private set
    private var iniciouMs = 0L
    private var amostras = 0

    /// utime+stime do processo, em ticks, na leitura anterior — o CPU% só existe como
    /// DELTA entre duas leituras.
    private var ticksAntes = -1L
    private var ticksAntesMs = 0L
    /// Jiffies do SISTEMA na leitura anterior (total, idle) — mesmo princípio do
    /// processo: CPU global só existe como delta.
    private var sysTotalAntes = -1L
    private var sysIdleAntes = 0L

    fun start(context: Context) { ctx = context.applicationContext }

    fun ligar() {
        if (ativo) return
        ativo = true
        iniciouMs = System.currentTimeMillis()
        amostras = 0
        ticksAntes = -1L
        AppLogger.i(TAG, "medição ligada (intervalo ${INTERVALO_S}s)")
        tarefa = exec.scheduleWithFixedDelay({ coletar() }, 0, INTERVALO_S, TimeUnit.SECONDS)
    }

    fun desligar() {
        if (!ativo) return
        ativo = false
        tarefa?.cancel(false); tarefa = null
        AppLogger.i(TAG, "medição desligada — $amostras amostra(s)")
        // Marca o fim pro bridge fechar a sessão mesmo sem mais amostras.
        MqttManager.getInstance().publicarPerf(
            JSONObject().put("fim", true).put("amostras", amostras)
                .put("duracaoS", (System.currentTimeMillis() - iniciouMs) / 1000).toString())
    }

    private fun coletar() {
        try {
            val o = JSONObject()
            o.put("ts", System.currentTimeMillis())

            // ── CPU: delta de jiffies do próprio processo / tempo decorrido ──
            // /proc/self/stat é legível mesmo com as restrições do Android 8+ (só o
            // /proc de OUTROS processos é bloqueado). Campos 14 e 15 = utime, stime.
            val campos = File("/proc/self/stat").readText().split(" ")
            val ticks = campos[13].toLong() + campos[14].toLong()
            val agora = System.currentTimeMillis()
            if (ticksAntes >= 0) {
                val dtMs = agora - ticksAntesMs
                if (dtMs > 0) {
                    // 100 ticks/s é o CLK_TCK de todo Android; multiplico por 10 pra
                    // converter ticks→ms. Divido pelos núcleos pra ter % de UM core
                    // comparável ("120%" num octa-core não diz nada sozinho).
                    val cpuMs = (ticks - ticksAntes) * 10.0
                    val cores = Runtime.getRuntime().availableProcessors().coerceAtLeast(1)
                    o.put("cpuPct", ((cpuMs / dtMs) * 100.0 / cores).coerceIn(0.0, 100.0))
                }
            }
            ticksAntes = ticks
            ticksAntesMs = agora

            // ── RAM: PSS é a métrica honesta (memória proporcional, sem contar
            // bibliotecas compartilhadas várias vezes). Debug.getPss é mais barato
            // que getMemoryInfo e suficiente pra acompanhar tendência.
            val mi = Debug.MemoryInfo()
            Debug.getMemoryInfo(mi)
            o.put("pssMb", mi.totalPss / 1024.0)
            o.put("heapMb", (Runtime.getRuntime().totalMemory() -
                             Runtime.getRuntime().freeMemory()) / 1048576.0)
            o.put("threads", Thread.activeCount())

            // ── Android INTEIRO ──────────────────────────────────────────────────
            // Sem isto os números do processo não têm régua: 25% de CPU é muito ou
            // pouco? Depende de quanto o head unit está usando no total. E é o que
            // responde se o gargalo somos nós ou o aparelho.
            //
            // /proc/stat e /proc/meminfo seguem legíveis no Android 8+ (a restrição
            // pega /proc de OUTROS processos, não os arquivos globais).
            runCatching {
                val cpuLinha = File("/proc/stat").useLines { it.first() }.split(Regex("\\s+"))
                // user nice system idle iowait irq softirq steal
                val vals = cpuLinha.drop(1).mapNotNull { it.toLongOrNull() }
                if (vals.size >= 4) {
                    val total = vals.sum()
                    val idle = vals[3] + (vals.getOrNull(4) ?: 0L)   // idle + iowait
                    if (sysTotalAntes >= 0) {
                        val dTotal = total - sysTotalAntes
                        val dIdle = idle - sysIdleAntes
                        if (dTotal > 0) {
                            o.put("sysCpuPct", ((dTotal - dIdle) * 100.0 / dTotal).coerceIn(0.0, 100.0))
                        }
                    }
                    sysTotalAntes = total; sysIdleAntes = idle
                }
            }
            runCatching {
                val am = ctx?.getSystemService(android.app.ActivityManager::class.java)
                val mi = android.app.ActivityManager.MemoryInfo()
                am?.getMemoryInfo(mi)
                val totalMb = mi.totalMem / 1048576.0
                val dispMb = mi.availMem / 1048576.0
                o.put("ramTotalMb", totalMb)
                o.put("ramUsadaMb", totalMb - dispMb)
                o.put("ramLivreMb", dispMb)
                // lowMemory é o sinal de que o sistema está prestes a matar processos —
                // exatamente o que vinha derrubando o app no meio de viagem/recarga.
                o.put("lowMemory", mi.lowMemory)
            }
            runCatching {
                val la = File("/proc/loadavg").readText().split(" ")
                o.put("load1", la[0].toDouble())
            }
            // ── Impulse (vc7284+): resourceUsage ────────────────────────────────
            // Só a cada 3ª amostra (~6s): o call() BLOQUEIA ~intervalMs porque o CPU%
            // exige duas leituras de /proc/stat espaçadas. A 2s isso prenderia a
            // thread um quarto do tempo — o medidor viraria parte do problema.
            //
            // O que interessa de verdade é `appRamMb`: o footprint do IMPULSE, que eu
            // não tenho como medir (no Android 8+ um app não lê o /proc do outro).
            // Com ele dá pra responder se mover a leitura do CAN pra lá economiza no
            // total ou só transfere o custo de lugar.
            if (amostras % 3 == 0) {
                runCatching {
                    val extras = android.os.Bundle().apply { putLong("intervalMs", 500L) }
                    val b = ctx?.contentResolver?.call(
                        android.net.Uri.parse("content://br.com.redesurftank.havalshisuku.status/connectivity"),
                        "resourceUsage", null, extras)
                    if (b != null && b.getBoolean("ok")) {
                        // cpuPct pode vir ausente (o contrato avisa) — não inventa 0.
                        if (b.containsKey("cpuPct")) o.put("impCpuPct", b.getInt("cpuPct"))
                        if (b.containsKey("ramPct")) o.put("impRamPct", b.getInt("ramPct"))
                        if (b.containsKey("appRamMb")) o.put("impulseRamMb", b.getInt("appRamMb"))
                    }
                }.onFailure {
                    // Impulse ausente ou versão < vc7284: segue com a leitura própria.
                    AppLogger.i(TAG, "resourceUsage indisponível: ${it.message}")
                }
            }

            // ── Tabela por processo (Impulse vc7285+) ────────────────────────────
            // A cada 15ª amostra = ~30s. Não a cada 6s como o resourceUsage: a chamada
            // bloqueia ~intervalMs e o contrato recomenda 30-60s — pra "quem consome",
            // tendência importa mais que resolução fina, e o head unit já está com
            // load ~16.
            if (amostras % 15 == 0) coletarProcessos()

            o.put("versao", ctx?.let {
                runCatching { it.packageManager.getPackageInfo(it.packageName, 0).versionName }.getOrNull()
            } ?: "?")

            amostras++
            MqttManager.getInstance().publicarPerf(o.toString())
        } catch (e: Exception) {
            AppLogger.w(TAG, "coleta falhou: ${e.message}")
        }
    }
    /// Pede ao Impulse a quebra por processo e publica num tópico próprio.
    ///
    /// Vai separado da amostra normal porque é uma LISTA e chega 15× menos vezes —
    /// embutir infla toda amostra com um campo quase sempre ausente.
    private fun coletarProcessos() {
        val c = ctx ?: return
        runCatching {
            val extras = android.os.Bundle().apply {
                putInt("topN", 25)
                putString("orderBy", "rss")
                putLong("intervalMs", 500L)
                putBoolean("includeSystem", false)   // 27 apps no carro; system explode pra ~750
            }
            val b = c.contentResolver.call(
                android.net.Uri.parse("content://br.com.redesurftank.havalshisuku.status/connectivity"),
                "processUsage", null, extras) ?: return
            if (!b.getBoolean("ok")) return

            val out = JSONObject()
            out.put("ts", b.getLong("sampledAtMs"))
            out.put("totalProcs", b.getInt("totalProcs"))
            out.put("nCores", b.getInt("nCores"))
            // Repasso memKind e cpuScale COMO VIERAM. O contrato é explícito: é RSS
            // (não PSS) e o cpuPct é % do TOTAL do sistema — escala diferente do
            // cpuPct que eu meço do EcoTrip, que é % de UM núcleo. Rotular errado
            // produziria uma tabela onde 10% e 1,2% parecem comparáveis e não são.
            out.put("memKind", b.getString("memKind") ?: "rss")
            out.put("cpuScale", b.getString("cpuScale") ?: "system_total")
            out.put("procs", org.json.JSONArray(b.getStringArrayList("processes").orEmpty()))
            MqttManager.getInstance().publicarPerfProcs(out.toString())
        }.onFailure {
            AppLogger.i(TAG, "processUsage indisponível: ${it.message}")
        }
    }


}
