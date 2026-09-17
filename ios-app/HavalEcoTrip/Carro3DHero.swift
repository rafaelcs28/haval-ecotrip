//  Carro3DHero.swift
//  O carro em 3D no topo do Painel.
//
//  Carrega `/carro.html` do bridge — um renderizador mínimo, só o veículo, sem
//  nada da interface do viewer original. A página é servida com cache de 1 ano
//  (`immutable`), então baixa uma vez e depois abre do cache.
//
//  Decisões que existem por causa desta tela ser a MAIS ABERTA do app:
//
//  · Só monta quando aparece, e a página para de desenhar sozinha quando some
//    (ela escuta `visibilitychange`). Loop de render a 60 fps numa home aberta o
//    dia todo é bateria queimada à toa.
//  · Altura fixa e fundo transparente: o Painel continua pintando instantâneo em
//    SwiftUI e o carro entra quando estiver pronto, em vez de segurar a tela.
//  · O estado vai por `window.onCarDataUpdate`, o mesmo ponto de entrada que o
//    APK usa no carro — a página não abre rede nenhuma.

import SwiftUI
import WebKit

struct Carro3DHero: View {
    @ObservedObject private var store = CarStore.shared
    /// Cinza do carro do dono. Editável em Config no futuro; por ora, constante.
    // O verniz e o ambiente clareiam bastante: `44474f` saía prata. Este valor é o
    // que RENDERIZA como o cinza chumbo do carro, não o que parece certo no papel.
    private let cor = "15171b"

    var body: some View {
        if let u = url {
            Carro3DWebView(url: u)
                .frame(height: 190)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var url: URL? {
        guard Settings.isConfigured else { return nil }
        // `native=1` não entra aqui: quem alimenta é o Swift, e a página só
        // desenha — ela não busca dado sozinho em nenhum caso.
        return URL(string: Settings.apiBase + "/carro.html?cor=" + cor)
    }
}

private struct Carro3DWebView: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coord { Coord() }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()          // guarda o modelo entre aberturas
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.navigationDelegate = context.coordinator
        w.isOpaque = false                          // fundo do Painel aparece atrás
        w.backgroundColor = .clear
        w.scrollView.backgroundColor = .clear
        w.scrollView.isScrollEnabled = false        // o dedo gira o carro, não rola
        w.scrollView.bounces = false
        w.load(URLRequest(url: url))
        context.coordinator.web = w
        return w
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coord: NSObject, WKNavigationDelegate {
        weak var web: WKWebView?
        private var timer: Timer?
        private var ultimo: [String: String] = [:]
        deinit { timer?.invalidate() }

        func webView(_ w: WKWebView, didFinish navigation: WKNavigation!) {
            ultimo.removeAll()
            timer?.invalidate()
            // 2 Hz. Aqui o carro é ilustração de estado, não instrumento: porta que
            // abriu aparece em meio segundo e ninguém percebe a diferença.
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.empurra()
            }
        }

        private func empurra() {
            guard let w = web else { return }
            let r = CarStore.shared.raw
            var pares: [(String, String)] = []
            for bloco in ["car_raw", "car"] {
                guard let m = r[bloco] as? [String: Any] else { continue }
                for (k, v) in m {
                    if v is NSNull { continue }
                    let s = String(describing: v)
                    if ultimo[k] == s { continue }
                    ultimo[k] = s
                    pares.append((k, s))
                }
            }
            guard !pares.isEmpty else { return }
            let js = pares.map { k, v in
                "window.onCarDataUpdate&&window.onCarDataUpdate(\(cita(k)),\(cita(v)));"
            }.joined()
            w.evaluateJavaScript(js, completionHandler: nil)
        }

        private func cita(_ s: String) -> String {
            (try? String(data: JSONSerialization.data(withJSONObject: [s]), encoding: .utf8))
                .map { String($0.dropFirst().dropLast()) } ?? "\"\""
        }
    }
}
