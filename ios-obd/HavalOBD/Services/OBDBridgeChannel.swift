import Foundation
import WebKit
import Combine

/// Bombeia os dados do ELM327 pro WebView a 5Hz (suave pros gauges) +
/// estado completo a 1Hz (pra widgets menos críticos).
///
/// Em paralelo, mantém a publicação MQTT pro bridge como fallback/sync.
/// Tudo offline-first: o app NÃO depende de internet pra funcionar.
@MainActor
final class OBDBridgeChannel: ObservableObject {
    weak var webView: WKWebView?
    private weak var elm: ELM327?
    private var bag = Set<AnyCancellable>()
    private var fastTimer: Timer?
    private var slowTimer: Timer?

    func attach(webView: WKWebView, elm: ELM327) {
        self.webView = webView
        self.elm = elm
        // Loop rápido (5Hz) — só os fast PIDs (RPM, speed, motor_kw)
        fastTimer?.invalidate()
        fastTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pushFast() }
        }
        // Loop lento (1Hz) — payload completo com todas as samples
        slowTimer?.invalidate()
        slowTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pushFull() }
        }
    }

    deinit {
        fastTimer?.invalidate(); slowTimer?.invalidate()
    }

    /// Push apenas dos PIDs marcados como `fast` — sem JSON encoding pesado.
    private func pushFast() {
        guard let webView = webView, let elm = elm, !elm.samples.isEmpty else { return }
        let fastIds: Set<String> = ["rpm", "speed_kmh", "motor_power_kw", "engine_rpm",
                                    "throttle_pct", "battery_current_a", "soc_pct"]
        var dict: [String: Any] = ["__fast": true]
        for id in fastIds {
            if let s = elm.samples[id], let v = s.value {
                dict[id] = v
            }
        }
        guard dict.count > 1 else { return }
        injectSnapshot(dict, on: webView)
    }

    /// Push completo a 1Hz com todos os PIDs ativos.
    private func pushFull() {
        guard let webView = webView, let elm = elm else { return }
        var dict: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "source": "obd_ble",
            "obd_connected": elm.bt.state == .ready,
            "obd_initialized": elm.initialized,
        ]
        for (key, sample) in elm.samples {
            if let v = sample.value { dict[key] = v }
        }
        injectSnapshot(dict, on: webView)
    }

    private func injectSnapshot(_ dict: [String: Any], on webView: WKWebView) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
              let json = String(data: data, encoding: .utf8) else { return }
        // evaluateJavaScript tem que ser na main thread (já estamos por @MainActor)
        let js = "if (window._nativeBridge && window._nativeBridge.update) window._nativeBridge.update(\(json));"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }
}
