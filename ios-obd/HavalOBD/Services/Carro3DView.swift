//  Carro3DView.swift
//  Visualizador 3D do carro (Haval-H6-3D, de netseek) dentro do Cockpit.
//
//  A página vem do bridge (/3d/), não do bundle: são ~92 MB de modelo e textura.
//  Servida com `immutable` e cache de 1 ano, ela baixa UMA vez e reusa — o IPA fica
//  pequeno e o repositório limpo (os assets são de terceiro, e este repo é público).
//  O custo é precisar de rede na primeira abertura, ou se o iOS despejar o cache.
//
//  Os DADOS não vêm do bridge: vêm da LAN direta com o carro, que é o que o Cockpit
//  já faz. O WebView não abre rede nenhuma pra telemetria — quem alimenta é este
//  arquivo, pelo mesmo desenho do ClusterWebView (Swift → JS por evaluateJavaScript).

import SwiftUI
import WebKit

struct Carro3DView: View {
    @EnvironmentObject var publisher: BridgePublisher
    @AppStorage("bridge_base_url") private var bridgeBase = "https://bridge.malha.dev"

    /// Largura de projeto do visualizador. Ele foi feito pra head unit larga e não
    /// reflui: num viewport de 1024 pt o layout não encolhe — ele fica CORTADO, e o
    /// carro sai pela direita da tela. Então o WebView é montado com 1920 px de
    /// largura e a camada inteira é reduzida pra caber. É o mesmo desenho que o
    /// head unit mostra, só menor — e não uma versão espremida que o autor nunca fez.
    private let larguraProjeto: CGFloat = 1920
    /// Altura relativa do viewport de projeto. Ajustável em Config só pra achar o
    /// valor certo no olho — o palco do carro é 8/3 no CSS do visualizador.
    @AppStorage("carro3d_altura_rel") private var alturaRel: Double = 0.75

    var body: some View {
        GeometryReader { g in
            let escala = max(0.05, g.size.width / larguraProjeto)
            let alturaProjeto = larguraProjeto * CGFloat(alturaRel)
            Carro3DWeb(baseUrl: bridgeBase, publisher: publisher)
                .frame(width: larguraProjeto, height: alturaProjeto)
                .scaleEffect(escala, anchor: .topLeading)
                .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
                .clipped()
        }
        .ignoresSafeArea()
        .navigationTitle("Carro em 3D")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct Carro3DWeb: UIViewRepresentable {
    let baseUrl: String
    let publisher: BridgePublisher

    func makeCoordinator() -> Coord { Coord(publisher: publisher) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        // Store persistente (o padrão) é o que guarda os 92 MB entre aberturas.
        cfg.websiteDataStore = .default()

        let web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = context.coordinator
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.backgroundColor = .black
        web.scrollView.bounces = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        if #available(iOS 16.4, *) { web.isInspectable = true }

        // `native=1` faz o SERVIDOR marcar que quem alimenta é o app — o shim da
        // página então não abre fetch nem WebSocket. Injetar isso do lado do app
        // correria com o carregamento; pelo servidor a ordem é garantida.
        // `android=1` é a flag de performance do próprio viewer (o /3d já força).
        let base = baseUrl.hasSuffix("/") ? String(baseUrl.dropLast()) : baseUrl
        if let url = URL(string: base + "/3d/?native=1") {
            web.load(URLRequest(url: url))
        }
        context.coordinator.web = web
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coord: NSObject, WKNavigationDelegate {
        private let publisher: BridgePublisher
        weak var web: WKWebView?
        private var timer: Timer?
        private var pronto = false
        private var ultimo: [String: String] = [:]

        init(publisher: BridgePublisher) { self.publisher = publisher }
        deinit { timer?.invalidate() }

        func webView(_ w: WKWebView, didFinish navigation: WKNavigation!) {
            pronto = true
            ultimo.removeAll()          // recarregou: o viewer esqueceu, reenvia tudo
            // 4 Hz. A LAN entrega 10, mas cada push redesenha e o olho não vê a
            // diferença num modelo 3D — a bateria vê.
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                self?.empurra()
            }
        }

        /// Repassa as chaves do CarConstants pro viewer pelo mesmo ponto de entrada
        /// que o Android usa (`window.onCarDataUpdate`) — pra ele não há diferença
        /// entre rodar no head unit e aqui.
        ///
        /// A fonte é o snapshot que o BridgePublisher JÁ recebe pelo /ws/state; não
        /// abro conexão própria, senão seriam dois clientes no mesmo servidor do APK.
        private func empurra() {
            guard pronto, let w = web else { return }
            let o = publisher.ultimoSnapshotLan
            guard !o.isEmpty else { return }
            var pares: [(String, String)] = []
            // `car_raw` primeiro e `car` depois: em conflito vence o valor curado.
            for bloco in ["car_raw", "car"] {
                guard let m = o[bloco] as? [String: Any] else { continue }
                for (k, v) in m {
                    if v is NSNull { continue }
                    let s = String(describing: v)
                    if ultimo[k] == s { continue }
                    ultimo[k] = s
                    pares.append((k, s))
                }
            }
            guard !pares.isEmpty else { return }
            // Um evaluateJavaScript por lote: cada chamada cruza a ponte pro processo
            // do WebView.
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
