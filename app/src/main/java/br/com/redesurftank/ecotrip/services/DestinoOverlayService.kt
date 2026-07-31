package br.com.redesurftank.ecotrip.services

import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.IBinder
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.TextView
import br.com.redesurftank.ecotrip.MainActivity
import br.com.redesurftank.ecotrip.managers.AppLogger
import br.com.redesurftank.ecotrip.managers.MqttManager
import kotlin.math.abs

/// Botão de destino desenhado POR CIMA de qualquer app do head unit — inclusive
/// o de espelhamento, então aparece sobre o Waze.
///
/// Um botão dentro do nosso app não resolve: quando você está com o espelhamento
/// na frente, nosso app está em background. Overlay de sistema é o único jeito
/// de ter o atalho sempre alcançável sem trocar de app.
///
/// Arrastável e com a posição lembrada, porque o lugar bom depende de onde o
/// app de espelhamento põe os controles dele — e isso varia por modelo.
class DestinoOverlayService : Service() {

    private var wm: WindowManager? = null
    private var botao: View? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        tentar()
    }

    /// cmd/overlay chama startService num serviço que já está rodando, e aí o
    /// Android entrega em onStartCommand — NÃO em onCreate. Sem isto o comando de
    /// retentativa não fazia absolutamente nada, e eu ficava lendo um retained
    /// antigo achando que era a tentativa nova.
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (botao == null) { tentar(); return START_STICKY }
        // Já no ar: RECRIA em vez de só relatar. "ja_no_ar" não dizia nada de útil —
        // e é justamente quando o botão existe mas não é visto que preciso da
        // medição. Remover e readicionar força um layout novo e um relatório fresco.
        relatar("recriando")
        runCatching { botao?.let { wm?.removeView(it) } }
        botao = null
        tentar()
        return START_STICKY
    }

    /// Publica o diagnóstico em debug/overlay. O AppLogger tem buffer de 300 e o
    /// dumplog entrega 80 — o que acontece no arranque do serviço rola pra fora
    /// antes de dar tempo de pedir. Num tópico o estado fica disponível a
    /// qualquer momento, sem depender do buffer.
    private fun relatar(etapa: String, detalhe: String = "") {
        val msg = "perm=${temPermissao(this)} etapa=$etapa" + if (detalhe.isEmpty()) "" else " $detalhe"
        AppLogger.i(TAG, msg)
        runCatching { MqttManager.getInstance().publicarDebugOverlay(msg) }
    }

    /// Separado do onCreate pra poder ser reexecutado por cmd/overlay sem reiniciar
    /// o app — tentar de novo custava um ciclo inteiro de release e despertar.
    fun tentar() {
        if (!temPermissao(this)) {
            // O head unit do Haval não expõe a tela de Ajustes de "desenhar sobre
            // outros apps" (verificado no carro em 31/07), e SYSTEM_ALERT_WINDOW é
            // appop — `pm grant` não serve. Sem este caminho o botão flutuante
            // seria impossível nesse hardware.
            relatar("sem_permissao_tentando_shizuku")
            val ok = br.com.redesurftank.ecotrip.managers.ShizukuPerms.concederOverlay(this)
            relatar(if (ok) "shizuku_liberou" else "shizuku_falhou")
            if (!ok) { stopSelf(); return }
        }
        runCatching { mostrar(); relatar("no_ar") }.onFailure {
            relatar("addview_falhou", it.message ?: it.javaClass.simpleName)
            stopSelf()
        }
    }

    private fun mostrar() {
        val ctx: Context = this
        val prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        val tv = TextView(ctx).apply {
            text = "🧭"
            textSize = 26f
            setTextColor(Color.parseColor("#06080C"))
            gravity = Gravity.CENTER
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(Color.parseColor("#00E5CC"))
                setStroke(3, Color.parseColor("#0F1520"))
            }
            // 64dp de alvo: é pra acertar dirigindo, não pra ser discreto.
            val d = (64 * resources.displayMetrics.density).toInt()
            minWidth = d; minHeight = d
        }

        // TYPE_APPLICATION_OVERLAY só existe do Oreo pra cima; o head unit é
        // Android 9, mas mantenho o fallback porque a família de firmware varia.
        val tipo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        else @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE

        val lp = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            tipo,
            // NOT_FOCUSABLE: o overlay não rouba o teclado nem o foco do app de
            // baixo. Sem isso, o espelhamento perde o toque enquanto o botão existe.
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            android.graphics.PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = prefs.getInt(K_X, 24)
            y = prefs.getInt(K_Y, 220)
        }

        // Arrastar move; toque curto abre. O limiar separa os dois: sem ele, um
        // toque com tremor de estrada viraria arrasto e nada abriria.
        var baseX = 0; var baseY = 0; var toqueX = 0f; var toqueY = 0f; var arrastou = false
        tv.setOnTouchListener { _, ev ->
            when (ev.action) {
                MotionEvent.ACTION_DOWN -> {
                    baseX = lp.x; baseY = lp.y; toqueX = ev.rawX; toqueY = ev.rawY; arrastou = false
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = (ev.rawX - toqueX).toInt(); val dy = (ev.rawY - toqueY).toInt()
                    if (abs(dx) > 12 || abs(dy) > 12) arrastou = true
                    if (arrastou) {
                        lp.x = baseX + dx; lp.y = baseY + dy
                        runCatching { wm?.updateViewLayout(tv, lp) }
                    }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    if (arrastou) {
                        prefs.edit().putInt(K_X, lp.x).putInt(K_Y, lp.y).apply()
                    } else {
                        mostrarPainel()
                    }
                    true
                }
                else -> false
            }
        }

        wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        wm?.addView(tv, lp)
        botao = tv
        // 'no_ar' não provou nada: o addView passou e o botão não aparecia. Mede a
        // view DEPOIS do layout e reporta — tamanho 0, coordenada fora da tela ou
        // view não anexada dão sintomas idênticos ("não vejo nada") e correções
        // diferentes. Sem isto o diagnóstico vira chute.
        tv.post {
            val m = resources.displayMetrics
            relatar("medido",
                "pos=${lp.x},${lp.y} tam=${tv.width}x${tv.height} " +
                "anexada=${tv.isAttachedToWindow} vis=${tv.visibility} " +
                "tela=${m.widthPixels}x${m.heightPixels} dens=${m.density} tipo=$tipo")
            // Fora da tela (posição salva de outra resolução, por exemplo) → recentra
            // em vez de deixar o botão inalcançável pra sempre.
            if (lp.x > m.widthPixels - 40 || lp.y > m.heightPixels - 40 || lp.x < -40 || lp.y < -40) {
                lp.x = m.widthPixels / 2; lp.y = m.heightPixels / 2
                runCatching { wm?.updateViewLayout(tv, lp) }
                prefs.edit().putInt(K_X, lp.x).putInt(K_Y, lp.y).apply()
                relatar("recentrado", "pos=${lp.x},${lp.y}")
            }
        }
        AppLogger.i(TAG, "overlay de destino no ar (x=${lp.x} y=${lp.y})")
    }

    /// Painel de favoritos POR CIMA do app atual — o ponto todo é não sair do
    /// Waze. Views nativas em vez de Compose porque aqui não há Activity nem
    /// ViewTree pra hospedar composição; a lista é curta, então não perde nada.
    ///
    /// Só favoritos: buscar exige teclado, e pra digitar o overlay teria que
    /// aceitar foco — o que rouba o teclado do app de baixo. Busca abre o app.
    private var painel: View? = null

    private fun mostrarPainel() {
        if (painel != null) { fecharPainel(); return }
        val favs = lerFavoritos()
        val dp: (Int) -> Int = { v -> (v * resources.displayMetrics.density).toInt() }

        val col = android.widget.LinearLayout(this).apply {
            orientation = android.widget.LinearLayout.VERTICAL
            setPadding(dp(14), dp(14), dp(14), dp(14))
            background = GradientDrawable().apply {
                cornerRadius = dp(18).toFloat()
                setColor(Color.parseColor("#F206080C"))
                setStroke(dp(1), Color.parseColor("#00E5CC"))
            }
        }
        col.addView(TextView(this).apply {
            text = "Para onde vamos?"
            setTextColor(Color.parseColor("#EEF4FF")); textSize = 19f
            setTypeface(null, android.graphics.Typeface.BOLD)
            setPadding(0, 0, 0, dp(10))
        })

        if (favs.isEmpty()) {
            col.addView(TextView(this).apply {
                text = "Sem favoritos ainda."
                setTextColor(Color.parseColor("#5B7394")); textSize = 15f
            })
        }
        for (f in favs.take(6)) {
            col.addView(TextView(this).apply {
                val km = f.optDouble("distKm").let { if (it.isNaN()) "" else "   ${"%.1f".format(it)} km" }
                text = f.optString("name") + km
                setTextColor(Color.parseColor("#EEF4FF")); textSize = 17f
                setTypeface(null, android.graphics.Typeface.BOLD)
                setPadding(dp(14), dp(14), dp(14), dp(14))
                background = GradientDrawable().apply {
                    cornerRadius = dp(12).toFloat(); setColor(Color.parseColor("#141A24"))
                }
                setOnClickListener {
                    MqttManager.getInstance().publishNavTo(
                        f.optDouble("lat"), f.optDouble("lng"), f.optString("name"), "waze")
                    text = "✓ " + f.optString("name")
                    setTextColor(Color.parseColor("#39FF88"))
                    postDelayed({ fecharPainel() }, 900)
                }
            }, android.widget.LinearLayout.LayoutParams(
                dp(300), android.widget.LinearLayout.LayoutParams.WRAP_CONTENT).apply {
                bottomMargin = dp(8)
            })
        }

        col.addView(TextView(this).apply {
            text = "🔍  Buscar outro lugar…"
            setTextColor(Color.parseColor("#00E5CC")); textSize = 16f
            setPadding(dp(14), dp(14), dp(14), dp(14))
            setOnClickListener { fecharPainel(); abrirTelaDestino() }
        })

        val lp = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT, WindowManager.LayoutParams.WRAP_CONTENT,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            else @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE,
            // NOT_FOCUSABLE aqui também: nada neste painel digita, então não há
            // motivo pra tirar o teclado do app de baixo.
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            android.graphics.PixelFormat.TRANSLUCENT,
        ).apply { gravity = Gravity.CENTER }

        runCatching {
            wm?.addView(col, lp); painel = col
            MqttManager.getInstance().pedirFavoritos()   // atualiza pra próxima abertura
        }.onFailure { AppLogger.w(TAG, "painel falhou: ${it.message}") }
    }

    private fun fecharPainel() {
        runCatching { painel?.let { wm?.removeView(it) } }
        painel = null
    }

    private fun lerFavoritos(): List<org.json.JSONObject> {
        val raw = MqttManager.getInstance().navFavoritosJson ?: return emptyList()
        return runCatching {
            val arr = org.json.JSONObject(raw).optJSONArray("items") ?: return emptyList()
            (0 until arr.length()).mapNotNull { arr.optJSONObject(it) }
                .filter { it.optString("name").isNotBlank() }
        }.getOrDefault(emptyList())
    }

    /// Traz o app pra frente já pedindo a tela de destino. REORDER_TO_FRONT em vez
    /// de recriar: se o app já está em memória, recriar perderia o estado dele.
    private fun abrirTelaDestino() {
        runCatching {
            startActivity(Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
                putExtra(EXTRA_ABRIR_DESTINO, true)
            })
        }.onFailure { AppLogger.w(TAG, "não abriu a tela: ${it.message}") }
    }

    override fun onDestroy() {
        fecharPainel()
        runCatching { botao?.let { wm?.removeView(it) } }
        botao = null
        super.onDestroy()
    }

    companion object {
        private const val TAG = "DestinoOverlay"
        private const val PREFS = "destino_overlay"
        private const val K_X = "x"
        private const val K_Y = "y"
        const val EXTRA_ABRIR_DESTINO = "abrir_destino"

        fun temPermissao(ctx: Context): Boolean =
            Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(ctx)

        fun ligar(ctx: Context) {
            if (!temPermissao(ctx)) { AppLogger.w(TAG, "sem permissão de overlay"); return }
            runCatching { ctx.startService(Intent(ctx, DestinoOverlayService::class.java)) }
        }

        fun desligar(ctx: Context) {
            runCatching { ctx.stopService(Intent(ctx, DestinoOverlayService::class.java)) }
        }

        /// Abre a tela do sistema pra conceder "desenhar sobre outros apps".
        fun pedirPermissao(ctx: Context) {
            runCatching {
                ctx.startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                    android.net.Uri.parse("package:" + ctx.packageName))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }
        }
    }
}
