package br.com.redesurftank.ecotrip.managers

/**
 * Filtro de mediana de janela móvel. Usado para suavizar leituras ruidosas de
 * sensores no caminho de exibição (ex.: % de combustível, que balança no tanque
 * em curva/freio/subida). Rejeita picos transientes de 1-2 amostras e ainda
 * acompanha mudanças reais sustentadas (com lag de ~n/2 amostras).
 */
class MedianFilter(private val n: Int = 7) {
    private val win = ArrayDeque<Float>()

    @Synchronized fun push(v: Float): Float {
        win.addLast(v)
        while (win.size > n) win.removeFirst()
        val s = win.sorted()
        return s[s.size / 2]
    }
}
