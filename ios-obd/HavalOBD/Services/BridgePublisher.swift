import Foundation
import CocoaMQTT

/// Publica amostras OBD pro bridge via MQTT (mesmo broker que o resto do
/// sistema usa). Topic: `haval/ecotrip/obd/snapshot` — JSON consolidado a 1Hz
/// com todos os últimos valores. Fast-lane: `haval/ecotrip/obd/<pidId>` em
/// push imediato pra pids de prioridade `.fast`.
@MainActor
final class BridgePublisher: ObservableObject {
    @Published var connected = false
    @Published var lastSentAt: Date?
    @Published var sampleCount = 0
    @Published var brokerHost = UserDefaults.standard.string(forKey: "mqtt_host") ?? "mqttrafael.duckdns.org"
    @Published var brokerPort: Int = UserDefaults.standard.integer(forKey: "mqtt_port").nonZeroOr(8883)
    @Published var brokerUser = UserDefaults.standard.string(forKey: "mqtt_user") ?? "obd_companion"
    @Published var brokerPass = UserDefaults.standard.string(forKey: "mqtt_pass") ?? ""
    @Published var topicPrefix = UserDefaults.standard.string(forKey: "mqtt_prefix") ?? "haval/ecotrip/obd"

    private var mqtt: CocoaMQTT?
    private weak var elm: ELM327?
    private var publishTimer: Timer?
    /// Callback chamado quando o bridge publica state extra (viagem em curso,
    /// preços, charging) via MQTT. Permite o cluster.html receber dados que
    /// não vêm do OBD direto.
    var onClusterExtra: (([String: Any]) -> Void)?

    func bind(_ elm: ELM327) {
        self.elm = elm
    }

    /// Conecta automaticamente se tiver credenciais salvas (host + user + senha).
    /// Chamado no boot do app — evita o usuário ter que abrir Settings toda vez.
    func autoConnectIfConfigured() {
        guard !connected else { return }
        guard !brokerHost.isEmpty, !brokerUser.isEmpty, !brokerPass.isEmpty else {
            print("[bridge] auto-connect pulado — credenciais incompletas")
            return
        }
        print("[bridge] auto-connect → \(brokerHost):\(brokerPort) como \(brokerUser)")
        connect()
    }

    func saveConfig() {
        UserDefaults.standard.set(brokerHost, forKey: "mqtt_host")
        UserDefaults.standard.set(brokerPort, forKey: "mqtt_port")
        UserDefaults.standard.set(brokerUser, forKey: "mqtt_user")
        UserDefaults.standard.set(brokerPass, forKey: "mqtt_pass")
        UserDefaults.standard.set(topicPrefix, forKey: "mqtt_prefix")
    }

    func connect() {
        saveConfig()
        let clientID = "obd-ipad-\(ProcessInfo.processInfo.globallyUniqueString.prefix(8))"
        mqtt = CocoaMQTT(clientID: clientID, host: brokerHost, port: UInt16(brokerPort))
        guard let m = mqtt else { return }
        m.username = brokerUser
        m.password = brokerPass
        m.keepAlive = 30
        m.cleanSession = true
        m.delegate = self
        m.enableSSL = (brokerPort == 8883)
        m.allowUntrustCACertificate = true
        _ = m.connect()
    }

    func disconnect() {
        publishTimer?.invalidate(); publishTimer = nil
        mqtt?.disconnect()
        connected = false
    }

    private func startPublishLoop() {
        publishTimer?.invalidate()
        publishTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flushSnapshot() }
        }
    }

    private func flushSnapshot() {
        guard connected else { return }
        var dict: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "source": "obd_ble",
        ]
        // Mesmo sem samples, publica heartbeat — valida o caminho MQTT e
        // permite o bridge atualizar last_obd_ms enquanto o usuário ainda
        // não conectou o ELM327.
        if let elm = elm {
            dict["obd_connected"] = (elm.bt.state == .ready ? 1.0 : 0.0)
            dict["obd_initialized"] = (elm.initialized ? 1.0 : 0.0)
            dict["obd_samples"] = Double(elm.samples.count)
            for (key, sample) in elm.samples {
                if let v = sample.value { dict[key] = v }
            }
        }
        guard let json = try? JSONSerialization.data(withJSONObject: dict, options: []),
              let str = String(data: json, encoding: .utf8) else { return }
        mqtt?.publish(topicPrefix + "/snapshot", withString: str, qos: .qos0, retained: false)
        sampleCount &+= 1
        lastSentAt = Date()
    }
}

