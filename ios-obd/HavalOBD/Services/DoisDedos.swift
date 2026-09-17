//  DoisDedos.swift
//  Deslizar com DOIS dedos troca de aba no Cockpit.
//
//  O reconhecedor é instalado na JANELA, não numa camada por cima do conteúdo.
//  Uma view transparente sobrando em ZStack só receberia o toque se BLOQUEASSE o
//  que está embaixo — e embaixo está o WebView do painel, que precisa do toque
//  dele. Na janela o gesto vê tudo, e com `cancelsTouchesInView = false` o toque
//  segue vivo pro WebView.
//
//  Dois dedos, e não um: o painel inteiro é rolável e cheio de botão. Um dedo
//  pertence à página.

import SwiftUI
import UIKit

struct DoisDedosSwipe: UIViewRepresentable {
    /// −1 = deslizou pra direita (aba anterior), +1 = pra esquerda (próxima).
    var aoDeslizar: (Int) -> Void

    func makeCoordinator() -> Coord { Coord(aoDeslizar: aoDeslizar) }

    func makeUIView(context: Context) -> UIView {
        let v = Ancora()
        v.isUserInteractionEnabled = false      // não rouba toque de ninguém
        v.aoEntrarNaJanela = { [weak v] in
            guard let janela = v?.window else { return }
            context.coordinator.instala(em: janela)
        }
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.aoDeslizar = aoDeslizar
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coord) {
        coordinator.remove()
    }

    /// View de tamanho zero cuja única função é avisar quando a janela existe —
    /// em `makeUIView` ela ainda não está na hierarquia e `window` é nil.
    final class Ancora: UIView {
        var aoEntrarNaJanela: (() -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { aoEntrarNaJanela?() }
        }
    }

    final class Coord: NSObject, UIGestureRecognizerDelegate {
        var aoDeslizar: (Int) -> Void
        private var gestos: [UISwipeGestureRecognizer] = []
        private weak var janela: UIWindow?

        init(aoDeslizar: @escaping (Int) -> Void) { self.aoDeslizar = aoDeslizar }

        func instala(em janela: UIWindow) {
            guard self.janela !== janela else { return }
            remove()
            self.janela = janela
            for (direcao, sinal) in [(UISwipeGestureRecognizer.Direction.left, 1),
                                     (UISwipeGestureRecognizer.Direction.right, -1)] {
                let g = UISwipeGestureRecognizer(target: self, action: #selector(disparou(_:)))
                g.direction = direcao
                g.numberOfTouchesRequired = 2
                g.cancelsTouchesInView = false   // o WebView continua recebendo o toque
                g.delegate = self
                g.name = String(sinal)
                janela.addGestureRecognizer(g)
                gestos.append(g)
            }
        }

        func remove() {
            gestos.forEach { $0.view?.removeGestureRecognizer($0) }
            gestos.removeAll()
            janela = nil
        }

        @objc private func disparou(_ g: UISwipeGestureRecognizer) {
            aoDeslizar(Int(g.name ?? "") ?? 1)
        }

        // O WebView tem os gestos dele (rolagem, zoom). Conviver é obrigatório:
        // exigir exclusividade faria um dos dois nunca disparar.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool { true }
    }
}
