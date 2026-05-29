import SwiftUI
import WebKit

/// Notificação postada quando o usuário clica no botão Navegar do cluster.
/// O RootView ouve e apresenta o NavigationModalView (Apple Maps nativo).
extension Notification.Name {
    static let openNavigation = Notification.Name("openNavigation")
}

/// WebView fullscreen que hospeda o `cluster.html` (mesmo do PWA, copiado pro
/// bundle). Canal JS bidirecional:
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
        // JS bridge handler — recebe comandos do cluster.html (window.webkit.messageHandlers.obd)
        config.userContentController.add(context.coordinator, name: "obd")
        // NOTA: NÃO injetamos _nativeBridge via WKUserScript .atDocumentStart
        // porque em loadFileURL às vezes não dispara. Em vez disso, injetamos
        // via evaluateJavaScript dentro do didFinish navigation (Coordinator).

        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.navigationDelegate = context.coordinator
        // Hostname mock pra debug
        if #available(iOS 16.4, *) { web.isInspectable = true }

        if let url = Bundle.main.url(forResource: "cluster", withExtension: "html",
                                     subdirectory: "WebAssets") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else if let url = Bundle.main.url(forResource: "cluster", withExtension: "html") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            let html = """
            <html><body style='background:#000;color:#fff;font-family:system-ui;padding:40px;text-align:center'>
            <h2>cluster.html não encontrado no bundle</h2>
            </body></html>
            """
            web.loadHTMLString(html, baseURL: nil)
        }

        // Liga o channel — ele só começa a pushar depois do didFinish + injeção do bridge.
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
            case "open_nav_modal":
                print("[obd-bridge] open_nav_modal recebido — incrementando navRequestId")
                DispatchQueue.main.async {
                    self.channel.navRequestId += 1
                }
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
            // INJEÇÃO DO BRIDGE — feita aqui (não via WKUserScript) pra
            // funcionar com loadFileURL.
            let initJs = """
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
            true;
            """
            webView.evaluateJavaScript(initJs) { [weak self] result, error in
                if let error = error {
                    print("[obd-bridge] ERRO injetando _nativeBridge: \(error)")
                } else {
                    print("[obd-bridge] _nativeBridge injetado com sucesso")
                    Task { @MainActor in self?.channel.markReady() }
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("[obd-bridge] navegação FALHOU: \(error)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            print("[obd-bridge] navegação provisória FALHOU: \(error)")
        }
    }
}
