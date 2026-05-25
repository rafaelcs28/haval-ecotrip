//
//  PwaWebView.swift
//  Wrapper de WKWebView que carrega o PWA inteiro. JS bridge permite que o
//  próprio PWA dispare ações nativas (iniciar/parar Live Activity).
//
//  Como o PWA chama do JS:
//    if (window.webkit?.messageHandlers?.haval) {
//      window.webkit.messageHandlers.haval.postMessage({ action: 'startLiveActivity' });
//    }
//
import SwiftUI
import WebKit

struct PwaWebView: UIViewRepresentable {
    let url: URL
    let manager: ActivityManager

    func makeCoordinator() -> Coordinator {
        Coordinator(manager: manager)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        // Persistente: cookies, localStorage, IndexedDB ficam guardados entre
        // launches do app. Sem isso, login expira a cada open.
        config.websiteDataStore = .default()
        // Bridge JS: registra o handler "haval".
        config.userContentController.add(context.coordinator, name: "haval")

        // Injeta script auxiliar que expõe window.HavalNative.* — mais
        // ergonômico pro PWA do que chamar postMessage direto.
        let bridgeJS = """
        window.HavalNative = {
          isNative: true,
          startLiveActivity: function() {
            window.webkit.messageHandlers.haval.postMessage({ action: 'startLiveActivity' });
          },
          stopLiveActivity: function() {
            window.webkit.messageHandlers.haval.postMessage({ action: 'stopLiveActivity' });
          },
          openSettings: function() {
            window.webkit.messageHandlers.haval.postMessage({ action: 'openSettings' });
          }
        };
        """
        config.userContentController.addUserScript(WKUserScript(
            source: bridgeJS, injectionTime: .atDocumentStart, forMainFrameOnly: false))

        let web = WKWebView(frame: .zero, configuration: config)
        web.allowsBackForwardNavigationGestures = true
        web.scrollView.bounces = false
        web.navigationDelegate = context.coordinator
        // User-Agent custom — o PWA pode detectar via navigator.userAgent
        // que está rodando dentro do wrapper iOS.
        web.customUserAgent = (web.value(forKey: "userAgent") as? String ?? "") + " HavalEcoTripiOS/1.0"
        web.load(URLRequest(url: url))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        // Se a URL mudou (user trocou no setup), recarrega.
        if let current = web.url, current.absoluteString != url.absoluteString {
            web.load(URLRequest(url: url))
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let manager: ActivityManager
        init(manager: ActivityManager) { self.manager = manager }

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let action = body["action"] as? String else { return }
            Task { @MainActor in
                switch action {
                case "startLiveActivity": await manager.start()
                case "stopLiveActivity":  await manager.stop()
                case "openSettings":      NotificationCenter.default.post(name: .openHavalSettings, object: nil)
                default: print("[bridge] ação desconhecida:", action)
                }
            }
        }

        // Pra links externos abrirem no Safari (não dentro do wrapper),
        // poderíamos filtrar aqui. Por enquanto deixa abrir tudo no WKWebView.
        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            print("[webview] falha:", error.localizedDescription)
        }
    }
}

extension Notification.Name {
    static let openHavalSettings = Notification.Name("HavalEcoTrip.openSettings")
}
