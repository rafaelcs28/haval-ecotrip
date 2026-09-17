//  Viewer3DView.swift
//
//  Abre o viewer 3D do carro (Haval-H6-3D, de netseek) dentro do app, servido
//  pelo bridge em /3d/. Não é porte: aquele app já é uma página Three.js num
//  WebView — o que existia de Java era casca de head unit (troca de tarefa,
//  acessibilidade, launcher), coisa sem sentido no iPad.
//
//  O token vai por WKUserScript em documentStart, NÃO pela URL: query string
//  vaza em log de servidor, histórico e Referer. O shim do lado servidor lê
//  `window.__ECOTRIP_TOKEN__` e é ele quem fala com /api/state e /ws.

import SwiftUI
import WebKit

struct Viewer3DView: View {
    @State private var carregando = true
    @State private var erro: String?

    var body: some View {
        ZStack {
            DS.bg.ignoresSafeArea()
            if let u = url {
                WebViewer3D(url: u, token: Settings.bridgeToken,
                            base: Settings.apiBase,
                            carregando: $carregando, erro: $erro)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                mensagem("Bridge não configurado neste aparelho.")
            }
            if carregando {
                VStack(spacing: 10) {
                    ProgressView().tint(DS.teal)
                    Text("Carregando o modelo 3D…")
                        .font(.system(size: DS.FontSize.micro)).foregroundStyle(DS.muted)
                    // ~92 MB na primeira vez; depois o WKWebView serve do cache.
                    Text("primeira abertura baixa os modelos; depois abre na hora")
                        .font(.system(size: DS.FontSize.micro)).foregroundStyle(DS.muted.opacity(0.7))
                }
            }
            if let e = erro { mensagem(e) }
        }
        .navigationTitle("Carro em 3D")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var url: URL? {
        guard Settings.isConfigured else { return nil }
        return URL(string: Settings.apiBase + "/3d/")
    }

    private func mensagem(_ t: String) -> some View {
        Text(t)
            .font(.system(size: DS.FontSize.body))
            .foregroundStyle(DS.muted)
            .multilineTextAlignment(.center)
            .padding(24)
    }
}

private struct WebViewer3D: UIViewRepresentable {
    let url: URL
    let token: String
    let base: String
    @Binding var carregando: Bool
    @Binding var erro: String?

    func makeCoordinator() -> Coord { Coord(self) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        // Config ANTES de qualquer script da página: o shim é injetado no fim do
        // body pelo servidor e lê estas globais na primeira linha que executa.
        // __ECOTRIP_NATIVE__ manda o shim ficar só como receptor: quem alimenta é
        // este lado, pelo CarStore, que já está em LAN direta com o carro. Duas
        // rotas pro mesmo campo discordam mais cedo ou mais tarde — e a página,
        // servida por HTTPS, nem alcançaria o carro em http: o WebKit barra como
        // mixed content, e não há chave pública no WKWebView pra liberar.
        let js = """
        window.__ECOTRIP_TOKEN__ = \(jsonString(token));
        window.__ECOTRIP_BASE__  = \(jsonString(base));
        window.__ECOTRIP_NATIVE__ = true;
        """
        cfg.userContentController.addUserScript(
            WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        wv.isOpaque = false
        wv.backgroundColor = .black
        wv.scrollView.backgroundColor = .black
        wv.scrollView.bounces = false          // o viewer trata o próprio gesto
        wv.load(URLRequest(url: url))
        context.coordinator.comecaAlimentar(wv)
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    /// Escapa pra literal JS com segurança — token com aspas ou barra quebraria
    /// o script injetado, e um script quebrado falha em silêncio.
    private func jsonString(_ s: String) -> String {
        (try? String(data: JSONSerialization.data(withJSONObject: [s]), encoding: .utf8))
            .map { String($0.dropFirst().dropLast()) } ?? "\"\""
    }

    final class Coord: NSObject, WKNavigationDelegate {
        private let pai: WebViewer3D
        private var timer: Timer?
        private weak var wv: WKWebView?
        private var pronto = false
        private var ultimo: [String: String] = [:]
        init(_ p: WebViewer3D) { pai = p }
        deinit { timer?.invalidate() }

        /// Empurra as chaves cruas do carro pro viewer a 4 Hz.
        ///
        /// 4 Hz e não os 10 Hz que a LAN entrega: cada push redesenha, e o olho não
        /// vê a diferença num modelo 3D — o que ele veria é a bateria do iPad
        /// acabando. Só chave que MUDOU é enviada, pelo mesmo motivo.
        func comecaAlimentar(_ w: WKWebView) {
            wv = w
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                self?.empurra()
            }
        }

        private func empurra() {
            guard pronto, let w = wv else { return }
            let r = CarStore.shared.raw
            var pares: [(String, String)] = []
            // `car` traz o que tem campo normalizado; `car_raw` o resto, direto do
            // barramento. `car` por último: em conflito, vence o valor curado.
            for bloco in ["car_raw", "car"] {
                guard let d = r[bloco] as? [String: Any] else { continue }
                for (k, v) in d {
                    if v is NSNull { continue }
                    let s = String(describing: v)
                    if ultimo[k] == s { continue }
                    ultimo[k] = s
                    pares.append((k, s))
                }
            }
            guard !pares.isEmpty else { return }
            // Uma avaliação só por lote: cada evaluateJavaScript cruza a ponte
            // pro processo do WebView, e 40 chaves viravam 40 travessias.
            let js = pares.map { k, v in
                "window.onCarDataUpdate&&window.onCarDataUpdate(\(quote(k)),\(quote(v)));"
            }.joined()
            w.evaluateJavaScript(js, completionHandler: nil)
        }

        private func quote(_ s: String) -> String {
            (try? String(data: JSONSerialization.data(withJSONObject: [s]), encoding: .utf8))
                .map { String($0.dropFirst().dropLast()) } ?? "\"\""
        }

        func webView(_ w: WKWebView, didFinish navigation: WKNavigation!) {
            pai.carregando = false
            pronto = true
            ultimo.removeAll()   // recarregou: o viewer esqueceu tudo, reenvia
        }
        func webView(_ w: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            pai.carregando = false
            pai.erro = "Falhou ao carregar: " + error.localizedDescription
        }
        func webView(_ w: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            pai.carregando = false
            pai.erro = "Não alcancei o bridge: " + error.localizedDescription
        }
    }
}
