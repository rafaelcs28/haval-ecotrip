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
import androidx.compose.ui.graphics.toArgb
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
        // Slot separado do da tela Compose: os dois escutam place_search/result e um
        // slot único fazia o último a registrar apagar o outro.
        MqttManager.getInstance().onNavResultOverlay = { topic, body ->
            if (topic.endsWith("/place_search/result")) onResultadoBusca(body)
        }
        tentar()
    }

    /// Resultado da busca chega na thread do MQTT; toda mexida em View tem que ir pra
    /// main. Só redesenha se o painel de busca ainda estiver aberto — resultado
    /// atrasado não deve reabrir um painel que o dono já fechou.
    private fun onResultadoBusca(body: String) {
        android.os.Handler(android.os.Looper.getMainLooper()).post {
            runCatching {
                val o = org.json.JSONObject(body)
                if (o.optBoolean("ok")) {
                    val itens = o.optJSONArray("items")
                    buscaItens = itens
                    buscaMsg = if (itens == null || itens.length() == 0)
                        "Nada encontrado para \"${o.optString("q")}\"." else null
                } else {
                    buscaItens = null
                    buscaMsg = "Busca falhou: ${o.optString("error")}"
                }
                if (modoBusca && painel != null) rerender()
            }.onFailure { AppLogger.w(TAG, "resultado de busca inválido: ${it.message}") }
        }
    }

    /// cmd/overlay chama startService num serviço que já está rodando, e aí o
    /// Android entrega em onStartCommand — NÃO em onCreate. Sem isto o comando de
    /// retentativa não fazia absolutamente nada, e eu ficava lendo um retained
    /// antigo achando que era a tentativa nova.
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Desligado nas configurações: derruba o que houver e NÃO pede recriação.
        // START_NOT_STICKY aqui é essencial — com STICKY o Android reergueria o serviço
        // e o botão voltaria sozinho na próxima partida.
        if (!habilitado(this)) {
            runCatching { botao?.let { wm?.removeView(it) } }
            botao = null
            stopSelf()
            return START_NOT_STICKY
        }
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
                // ~38%. Antes eu somei dois efeitos (cor 66% × alpha 0.88 = 58%) e o
                // botão sumia sobre fundo claro; 85% ficou forte demais. A borda
                // escura é que garante o contorno visível em qualquer fundo.
                setColor(Color.parseColor("#6200E5CC"))
                setStroke(3, Color.parseColor("#99000000"))
            }
            // A medição no carro deu density=1.0, então dp==px: 64 virava 64px numa
            // tela de 1792 — 3,5% da largura. 100px é o alvo que se acerta dirigindo.
            val d = (70 * resources.displayMetrics.density).toInt()
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
            // Nasce no CENTRO da tela, onde é impossível estar coberto: a medição
            // provou que em x=24 o botão estava desenhado, visível e anexado — e
            // invisível de fato, porque a barra de atalhos do head unit (home, grid,
            // clima) ocupa a faixa da esquerda e fica na frente. Do centro o dono
            // arrasta pro canto que preferir, e a posição fica salva.
            val mDef = resources.displayMetrics
            x = prefs.getInt(K_X, (mDef.widthPixels * 0.50f).toInt())
            y = prefs.getInt(K_Y, (mDef.heightPixels * 0.50f).toInt())
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
            // Só resgata posição REALMENTE inalcançável, e só quando o dono nunca
            // escolheu uma. A versão anterior tratava todo x na faixa esquerda como
            // inválido e recentrava — apagando a posição escolhida a cada abertura,
            // que é o oposto de persistir. Se você arrastou pra algum canto, aquilo
            // é a sua decisão, mesmo perto da barra do sistema.
            val escolhida = prefs.contains(K_X) && prefs.contains(K_Y)
            val foraDaTela = lp.x > m.widthPixels - 30 || lp.y > m.heightPixels - 30 ||
                             lp.x < -30 || lp.y < -30
            if (foraDaTela || (!escolhida && lp.x < (m.widthPixels * 0.14f))) {
                lp.x = (m.widthPixels * 0.50f).toInt(); lp.y = (m.heightPixels * 0.50f).toInt()
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
    /// A busca também acontece AQUI. Antes ela mandava pro app, e como o Intent usa
    /// REORDER_TO_FRONT o extra chegava em onNewIntent — que a tela não lia — então
    /// o app abria na aba de sempre e o motorista tinha que procurar o botão de novo.
    /// Pra digitar, a janela do painel troca de flags e aceita foco só enquanto a
    /// busca está aberta; fora dela segue NOT_FOCUSABLE pra não roubar o teclado do
    /// app de baixo.
    private var painel: View? = null
    private var modoBusca = false
    private var buscaTexto = ""
    private var buscaItens: org.json.JSONArray? = null
    private var buscaMsg: String? = null

    /// Tamanho do painel. A tela do carro é 1792x720 com density=1.0 (dp = px), então
    /// dá folga nos dois eixos: o painel inteiro fica em ~530px de altura contando
    /// título, abas e o rodapé de busca. Item de ~54dp + 8 de margem = 62.
    /// Paleta e escala do overlay. Antes eram literais espalhados: nove strings hex
    /// e seis tamanhos ad-hoc. O teal já existia como `AuroraTeal` no Theme.kt e
    /// estava redigitado aqui como "#00E5CC" — duas fontes de verdade pra mesma cor,
    /// que divergem no primeiro ajuste de tema.
    private object Cor {
        val teal    = br.com.redesurftank.ecotrip.ui.theme.AuroraTeal.toArgb()
        val texto   = Color.parseColor("#EEF4FF")
        val apagado = Color.parseColor("#5B7394")
        val fundo   = Color.parseColor("#F206080C")   // painel, com alpha
        val item    = Color.parseColor("#141A24")
        val sobreTeal = Color.parseColor("#06080C")   // texto sobre fundo teal
        val ok      = Color.parseColor("#39FF88")
    }
    /// Piso de 14sp: o carro é lido de relance e em movimento.
    private object Fonte {
        const val TITULO = 19f
        const val ITEM   = 17f
        const val CORPO  = 16f
        const val APOIO  = 15f
        const val MICRO  = 14f
    }
    /// Mínimo do Material pra alvo de toque. As abas ficavam em ~34dp.
    private val ALVO_MIN = 48

    private val PAINEL_W = 400
    private val ITEM_H = 62
    private val LINHAS_VISIVEIS = 6

    /// Aba visível, lembrada entre aberturas: quem usa "Recentes" tende a usar de
    /// novo, e voltar sempre pra primeira aba obrigaria dois toques cada vez.
    private var abaAtiva = 0

    /// Redesenha o painel mantendo o estado (aba, texto digitado). O painel é
    /// recriado inteiro porque as flags da janela mudam entre modo lista e modo
    /// busca, e isso exige removeView/addView.
    private fun rerender() {
        val estava = painel != null
        fecharPainel()
        if (estava) mostrarPainel()
    }

    private fun mostrarPainel() {
        if (painel != null) { fecharPainel(); return }
        if (modoBusca) { mostrarPainelBusca(); return }
        val abas = lerAbas()
        if (abaAtiva >= abas.size) abaAtiva = 0
        val favs = abas.getOrNull(abaAtiva)?.second ?: emptyList()
        val dp: (Int) -> Int = { v -> (v * resources.displayMetrics.density).toInt() }

        val col = android.widget.LinearLayout(this).apply {
            orientation = android.widget.LinearLayout.VERTICAL
            setPadding(dp(14), dp(14), dp(14), dp(14))
            background = GradientDrawable().apply {
                cornerRadius = dp(18).toFloat()
                setColor(Cor.fundo)
                setStroke(dp(1), Cor.teal)
            }
        }
        col.addView(TextView(this).apply {
            text = "Para onde vamos?"
            setTextColor(Cor.texto); textSize = Fonte.TITULO
            setTypeface(null, android.graphics.Typeface.BOLD)
            setPadding(0, 0, 0, dp(10))
        })

        if (abas.size > 1) {
            val linha = android.widget.LinearLayout(this).apply {
                orientation = android.widget.LinearLayout.HORIZONTAL
                setPadding(0, 0, 0, dp(10))
            }
            abas.forEachIndexed { i, (titulo, itens) ->
                linha.addView(TextView(this).apply {
                    // Contagem no rótulo: evita trocar de aba pra descobrir que está vazia.
                    text = "$titulo (${itens.size})"
                    textSize = Fonte.MICRO
                    setTypeface(null, android.graphics.Typeface.BOLD)
                    setTextColor(if (i == abaAtiva) Cor.sobreTeal else Cor.apagado)
                    setPadding(dp(14), dp(8), dp(14), dp(8))
                    gravity = Gravity.CENTER
                    background = GradientDrawable().apply {
                        cornerRadius = dp(10).toFloat()
                        setColor(if (i == abaAtiva) Cor.teal else Cor.item)
                    }
                    setOnClickListener { abaAtiva = i; fecharPainel(); mostrarPainel() }
                }, android.widget.LinearLayout.LayoutParams(
                    android.widget.LinearLayout.LayoutParams.WRAP_CONTENT,
                    // 48dp: com padding de 8 a aba tinha ~34dp de altura. Trocar de aba
                    // com o carro andando é toque de relance — abaixo do mínimo, erra.
                    dp(ALVO_MIN)).apply { rightMargin = dp(6) })
            }
            col.addView(linha)
        }

        if (favs.isEmpty()) {
            // "Meus locais" espelha a lista do iPhone. Se ela chega vazia, o motivo
            // quase sempre é o celular ainda não ter sincronizado — dizer isso evita
            // que a aba em branco pareça um lugar perdido.
            col.addView(TextView(this).apply {
                text = if (abaAtiva == 0) "Nenhum local do iPhone ainda.\nAbra a tela de destino no iPhone\npra sincronizar."
                       else "Nada nesta aba ainda."
                setTextColor(Cor.apagado); textSize = Fonte.APOIO
            })
        }
        // Rolagem: antes a lista era cortada em 6 itens sem aviso e o resto ficava
        // inalcançável. Agora todos entram e a altura mostra ~5 — o suficiente pra
        // decidir sem virar uma parede de texto no carro.
        val listaCol = android.widget.LinearLayout(this).apply {
            orientation = android.widget.LinearLayout.VERTICAL
        }
        for (f in favs) {
            listaCol.addView(TextView(this).apply {
                val km = f.optDouble("distKm").let { if (it.isNaN()) "" else "   ${"%.1f".format(it)} km" }
                text = f.optString("name") + km
                setTextColor(Cor.texto); textSize = Fonte.ITEM
                setTypeface(null, android.graphics.Typeface.BOLD)
                setPadding(dp(14), dp(14), dp(14), dp(14))
                background = GradientDrawable().apply {
                    cornerRadius = dp(12).toFloat(); setColor(Cor.item)
                }
                setOnClickListener {
                    // "⏳" até o broker confirmar. O ✓ imediato era otimista: com o
                    // MQTT fora, a publicação era descartada em silêncio e só o carro
                    // não receber revelava — daí ter que tocar duas vezes (05/08).
                    text = "⏳ " + f.optString("name")
                    setTextColor(Cor.apagado)
                    MqttManager.getInstance().publishNavTo(
                        f.optDouble("lat"), f.optDouble("lng"), f.optString("name"), "waze") { ok ->
                        post {
                            if (ok) {
                                text = "✓ " + f.optString("name"); setTextColor(Cor.ok)
                                postDelayed({ fecharPainel() }, 900)
                            } else {
                                text = "✗ sem conexão — toque de novo"
                                setTextColor(Color.parseColor("#FF6B6B"))
                            }
                        }
                    }
                }
            }, android.widget.LinearLayout.LayoutParams(
                android.widget.LinearLayout.LayoutParams.MATCH_PARENT,
                android.widget.LinearLayout.LayoutParams.WRAP_CONTENT).apply {
                bottomMargin = dp(8)
            })
        }
        // Largura EXPLÍCITA na ScrollView e na lista interna. Com WRAP_CONTENT e sem
        // LayoutParams no filho, a largura degenerou e o popup virou uma faixa
        // vertical fina no meio da tela (visto no carro em 31/07) — ScrollView não
        // propaga a largura dos filhos como um LinearLayout faria.
        col.addView(android.widget.ScrollView(this).apply {
            isVerticalScrollBarEnabled = true
            addView(listaCol, android.widget.FrameLayout.LayoutParams(
                dp(PAINEL_W), android.widget.FrameLayout.LayoutParams.WRAP_CONTENT))
        }, android.widget.LinearLayout.LayoutParams(dp(PAINEL_W), dp(LINHAS_VISIVEIS * ITEM_H)))

        col.addView(TextView(this).apply {
            text = "🔍  Buscar outro lugar…"
            setTextColor(Cor.teal); textSize = Fonte.CORPO
            setPadding(dp(14), dp(14), dp(14), dp(14))
            setOnClickListener { modoBusca = true; buscaMsg = null; rerender() }
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

    /// Painel de busca: campo de texto + resultados do Google (via bridge, que tem a
    /// chave). Fica no overlay pra não interromper o Waze — sair do app de navegação
    /// pra digitar um endereço é justamente o que este botão existe pra evitar.
    private fun mostrarPainelBusca() {
        val dp: (Int) -> Int = { v -> (v * resources.displayMetrics.density).toInt() }
        val col = android.widget.LinearLayout(this).apply {
            orientation = android.widget.LinearLayout.VERTICAL
            setPadding(dp(14), dp(14), dp(14), dp(14))
            background = GradientDrawable().apply {
                cornerRadius = dp(18).toFloat()
                setColor(Cor.fundo)
                setStroke(dp(1), Cor.teal)
            }
        }
        col.addView(TextView(this).apply {
            text = "Buscar lugar"
            setTextColor(Cor.texto); textSize = Fonte.TITULO
            setTypeface(null, android.graphics.Typeface.BOLD)
            setPadding(0, 0, 0, dp(10))
        })

        val campo = android.widget.EditText(this).apply {
            hint = "Ex: New Vikings, posto Shell…"
            setHintTextColor(Cor.apagado)
            setTextColor(Cor.texto); textSize = Fonte.ITEM
            setPadding(dp(12), dp(12), dp(12), dp(12))
            setSingleLine(true)
            imeOptions = android.view.inputmethod.EditorInfo.IME_ACTION_SEARCH
            inputType = android.text.InputType.TYPE_CLASS_TEXT
            background = GradientDrawable().apply {
                cornerRadius = dp(12).toFloat(); setColor(Cor.item)
            }
            setText(buscaTexto)
            setSelection(buscaTexto.length)
            setOnEditorActionListener { _, _, _ -> disparaBusca(text.toString()); true }
        }
        col.addView(campo, android.widget.LinearLayout.LayoutParams(
            dp(PAINEL_W), android.widget.LinearLayout.LayoutParams.WRAP_CONTENT))

        val linha = android.widget.LinearLayout(this).apply {
            orientation = android.widget.LinearLayout.HORIZONTAL
            setPadding(0, dp(10), 0, dp(10))
        }
        fun botao(rotulo: String, fundo: String, fg: String, acao: () -> Unit) =
            TextView(this).apply {
                text = rotulo; textSize = Fonte.CORPO
                setTypeface(null, android.graphics.Typeface.BOLD)
                setTextColor(Color.parseColor(fg))
                setPadding(dp(18), dp(10), dp(18), dp(10))
                background = GradientDrawable().apply {
                    cornerRadius = dp(10).toFloat(); setColor(Color.parseColor(fundo))
                }
                setOnClickListener { acao() }
            }
        linha.addView(botao("Buscar", "#00E5CC", "#06080C") { disparaBusca(campo.text.toString()) },
            android.widget.LinearLayout.LayoutParams(
                android.widget.LinearLayout.LayoutParams.WRAP_CONTENT,
                android.widget.LinearLayout.LayoutParams.WRAP_CONTENT).apply { rightMargin = dp(8) })
        linha.addView(botao("Voltar", "#141A24", "#5B7394") {
            modoBusca = false; buscaItens = null; buscaMsg = null; rerender()
        })
        col.addView(linha)

        buscaMsg?.let {
            col.addView(TextView(this).apply {
                text = it
                setTextColor(Cor.apagado); textSize = Fonte.APOIO
                setPadding(0, 0, 0, dp(8))
            })
        }

        val listaCol = android.widget.LinearLayout(this).apply {
            orientation = android.widget.LinearLayout.VERTICAL
        }
        val itens = buscaItens
        if (itens != null) for (i in 0 until itens.length()) {
            val o = itens.optJSONObject(i) ?: continue
            listaCol.addView(TextView(this).apply {
                val km = o.optDouble("distKm").let { if (it.isNaN()) "" else "  ·  ${"%.1f".format(it)} km" }
                val end = o.optString("address").let { if (it.isEmpty()) "" else "\n$it" }
                text = o.optString("name") + km + end
                setTextColor(Cor.texto); textSize = Fonte.CORPO
                setPadding(dp(14), dp(12), dp(14), dp(12))
                background = GradientDrawable().apply {
                    cornerRadius = dp(12).toFloat(); setColor(Cor.item)
                }
                setOnClickListener {
                    text = "⏳ " + o.optString("name")
                    setTextColor(Cor.apagado)
                    MqttManager.getInstance().publishNavTo(
                        o.optDouble("lat"), o.optDouble("lng"), o.optString("name"), "waze") { ok ->
                        post {
                            if (ok) {
                                text = "✓ " + o.optString("name"); setTextColor(Cor.ok)
                                postDelayed({ modoBusca = false; buscaItens = null; fecharPainel() }, 900)
                            } else {
                                text = "✗ sem conexão — toque de novo"
                                setTextColor(Color.parseColor("#FF6B6B"))
                            }
                        }
                    }
                }
            }, android.widget.LinearLayout.LayoutParams(
                android.widget.LinearLayout.LayoutParams.MATCH_PARENT,
                android.widget.LinearLayout.LayoutParams.WRAP_CONTENT).apply { bottomMargin = dp(8) })
        }
        col.addView(android.widget.ScrollView(this).apply {
            isVerticalScrollBarEnabled = true
            addView(listaCol, android.widget.FrameLayout.LayoutParams(
                dp(PAINEL_W), android.widget.FrameLayout.LayoutParams.WRAP_CONTENT))
        }, android.widget.LinearLayout.LayoutParams(dp(PAINEL_W), dp(4 * ITEM_H)))

        // SEM FLAG_NOT_FOCUSABLE: é o que permite digitar. Só nesta tela — o painel de
        // lista continua não-focável pra não tirar o teclado de quem está embaixo.
        val lp = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT, WindowManager.LayoutParams.WRAP_CONTENT,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            else @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE,
            0,   // nenhuma flag = janela focável = o EditText recebe o teclado
            android.graphics.PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.CENTER
            softInputMode = WindowManager.LayoutParams.SOFT_INPUT_STATE_VISIBLE or
                            WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE
        }

        runCatching {
            wm?.addView(col, lp); painel = col
            campo.requestFocus()
            // O IME não sobe junto com o addView — a janela precisa estar anexada
            // primeiro. 250ms cobre a anexação no head unit sem piscar.
            campo.postDelayed({
                runCatching {
                    (getSystemService(INPUT_METHOD_SERVICE) as android.view.inputmethod.InputMethodManager)
                        .showSoftInput(campo, android.view.inputmethod.InputMethodManager.SHOW_IMPLICIT)
                }
            }, 250)
        }.onFailure { AppLogger.w(TAG, "painel de busca falhou: ${it.message}") }
    }

    private fun disparaBusca(texto: String) {
        buscaTexto = texto.trim()
        if (buscaTexto.length < 3) { buscaMsg = "Digite ao menos 3 letras."; rerender(); return }
        buscaMsg = "Buscando \"$buscaTexto\"…"
        buscaItens = null
        MqttManager.getInstance().buscarLugar(buscaTexto)
        rerender()
    }

    private fun fecharPainel() {
        runCatching { painel?.let { wm?.removeView(it) } }
        painel = null
    }

    /// As três abas: lugares salvos, favoritados numa busca, e histórico. Cai pra
    /// `items` (lista única) se o bridge for antigo e não mandar `abas`.
    private fun lerAbas(): List<Pair<String, List<org.json.JSONObject>>> {
        val raw = MqttManager.getInstance().navFavoritosJson ?: return emptyList()
        return runCatching {
            val o = org.json.JSONObject(raw)
            fun lista(arr: org.json.JSONArray?): List<org.json.JSONObject> =
                if (arr == null) emptyList()
                else (0 until arr.length()).mapNotNull { arr.optJSONObject(it) }
                    .filter { it.optString("name").isNotBlank() }
            val abas = o.optJSONObject("abas")
            if (abas == null) listOf("Locais" to lista(o.optJSONArray("items")))
            else listOf(
                "Meus locais" to lista(abas.optJSONArray("lugares")),
                "Favoritos"   to lista(abas.optJSONArray("favoritos")),
                "Recentes"    to lista(abas.optJSONArray("recentes")),
            )
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
        MqttManager.getInstance().onNavResultOverlay = null
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

        /// Botão habilitado nas configurações? Ausente = ligado (comportamento histórico).
        ///
        /// A checagem vive AQUI, e não só em quem chama, porque havia dois caminhos que
        /// religavam o botão por fora do toggle: um `LaunchedEffect` na ConsumptionScreen
        /// que subia o overlay ao ver a permissão concedida, e o `START_STICKY`, que faz o
        /// Android reerguer o serviço sozinho e redesenhar o botão. Era isso que fazia ele
        /// aparecer a cada partida e sumir em seguida (31/08).
        fun habilitado(ctx: Context): Boolean =
            ctx.getSharedPreferences(
                br.com.redesurftank.ecotrip.models.SharedPreferencesKeys.PREFS_NAME,
                Context.MODE_PRIVATE,
            ).getString(
                br.com.redesurftank.ecotrip.models.SharedPreferencesKeys.OVERLAY_DESTINO, "1",
            ) != "0"

        fun ligar(ctx: Context) {
            if (!habilitado(ctx)) { AppLogger.i(TAG, "botão desligado nas configurações — não sobe"); return }
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
