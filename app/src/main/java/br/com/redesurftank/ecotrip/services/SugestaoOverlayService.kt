package br.com.redesurftank.ecotrip.services

import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import br.com.redesurftank.ecotrip.managers.AppLogger
import br.com.redesurftank.ecotrip.managers.MqttManager

/**
 * Popup de sugestão de destino, em janela OVERLAY própria.
 *
 * Serviço SEPARADO do `DestinoOverlayService` de propósito: aquele é o botão flutuante,
 * que o dono desligou e não deve voltar por tabela. Este não lê nem escreve a
 * preferência `OVERLAY_DESTINO`, não inicia aquele serviço e não compartilha janela —
 * ligar um nunca liga o outro.
 *
 * Overlay em vez de Activity porque o dono usa Android Auto projetado: uma Activity
 * roubaria a tela da projeção, que é justamente a reclamação que gerou a v6.212.
 * `FLAG_NOT_FOCUSABLE` mantém o app de baixo recebendo toque normalmente; só a área do
 * painel captura.
 */
class SugestaoOverlayService : Service() {
    private var wm: WindowManager? = null
    private var painel: View? = null
    private val handler = Handler(Looper.getMainLooper())
    private var sumirRunnable: Runnable? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val id = intent?.getStringExtra(EXTRA_ID) ?: ""
        val nome = intent?.getStringExtra(EXTRA_NOME) ?: ""
        val hhmm = intent?.getStringExtra(EXTRA_HHMM) ?: ""
        if (id.isBlank() || nome.isBlank()) { stopSelf(); return START_NOT_STICKY }
        if (!temPermissao(this)) {
            AppLogger.w(TAG, "sem permissão de overlay — sugestão não exibida")
            stopSelf(); return START_NOT_STICKY
        }
        mostrarPainel(id, nome, hhmm)
        // START_NOT_STICKY: convite pontual. Com STICKY o Android reergueria o serviço
        // e o painel voltaria sozinho sem compromisso nenhum na tela — foi o vício que
        // fazia o botão flutuante reaparecer a cada partida.
        return START_NOT_STICKY
    }

    private fun mostrarPainel(id: String, nome: String, hhmm: String) {
        remover()
        val ctx = this
        val dp = { v: Int -> (v * resources.displayMetrics.density).toInt() }

        val titulo = TextView(ctx).apply {
            text = if (hhmm.isNotBlank()) "Compromisso às $hhmm" else "Próximo compromisso"
            setTextColor(Color.parseColor("#B0BEC5")); textSize = 12f
        }
        val destino = TextView(ctx).apply {
            text = nome
            setTextColor(Color.WHITE); textSize = 17f
            setPadding(0, dp(2), 0, dp(10))
        }
        val definir = Button(ctx).apply {
            text = "Definir destino"
            setTextColor(Color.parseColor("#04252B"))
            background = GradientDrawable().apply {
                cornerRadius = dp(10).toFloat(); setColor(Color.parseColor("#22D3EE"))
            }
            setOnClickListener {
                MqttManager.getInstance().publicarSugestaoResposta(id, true)
                AppLogger.i(TAG, "sugestão ACEITA: $nome")
                pararTudo()
            }
        }
        val agoraNao = Button(ctx).apply {
            text = "Agora não"
            setTextColor(Color.parseColor("#B0BEC5"))
            background = GradientDrawable().apply {
                cornerRadius = dp(10).toFloat()
                setColor(Color.parseColor("#22FFFFFF"))
                setStroke(2, Color.parseColor("#44FFFFFF"))
            }
            setOnClickListener {
                MqttManager.getInstance().publicarSugestaoResposta(id, false)
                AppLogger.i(TAG, "sugestão recusada: $nome")
                pararTudo()
            }
        }
        val botoes = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            addView(definir, LinearLayout.LayoutParams(0, dp(46), 1f))
            addView(View(ctx), LinearLayout.LayoutParams(dp(8), 1))
            addView(agoraNao, LinearLayout.LayoutParams(0, dp(46), 1f))
        }
        val caixa = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(12), dp(16), dp(14))
            background = GradientDrawable().apply {
                cornerRadius = dp(16).toFloat()
                setColor(Color.parseColor("#F0161821"))
                setStroke(2, Color.parseColor("#3322D3EE"))
            }
            addView(titulo); addView(destino); addView(botoes)
        }

        val tipo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        else @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE

        val lp = WindowManager.LayoutParams(
            dp(360), WindowManager.LayoutParams.WRAP_CONTENT, tipo,
            // NOT_FOCUSABLE mantém o app de baixo com o toque; os botões daqui seguem
            // clicáveis (foco só afeta teclado). Sem isso a projeção do AA perderia
            // o toque enquanto o painel existisse.
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            android.graphics.PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
            y = dp(24)
        }

        wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        runCatching { wm?.addView(caixa, lp); painel = caixa }
            .onFailure { AppLogger.w(TAG, "addView falhou: ${it.message}"); stopSelf(); return }

        // Some sozinho: sugestão que fica na tela vira estorvo dirigindo. Sem resposta
        // o bridge trata como não-decidido e pode sugerir de novo na próxima partida.
        sumirRunnable = Runnable {
            AppLogger.i(TAG, "sugestão expirou sem resposta")
            MqttManager.getInstance().publicarSugestaoResposta(id, false, expirou = true)
            pararTudo()
        }.also { handler.postDelayed(it, EXPIRA_MS) }
    }

    private fun pararTudo() { remover(); stopSelf() }

    private fun remover() {
        sumirRunnable?.let { handler.removeCallbacks(it) }; sumirRunnable = null
        runCatching { painel?.let { wm?.removeView(it) } }
        painel = null
    }

    override fun onDestroy() { super.onDestroy(); remover() }

    companion object {
        private const val TAG = "SugestaoOverlay"
        private const val EXTRA_ID = "id"
        private const val EXTRA_NOME = "nome"
        private const val EXTRA_HHMM = "hhmm"
        private const val EXPIRA_MS = 45_000L

        fun temPermissao(ctx: Context): Boolean =
            Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(ctx)

        fun mostrar(ctx: Context, id: String, nome: String, hhmm: String) {
            runCatching {
                ctx.startService(Intent(ctx, SugestaoOverlayService::class.java).apply {
                    putExtra(EXTRA_ID, id); putExtra(EXTRA_NOME, nome); putExtra(EXTRA_HHMM, hhmm)
                })
            }
        }

        fun esconder(ctx: Context) {
            runCatching { ctx.stopService(Intent(ctx, SugestaoOverlayService::class.java)) }
        }
    }
}
