import SwiftUI
import WebKit

/// WebView fullscreen que hospeda o `cluster.html` (mesmo do PWA, copiado pro
/// bundle). Cria um canal JS bidirecional:
///
///   Swift → JS:  `webView.evaluateJavaScript("window._nativeBridge.update(...)")`
///                injeta snapshot OBD em tempo real (via OBDBridgeChannel)
///
///   JS → Swift:  `window.webkit.messageHandlers.obd.postMessage({...})`
///                comandos do cluster (abrir navegação externa, etc.)
struct ClusterWebView: UIViewRepresentable {
    @EnvironmentObject var elm: ELM327
    @EnvironmentObject var channel: OBDBridgeChannel

    func makeCoordinator() -> Coordinator { Coordinator(channel: channel) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        // JS bridge handler — recebe comandos do cluster.html
        config.userContentController.add(context.coordinator, name: "obd")

        // Injeta sentinela `window._nativeBridge` ANTES do HTML rodar.
        // Cluster.html detecta esse symbol e troca a fonte de dados de
        // WebSocket → bridge nativo.
        let initScript = WKUserScript(
            source: """
            window._nativeBridge = {
              source: 'havalobd-ios',
              _latest: {},
              update: function(payload) {
                if (!payload || typeof payload !== 'object') return;
                Object.assign(this._latest, payload);
                if (typeof window.applyNativeSnapshot === 'function') {
                  window.applyNativeSnapshot(this._latest);
                }
              },
              postAction: function(action, data) {
                try {
                  window.webkit.messageHandlers.obd.postMessage(
                    Object.assign({ action: action }, data || {})
                  );
                } catch (e) {}
              }
            };
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(initScript)

        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.navigationDelegate = context.coordinator

        // Carrega cluster.html do bundle (subpasta WebAssets)
        if let url = Bundle.main.url(forResource: "cluster", withExtension: "html",
                                     subdirectory: "WebAssets") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else if let url = Bundle.main.url(forResource: "cluster", withExtension: "html") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            let html = """
            <html><body style='background:#000;color:#fff;font-family:system-ui;padding:40px;text-align:center'>
            <h2>cluster.html não encontrado no bundle</h2>
            <p>Verifique se WebAssets foi adicionado como Resource no target.</p>
            </body></html>
            """
            web.loadHTMLString(html, baseURL: nil)
        }

        // Conecta o canal de injeção de dados assim que o WebView é criado.
        // O channel só começa a pushar depois do didFinish navigation.
        DispatchQueue.main.async {
            channel.attach(webView: web, elm: elm)
        }
        return web
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // No-op — atualizações são via OBDBridgeChannel.
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let channel: OBDBridgeChannel
        init(channel: OBDBridgeChannel) { self.channel = channel }

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let dict = message.body as? [String: Any] else { return }
            let action = dict["action"] as? String ?? ""
            switch action {
            case "open_nav":
                let app = (dict["app"] as? String ?? "waze").lowercased()
                let schemes: [String: String] = [
                    "waze":  "waze://?navigate=yes",
                    "gmaps": "comgooglemaps://",
                    "apple": "maps://",
                ]
                if let s = schemes[app], let url = URL(string: s) {
                    DispatchQueue.main.async {
                        UIApplication.shared.open(url, options: [:], completionHandler: nil)
                    }
                }
            default:
                print("[obd-bridge] ação desconhecida: \(action)")
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("[obd-bridge] cluster.html carregado — marca channel ready")
            DispatchQueue.main.async {
                Task { @MainActor in self.channel.markReady() }
            }
        }
    }
}
