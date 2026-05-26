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
          },
          setDeviceId: function(id) {
            window.webkit.messageHandlers.haval.postMessage({ action: 'setDeviceId', deviceId: id });
          }
        };
        """
        config.userContentController.addUserScript(WKUserScript(
            source: bridgeJS, injectionTime: .atDocumentStart, forMainFrameOnly: false))

        let web = WKWebView(frame: .zero, configuration: config)
        web.allowsBackForwardNavigationGestures = true
        web.scrollView.bounces = false
        web.navigationDelegate = context.coordinator

        // Long-press com 3 dedos por 1s abre configurações nativas.
        // Adicionado direto na WKWebView porque SwiftUI .onLongPressGesture
        // não chega através dela (a WebView consome todos os toques).
        let lp = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleThreeFingerLongPress(_:)))
        lp.minimumPressDuration = 1.0
        lp.numberOfTouchesRequired = 3
        lp.delegate = context.coordinator
        web.addGestureRecognizer(lp)
        // WKWebView no iOS bloqueia alert/confirm/prompt JS por padrão. Sem
        // uiDelegate, chamadas retornam false silenciosamente e botões como
        // "Limpar histórico" (que confirma com confirm()) ficam inertes.
        web.uiDelegate = context.coordinator
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
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate, UIGestureRecognizerDelegate {
        let manager: ActivityManager
        init(manager: ActivityManager) { self.manager = manager }

        @objc func handleThreeFingerLongPress(_ gr: UILongPressGestureRecognizer) {
            guard gr.state == .began else { return }
            NotificationCenter.default.post(name: .openHavalSettings, object: nil)
        }

        func gestureRecognizer(_ gr: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            return true
        }

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let action = body["action"] as? String else { return }
            Task { @MainActor in
                switch action {
                case "startLiveActivity": await manager.start()
                case "stopLiveActivity":  await manager.stop()
                case "openSettings":      NotificationCenter.default.post(name: .openHavalSettings, object: nil)
                case "setDeviceId":
                    if let id = body["deviceId"] as? String, !id.isEmpty {
                        Settings.notifDeviceId = id
                    }
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

        // ── JS dialogs: alert / confirm / prompt ─────────────────────────────
        // Sem esses delegates, WKWebView ignora silenciosamente os 3 e botões
        // do PWA que dependem deles (ex: confirm() de "Limpar histórico de
        // notificações", "Remover dispositivo" etc.) ficam inertes.

        private func topController() -> UIViewController? {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let window = scenes.flatMap { $0.windows }.first(where: { $0.isKeyWindow }) ?? scenes.first?.windows.first
            var top = window?.rootViewController
            while let presented = top?.presentedViewController { top = presented }
            return top
        }

        func webView(_ webView: WKWebView,
                     runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping () -> Void) {
            // Guard obrigatório: sem isso, se topController() for nil (app em
            // transição), o completionHandler nunca é chamado e o WKWebView
            // congela todo o JavaScript permanentemente até o app ser morto.
            guard let vc = topController() else { completionHandler(); return }
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
            vc.present(alert, animated: true)
        }

        func webView(_ webView: WKWebView,
                     runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (Bool) -> Void) {
            guard let vc = topController() else { completionHandler(false); return }
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancelar", style: .cancel) { _ in completionHandler(false) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
            vc.present(alert, animated: true)
        }

        func webView(_ webView: WKWebView,
                     runJavaScriptTextInputPanelWithPrompt prompt: String,
                     defaultText: String?,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (String?) -> Void) {
            guard let vc = topController() else { completionHandler(nil); return }
            let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
            alert.addTextField { tf in tf.text = defaultText }
            alert.addAction(UIAlertAction(title: "Cancelar", style: .cancel) { _ in completionHandler(nil) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
                completionHandler(alert.textFields?.first?.text)
            })
            vc.present(alert, animated: true)
        }
    }
}

extension Notification.Name {
    static let openHavalSettings = Notification.Name("HavalEcoTrip.openSettings")
}
