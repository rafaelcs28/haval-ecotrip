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
    /// Modo debug — quando ON, snapshot inclui lista crua de PIDs lidos.
    /// O cluster.html renderiza overlay flutuante com tabela id/value/unit/age.
    @Published var debugMode: Bool = UserDefaults.standard.bool(forKey: "haval_obd_debug") {
        didSet { UserDefaults.standard.set(debugMode, forKey: "haval_obd_debug") }
    }

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
    /// Mapeamentos confirmados via OBDb/Haval-Jolion-HEV (mesma plataforma Lemon B30).
    private func translateForCluster(_ raw: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in raw { out[k] = v }

        // ── Aliases pros nomes que o cluster.html espera ──
        if let v = raw["rpm"]                    { out["engine_rpm"] = v }
        if let v = raw["speed_kmh_obd"]          { out["speed_kmh"] = v }
        if let v = raw["control_voltage"]        { out["batt_12v_v"] = v }
        if let v = raw["oil_temp_c"]             { out["engine_temp_c"] = v }   // melhor proxy disponível
        if let v = raw["fuel_level_pct_22"]      { out["fuel_level_pct"] = v }
        if let v = raw["fuel_level_l_22"]        { out["fuel_l"] = v }
        else if let pct = raw["fuel_level_pct_22"] as? Double {
            out["fuel_l"] = pct / 100.0 * 55.0   // tanque H6 PHEV ≈ 55L
        }
        // Motor speed: cluster.html usa *_motor_speed; registry usa *_motor_rpm
        if let v = raw["gmcu_motor_rpm"]         { out["gmcu_motor_speed"] = v }
        if let v = raw["tmcu_motor_rpm"]         { out["tmcu_motor_speed"] = v }

        // ── Motor power derivado: P = V × I / 1000 ──
        // Bateria descarregando (I positiva) → motor_power_kw positivo (consumo)
        // Bateria recarregando (I negativa) → motor_power_kw negativo (regen)
        if let v = raw["pack_voltage_v"] as? Double,
           let i = raw["battery_current_a"] as? Double {
            out["motor_power_kw"] = v * i / 1000.0
        }

        // ── Derivados de estado ──
        // engine_state: motor a combustão ligado se RPM > 200 (idle ≈ 700)
        if let rpm = raw["rpm"] as? Double {
            out["engine_state"] = rpm > 200 ? "running" : "off"
        }
        // rolling: carro em movimento se velocidade > 1 km/h
        if let kmh = raw["speed_kmh_obd"] as? Double {
            out["rolling"] = kmh > 1
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
        if debugMode {
            let now = Date()
            var debugList: [[String: Any]] = []
            for (key, sample) in elm.samples {
                if let v = sample.value {
                    debugList.append([
                        "id": key,
                        "value": v,
                        "unit": sample.unit,
                        "age_ms": Int(now.timeIntervalSince(sample.ts) * 1000),
                    ])
                }
            }
            debugList.sort { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") }
            dict["_debug_obd"] = true
            dict["_debug_pids"] = debugList
        } else {
            dict["_debug_obd"] = false
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
