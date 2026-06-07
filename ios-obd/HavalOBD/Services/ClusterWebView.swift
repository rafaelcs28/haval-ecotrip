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
    @EnvironmentObject var publisher: BridgePublisher
    // Intervalo do pisca-alerta (Config do iPad) — injetado no JS como window._hazardIntervalMs.
    @AppStorage("hazardIntervalSec") private var hazardIntervalSec: Double = 2.0
    // Tamanho do botão de pisca (px) — aplicado via CSS var --haz-size. Default 248 (dobro do antigo).
    @AppStorage("hazardBtnSize") private var hazardBtnSize: Double = 248

    func makeCoordinator() -> Coordinator { Coordinator(channel: channel, publisher: publisher) }

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
        // Transparente pra MapKit nativo aparecer por baixo (na área do mapa)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
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
        // Propaga o intervalo do pisca-alerta (muda quando o slider da Config muda).
        let ms = Int((hazardIntervalSec * 1000).rounded())
        webView.evaluateJavaScript("window._hazardIntervalMs = \(ms);", completionHandler: nil)
        // Propaga o tamanho do botão de pisca via CSS var.
        let sz = Int(hazardBtnSize.rounded())
        webView.evaluateJavaScript("document.documentElement.style.setProperty('--haz-size', '\(sz)px');", completionHandler: nil)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let channel: OBDBridgeChannel
        let publisher: BridgePublisher
        init(channel: OBDBridgeChannel, publisher: BridgePublisher) {
            self.channel = channel
            self.publisher = publisher
        }

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let dict = message.body as? [String: Any] else { return }
            let action = dict["action"] as? String ?? ""
            let value = dict["value"] as? String ?? ""
            switch action {
            case "open_nav_modal":
                DispatchQueue.main.async {
                    self.channel.navRequestId += 1
                }
            // Comandos drive (POST HTTP no bridge, mesmo padrão do PWA)
            case "drive_mode_set":
                Task { await publisher.postCommand(path: "/api/drive-mode", body: ["mode": Int(value) ?? 0]) }
            case "power_reserve_set":   // sub-modo HEV: 1=inteligente, 2=prioritário
                Task { await publisher.postCommand(path: "/api/power-reserve", body: ["mode": Int(value) ?? 1]) }
            case "charge_soc_target_set":   // % de bateria a preservar (20..80)
                Task { await publisher.postCommand(path: "/api/charge-soc-target", body: ["pct": Int(value) ?? 50]) }
            case "terrain_mode_set":
                Task { await publisher.postCommand(path: "/api/terrain-mode", body: ["mode": Int(value) ?? 0]) }
            case "regen_level_set":
                Task { await publisher.postCommand(path: "/api/regen-level", body: ["level": Int(value) ?? 0]) }
            case "steer_mode_set":
                Task { await publisher.postCommand(path: "/api/steer-mode", body: ["mode": Int(value) ?? 0]) }
            case "one_pedal_set":
                Task { await publisher.postCommand(path: "/api/one-pedal", body: ["enable": value == "true" ? 1 : 0]) }
            case "esp_set":
                Task { await publisher.postCommand(path: "/api/esp", body: ["enable": value == "true" ? 1 : 0]) }
            case "hvac_ac":
                // Bridge tem /api/hvac/:control que espera body.value (string '0' ou '1')
                Task { await publisher.postCommand(path: "/api/hvac/ac_enable", body: ["value": value]) }
            case "hvac_set":
                // Menu de AC: control vem em dict["control"], valor em value.
                let control = (dict["control"] as? String) ?? ""
                if !control.isEmpty {
                    Task { await publisher.postCommand(path: "/api/hvac/\(control)", body: ["value": value]) }
                }
            case "hvac_power":
                // ON/OFF inteligente (APK guarda o fan anterior). value = "0" | "1".
                Task { await publisher.postCommand(path: "/api/hvac/power", body: ["value": value]) }
            case "hazard":
                // Pisca-alerta (4 setas): alterna car.light_setting.sport_mode_light.
                // O cluster chama a cada ~1s com value "0"/"1".
                Task { await publisher.postCommand(path: "/api/hazard", body: ["value": value]) }
            case "vehicle_shade":
                // Cortina elétrica: level 0..100 (0=fechada).
                Task { await publisher.postCommand(path: "/api/vehicle/shade", body: ["level": Int(value) ?? 0]) }
            case "vehicle_skylight":
                // Teto solar: 0=fechado · 200=ventilação · 10..100=abertura.
                Task { await publisher.postCommand(path: "/api/vehicle/skylight", body: ["level": Int(value) ?? 0]) }
            case "vehicle_windows":
                // Vidros (todos): 1=fechado · 3=entreaberto · 0=aberto.
                Task { await publisher.postCommand(path: "/api/vehicle/window-all", body: ["level": Int(value) ?? 1]) }
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
            // Garante body.native — caso IIFE do cluster.html não tenha
            // detectado o WKWebView corretamente.
            webView.evaluateJavaScript("document.body && document.body.classList.add('native');") { _, err in
                if let err = err { print("[obd-bridge] add('native') erro: \(err)") }
                else { print("[obd-bridge] body.native injetado via Swift") }
            }
            // Intervalo do pisca-alerta (Config do iPad) — injeta após carregar.
            let hzSec = UserDefaults.standard.object(forKey: "hazardIntervalSec") as? Double ?? 2.0
            let hzMs = Int((hzSec * 1000).rounded())
            webView.evaluateJavaScript("window._hazardIntervalMs = \(hzMs);", completionHandler: nil)
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
