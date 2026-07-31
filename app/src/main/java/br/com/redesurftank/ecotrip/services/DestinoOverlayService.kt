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
        if (!temPermissao(this)) {
            // Sem "desenhar sobre outros apps" o addView lança e derruba o serviço.
            AppLogger.w(TAG, "sem permissão de overlay — serviço não sobe")
            stopSelf(); return
        }
        runCatching { mostrar() }.onFailure {
            AppLogger.e(TAG, "falha ao criar overlay", it as? Exception ?: Exception(it))
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
                        abrirTelaDestino()
                    }
                    true
                }
                else -> false
            }
        }

        wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        wm?.addView(tv, lp)
        botao = tv
        AppLogger.i(TAG, "overlay de destino no ar (x=${lp.x} y=${lp.y})")
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
