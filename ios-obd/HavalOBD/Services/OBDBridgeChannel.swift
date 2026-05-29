import Foundation
import WebKit
import Combine

/// Bombeia os dados do ELM327 pro WebView a 5Hz (suave pros gauges) +
/// estado completo a 1Hz (pra widgets menos críticos).
///
/// Tem 2 gates de segurança:
///   • webViewReady — só pusha depois do cluster.html terminar de carregar
///                    (didFinish navigation). Antes disso, evaluateJavaScript
///                    falha porque window._nativeBridge ainda não existe.
///   • completionHandler do evaluateJavaScript silencia erros pra não poluir
///     logs (e impedir o WebKit de spamear o Console).
@MainActor
final class OBDBridgeChannel: ObservableObject {
    weak var webView: WKWebView?
    private weak var elm: ELM327?
    private var fastTimer: Timer?
    private var slowTimer: Timer?
    @Published var webViewReady = false
    @Published var pushCount = 0
    @Published var lastError: String?

    func attach(webView: WKWebView, elm: ELM327) {
        self.webView = webView
        self.elm = elm
        // NÃO inicia os timers ainda — só após webViewReady = true
    }

    /// Chamado pelo ClusterWebView quando o cluster.html termina de carregar.
    func markReady() {
        guard !webViewReady else { return }
        webViewReady = true
        // Loop rápido — só os fast PIDs (RPM, speed, motor_kw)
        fastTimer?.invalidate()
        fastTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pushFast() }
        }
        // Loop lento — payload completo
        slowTimer?.invalidate()
        slowTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pushFull() }
        }
        print("[OBDBridgeChannel] webView ready — push iniciado")
    }

    func stop() {
        fastTimer?.invalidate(); fastTimer = nil
        slowTimer?.invalidate(); slowTimer = nil
        webViewReady = false
    }

    /// Mapeia PIDs do OBD pros nomes que o cluster.html consome.
    /// Sem isso, dados chegam no JS mas com chaves erradas — gauges ficam vazios.
    private func translateForCluster(_ raw: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in raw {
            out[k] = v
            // Aliases — mesmo dado com chaves diferentes pro cluster pegar
            switch k {
            case "rpm":
                out["engine_rpm"] = v
            case "fuel_level_pct":
                // Cluster usa fuel_l (litros). Tank Haval = 55L.
                if let pct = v as? Double { out["fuel_l"] = pct / 100.0 * 55.0 }
            case "control_voltage":
                out["batt_12v_v"] = v
            case "ect_c":
                out["engine_temp_c"] = v
            default:
                break
            }
        }
        return out
    }

    private func pushFast() {
        guard webViewReady, let webView = webView, let elm = elm, !elm.samples.isEmpty else { return }
        let fastIds: Set<String> = ["rpm", "speed_kmh", "motor_power_kw", "engine_rpm",
                                    "throttle_pct", "battery_current_a", "soc_pct"]
        var dict: [String: Any] = ["__fast": true]
        for id in fastIds {
            if let s = elm.samples[id], let v = s.value {
                dict[id] = v
            }
        }
        guard dict.count > 1 else { return }
        injectSnapshot(translateForCluster(dict), on: webView)
    }

    private func pushFull() {
        guard webViewReady, let webView = webView, let elm = elm else { return }
        var dict: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "source": "obd_ble",
            "obd_connected": elm.bt.state == .ready,
            "obd_initialized": elm.initialized,
        ]
        for (key, sample) in elm.samples {
            if let v = sample.value { dict[key] = v }
        }
        injectSnapshot(translateForCluster(dict), on: webView)
    }

    private func injectSnapshot(_ dict: [String: Any], on webView: WKWebView) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
              let json = String(data: data, encoding: .utf8) else { return }
        let js = "if (window._nativeBridge && window._nativeBridge.update) window._nativeBridge.update(\(json));"
        // Completion handler SILENCIA erros (sem propagar pro Console).
        // Erros comuns:
        //   • WKErrorDomain Code=5 (JavaScript exception)
        //   • WKErrorDomain Code=14 (frame load interrupted) — durante reload
        webView.evaluateJavaScript(js) { [weak self] _, error in
            if let error = error {
                let msg = (error as NSError).localizedDescription
                self?.lastError = msg
            } else {
                self?.pushCount &+= 1
                self?.lastError = nil
            }
        }
    }
}
