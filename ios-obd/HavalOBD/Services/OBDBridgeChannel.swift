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
    private weak var location: LocationManager?
    private var fastTimer: Timer?
    private var slowTimer: Timer?
    @Published var webViewReady = false
    @Published var pushCount = 0
    @Published var lastError: String?
    /// Contador incrementado quando o cluster pede pra abrir a navegação Apple Maps.
    /// RootView observa via onChange e apresenta o NavigationModalView.
    /// Usar Int em vez de Bool evita race condition de reset.
    @Published var navRequestId: Int = 0
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

    func bind(location: LocationManager) {
        self.location = location
    }

    /// Injeta dados vindos do bridge (não-OBD: trip, preços, charging) no
    /// cluster.html. Chamado pelo BridgePublisher quando recebe MQTT em
    /// haval/ecotrip/cluster_extra. Marca-os com `__from_bridge` pra debug.
    func injectExtra(_ dict: [String: Any]) {
        guard webViewReady, let webView = webView, !dict.isEmpty else { return }
        var payload = dict
        payload["__from_bridge"] = true
        injectSnapshot(payload, on: webView)
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
        // Velocidade: SÓ do carro (OBD 010D). O GPS do iPad foi descartado — dava
        // picos absurdos (81, 272 km/h). Só seta speed_kmh se tiver leitura OBD;
        // senão deixa o CAN do APK (LAN/cloud) mandar.
        if let o = raw["speed_kmh_obd"] as? Double, o >= 0 {
            out["speed_kmh"] = o
        }
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

        // E007 (Cell voltages total) é o pack voltage REAL — soma das 96 células.
        // E006 ("HV battery voltage") reporta ~149V, que é outra coisa (talvez
        // tensão pós-relé ou sub-bus). E007 ~347V bate com SOC × 96 células.
        if let v = raw["pack_cells_total_v"] {
            out["pack_voltage_v"] = v   // sobrescreve E006 no estado do cluster
        }
        // ── Motor power derivado ──
        // P = V × I / 1000. Sem battery_current_a, deixa nil (sem fallback
        // ruim — anteriores estavam gerando -151 kW absurdo).
        let voltageForPower = (raw["pack_cells_total_v"] as? Double) ?? (raw["pack_voltage_v"] as? Double)
        if let v = voltageForPower, let i = raw["battery_current_a"] as? Double {
            let kw = v * i / 1000.0
            // Clamp em ±200 kW (motor real do H6 PHEV: ~184 kW pico).
            // Valor fora disso é certeza de erro de parser.
            if abs(kw) < 250 {
                out["motor_power_kw"] = kw
            }
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
        // IDs reais do registry (não os aliases do cluster) — sem nada disso,
        // pushFast não pega NADA do elm.samples e o fallback heurístico
        // explode com valores absurdos.
        let fastIds: Set<String> = [
            "rpm", "speed_kmh_obd", "throttle_pct", "control_voltage",
            "soc_pct", "battery_current_a",
            "pack_voltage_v", "pack_cells_total_v",
            "gmcu_motor_rpm", "tmcu_motor_rpm",
        ]
        let now = Date()
        var dict: [String: Any] = ["__fast": true]
        for id in fastIds {
            if let s = elm.samples[id], let v = s.value {
                // Drop sample stale (> 3s) — evita valores travados enquanto
                // ECU dormindo (típico em modo elétrico parado)
                if now.timeIntervalSince(s.ts) < 3.0 {
                    dict[id] = v
                }
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
        let now = Date()
        for (key, sample) in elm.samples {
            if let v = sample.value {
                // Samples velhos (> 10s) NÃO entram — evita display de dados
                // congelados quando ECU adormece (especialmente speed/rpm
                // do ECM em modo elétrico)
                if now.timeIntervalSince(sample.ts) < 10.0 {
                    dict[key] = v
                }
            }
        }
        // Mapa usa o GPS do CARRO (publicado pelo APK → bridge), NÃO o do iPad.
        // Antes injetávamos gps_lat/gps_lng do CoreLocation aqui e isso brigava
        // com o GPS do carro (chega via bridge), fazendo o marker pular entre dois
        // pontos. A velocidade segue podendo usar o GPS do iPad (speed_kmh_gps).
        if let loc = location {
            if let s = loc.speedKmh { dict["speed_kmh_gps"] = s }
        }
        if debugMode {
            let now = Date()
            var debugList: [[String: Any]] = []
            // GPS no debug pra diagnosticar se autorização/fix está chegando
            if let loc = location {
                let gpsAuth = loc.authorized ? "ok" : "negado"
                debugList.append([
                    "id": "_gps_status", "value": gpsAuth, "unit": "", "age_ms": 0,
                ])
                if let la = loc.lat, let lo = loc.lng {
                    let lastFix = loc.lastFixAt.map { Int(now.timeIntervalSince($0) * 1000) } ?? 0
                    debugList.append([
                        "id": "_gps_lat", "value": la, "unit": "°", "age_ms": lastFix,
                    ])
                    debugList.append([
                        "id": "_gps_lng", "value": lo, "unit": "°", "age_ms": lastFix,
                    ])
                    if let s = loc.speedKmh {
                        debugList.append([
                            "id": "_gps_speed", "value": s, "unit": "km/h", "age_ms": lastFix,
                        ])
                    } else {
                        debugList.append([
                            "id": "_gps_speed", "value": "nil (-1)", "unit": "km/h", "age_ms": lastFix,
                        ])
                    }
                } else {
                    debugList.append([
                        "id": "_gps_lat", "value": "nil", "unit": "", "age_ms": 0,
                    ])
                }
            }
            for (key, sample) in elm.samples {
                if let v = sample.value {
                    var item: [String: Any] = [
                        "id": key,
                        "value": v,
                        "unit": sample.unit,
                        "age_ms": Int(now.timeIntervalSince(sample.ts) * 1000),
                    ]
                    if let h = sample.rawHex { item["raw"] = h }
                    debugList.append(item)
                }
            }
            debugList.sort { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") }
            dict["_debug_obd"] = true
            dict["_debug_pids"] = debugList
            // PIDs que responderam mas parser falhou (bytes inesperados)
            var failed: [[String: Any]] = []
            for (id, raw) in elm.failedPids {
                failed.append(["id": id, "raw": raw])
            }
            failed.sort { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") }
            dict["_debug_failed"] = failed
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
