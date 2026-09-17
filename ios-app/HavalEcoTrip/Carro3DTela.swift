//  Carro3DTela.swift
//  O carro em 3D, em tela cheia, aberto por um toque no Painel.
//
//  Já foi um bloco fixo no topo do Painel e voltou atrás por dois motivos que
//  valem ficar escritos:
//
//  · A 190pt o desenho não pagava o espaço. O carro mostra estado ACENDENDO a
//    peça (porta, vidro, teto, farol) — não abrindo —, e naquele tamanho porta
//    acesa virava mancha. Em tela cheia o mesmo destaque se lê de relance.
//  · WebView com loop de render numa home aberta o dia todo é bateria queimada
//    à toa. Aqui ele só existe enquanto a tela está aberta.
//
//  A página (`/carro.html` do bridge) é servida com cache de 1 ano (`immutable`):
//  baixa uma vez e depois abre do cache. O estado vai por `window.setCarState`,
//  com os campos já normalizados pelo bridge — a página não abre rede nenhuma.

import SwiftUI
import WebKit

struct Carro3DTela: View {
    @Environment(\.dismiss) private var dismiss
    /// Cinza do carro do dono. O verniz e o ambiente clareiam bastante: `44474f`
    /// saía prata. Este valor é o que RENDERIZA como o cinza chumbo do carro, não
    /// o que parece certo no papel.
    private let cor = "15171b"

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let u = url {
                Carro3DWebView(url: u).ignoresSafeArea()
            } else {
                Text("Configure o servidor primeiro")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(.white.opacity(0.14), in: Circle())
            }
            .padding(.top, 10).padding(.trailing, 14)
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
            let st = CarStore.shared

            // Os campos NORMALIZADOS do bridge, não as chaves cruas do CarConstants:
            // `car`/`car_raw` só existem quando o iPhone está na LAN do carro, e fora
            // dela o desenho ficava mudo. Estes o app tem sempre.
            //
            // Cada abertura passa pelo MESMO filtro de frescor do resto do Painel
            // (`campoConfiavel`). Sem ele o carro desenharia porta aberta com o
            // veículo trancado: `door_fl` congela no último valor do APK, que morre
            // junto com o carro, e ninguém publica o fechamento — foi exatamente o
            // "1 aberta" que o painel já acusou errado.
            // Desconhecido desenha FECHADO, nunca aberto: o destaque afirma, e o
            // que não pôde ser confirmado não vira aviso laranja na tela.
            func aberto(_ campo: String) -> Bool {
                st.campoConfiavel(campo) && st.str(campo) == "on"
            }
            var o: [String: Bool] = [
                "porta_fl": aberto("door_fl"), "porta_fr": aberto("door_fr"),
                "porta_rl": aberto("door_rl"), "porta_rr": aberto("door_rr"),
                "porta_malas": aberto("door_trunk"),
                "vidro_fl": aberto("window_fl"), "vidro_fr": aberto("window_fr"),
                "vidro_rl": aberto("window_rl"), "vidro_rr": aberto("window_rr"),
                "teto": aberto("sunroof"),
            ]
            // Farol: `light_state` é o campo próprio, mas o bridge anota "sem sensor
            // por ora" — então o alto também acende o desenho. Sem leitura, apagado.
            func ligado(_ campo: String) -> Bool {
                st.campoConfiavel(campo) && st.str(campo) == "on"
            }
            o["farol"] = ligado("light_state") || ligado("high_beam")

            // Tranca segue a semântica do bridge: 'off' = trancado. Só desenha o
            // cadeado com leitura afirmada — trancado é o normal e não vira aviso.
            o["destrancado"] = st.lockKnown && st.campoConfiavel("lock_state") && !st.isLocked

            var mudou: [String: Bool] = [:]
            for (k, v) in o {
                let s = String(v)
                if ultimo[k] == s { continue }
                ultimo[k] = s
                mudou[k] = v
            }
            guard !mudou.isEmpty,
                  let d = try? JSONSerialization.data(withJSONObject: mudou),
                  let j = String(data: d, encoding: .utf8) else { return }
            w.evaluateJavaScript("window.setCarState&&window.setCarState(\(j));",
                                 completionHandler: nil)
        }

    }
}