extension BridgePublisher: CocoaMQTTDelegate {
    func mqtt(_ mqtt: CocoaMQTT, didReceive trust: SecTrust, completionHandler: @escaping (Bool) -> Void) { completionHandler(true) }
    func mqtt(_ mqtt: CocoaMQTT, didConnectAck ack: CocoaMQTTConnAck) {
        if ack == .accept {
            DispatchQueue.main.async {
                self.connected = true
                self.startPublishLoop()
                // Tópicos pra alimentar o cluster do iPad:
                // - cluster_extra: payload JSON consolidado (publicado pelo bridge novo)
                // - current_trip: viagem em curso (publicado direto pelo APK do carro)
                // - charging_state / charge_power_kw / preços: campos individuais
                let topics = [
                    "haval/ecotrip/cluster_extra",
                    "haval/ecotrip/current_trip",
                    "haval/ecotrip/charging_state",
                    "haval/ecotrip/charge_power_kw",
                    "haval/ecotrip/price_kwh",
                    "haval/ecotrip/price_gas_per_l",
                    "haval/ecotrip/battery_avg_price_per_kwh",
                    "haval/ecotrip/tank_avg_price_per_l",
                ]
                for t in topics {
                    mqtt.subscribe(t, qos: .qos0)
                }
                print("[bridge] subscribed em \(topics.count) tópicos")
            }
        }
    }
    func mqtt(_ mqtt: CocoaMQTT, didPublishMessage message: CocoaMQTTMessage, id: UInt16) {}
    func mqtt(_ mqtt: CocoaMQTT, didPublishAck id: UInt16) {}
    func mqtt(_ mqtt: CocoaMQTT, didReceiveMessage message: CocoaMQTTMessage, id: UInt16) {
        guard let str = message.string else { return }
        var dict: [String: Any] = [:]
        switch message.topic {
        case "haval/ecotrip/cluster_extra":
            // JSON consolidado (bridge novo)
            if let data = str.data(using: .utf8),
               let obj  = try? JSONSerialization.jsonObject(with: data),
               let d = obj as? [String: Any] {
                dict = d
            }
        case "haval/ecotrip/current_trip":
            // Viagem em curso publicada DIRETO pelo APK do carro
            if let data = str.data(using: .utf8),
               let obj  = try? JSONSerialization.jsonObject(with: data),
               let trip = obj as? [String: Any] {
                dict["current_trip"] = trip
            }
        case "haval/ecotrip/charging_state":
            // String "Carregando" / "Direção" / "Parado" / etc → bool numérico
            let isCharging = str.lowercased().contains("carreg") || str.lowercased() == "charging"
            dict["charging_state"] = isCharging ? 1 : 0
        case "haval/ecotrip/charge_power_kw":
            if let v = Double(str) { dict["charge_power_kw"] = v }
        case "haval/ecotrip/price_kwh":
            if let v = Double(str) { dict["price_kwh"] = v }
        case "haval/ecotrip/price_gas_per_l":
            if let v = Double(str) { dict["price_gas_per_l"] = v }
        case "haval/ecotrip/battery_avg_price_per_kwh":
            if let v = Double(str) { dict["battery_avg_price_per_kwh"] = v }
        case "haval/ecotrip/tank_avg_price_per_l":
            if let v = Double(str) { dict["tank_avg_price_per_l"] = v }
        default:
            return
        }
        if dict.isEmpty { return }
        DispatchQueue.main.async {
            self.onClusterExtra?(dict)
        }
    }
    func mqtt(_ mqtt: CocoaMQTT, didSubscribeTopics success: NSDictionary, failed: [String]) {}
    func mqtt(_ mqtt: CocoaMQTT, didUnsubscribeTopics topics: [String]) {}
    func mqttDidPing(_ mqtt: CocoaMQTT) {}
    func mqttDidReceivePong(_ mqtt: CocoaMQTT) {}
    func mqttDidDisconnect(_ mqtt: CocoaMQTT, withError err: Error?) {
        DispatchQueue.main.async { self.connected = false }
    }
}

private extension Int {
    func nonZeroOr(_ fallback: Int) -> Int { self == 0 ? fallback : self }
}
