import Foundation
import CocoaMQTT
import CommonCrypto

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
    /// HTTP API do bridge — fonte primária de state. PWA usa GET /api/state.
    /// Ex: bridgeBaseUrl = "https://mqttrafael.duckdns.org" (sem path, sem /ws)
    @Published var bridgeBaseUrl: String = UserDefaults.standard.string(forKey: "bridge_base_url") ?? "https://mqttrafael.duckdns.org"
    @Published var bridgeAuthToken: String = UserDefaults.standard.string(forKey: "bridge_auth_token") ?? ""

    private var mqtt: CocoaMQTT?
    private weak var elm: ELM327?
    private var publishTimer: Timer?
    private var httpPollTimer: Timer?
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
        UserDefaults.standard.set(bridgeBaseUrl, forKey: "bridge_base_url")
        UserDefaults.standard.set(bridgeAuthToken, forKey: "bridge_auth_token")
        restartHttpPoll()
    }

    /// Login no bridge — POST /api/auth/login com SHA256(senha). Salva token
    /// retornado e inicia polling. Mesmo fluxo do PWA.
    @Published var loginError: String?
    @Published var loggingIn: Bool = false
    @Published var needs2FA: Bool = false   // true quando server pediu TOTP
    func login(password: String, totp: String = "") async {
        let base = bridgeBaseUrl.hasSuffix("/") ? String(bridgeBaseUrl.dropLast()) : bridgeBaseUrl
        guard let url = URL(string: "\(base)/api/auth/login") else {
            loginError = "URL inválida"; return
        }
        await MainActor.run { self.loggingIn = true; self.loginError = nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let hash = Self.sha256Hex(password)
        var body: [String: Any] = ["password_hash": hash]
        if !totp.isEmpty { body["totp_code"] = totp }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                await MainActor.run { self.loginError = "Resposta inválida (status \(status))"; self.loggingIn = false }
                return
            }
            if status == 200, let token = obj["token"] as? String {
                await MainActor.run {
                    self.bridgeAuthToken = token
                    self.saveConfig()    // já chama restartHttpPoll
                    self.loggingIn = false
                    self.loginError = nil
                    self.needs2FA = false
                }
            } else if status == 401, (obj["error"] as? String) == "totp_required" {
                await MainActor.run {
                    self.needs2FA = true
                    self.loggingIn = false
                    self.loginError = "Digite o código 2FA"
                }
            } else if status == 401, (obj["error"] as? String) == "invalid_totp" {
                await MainActor.run {
                    self.needs2FA = true
                    self.loggingIn = false
                    self.loginError = "Código 2FA inválido"
                }
            } else {
                let err = (obj["error"] as? String) ?? "erro \(status)"
                await MainActor.run { self.loginError = err; self.loggingIn = false }
            }
        } catch {
            await MainActor.run {
                self.loginError = error.localizedDescription
                self.loggingIn = false
            }
        }
    }
    private static func sha256Hex(_ s: String) -> String {
        let data = Data(s.utf8)
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { ptr in
            _ = CC_SHA256(ptr.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// HTTP poll do /api/state do bridge — fonte ÚNICA de state pro cluster.
    /// Mesma estratégia do PWA: GET /api/state com Bearer token a cada 1s.
    func restartHttpPoll() {
        httpPollTimer?.invalidate()
        httpPollTimer = nil
        guard !bridgeBaseUrl.isEmpty, !bridgeAuthToken.isEmpty else {
            print("[bridge http] URL/token vazios — poll inativo")
            return
        }
        // Dispara imediato + a cada 1s
        Task { await fetchState() }
        httpPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { await self?.fetchState() }
        }
        print("[bridge http] poll iniciado em \(bridgeBaseUrl)/api/state")
    }

    private func fetchState() async {
        let base = bridgeBaseUrl.hasSuffix("/") ? String(bridgeBaseUrl.dropLast()) : bridgeBaseUrl
        guard let url = URL(string: "\(base)/api/state") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3
        req.setValue("Bearer \(bridgeAuthToken)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                print("[bridge http] status não-200: \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
                return
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data),
                  let dict = obj as? [String: Any] else { return }
            await MainActor.run { self.onClusterExtra?(dict) }
        } catch {
            // Silent — só primeiro erro com timeout
        }
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
        // Desativado: app agora é receive-only (puxa state do servidor).
        // Mantido o método pra não quebrar callers.
    }

    /// Publica um comando MQTT (ligar A/C, mudar drive mode, etc).
    /// Tópicos comuns: haval/ecotrip/cmd/hvac/ac_enable, .../charge_limit, etc.
    func publishCommand(topic: String, value: String) {
        guard let m = mqtt, connected else {
            print("[bridge] não conectado, comando descartado: \(topic) = \(value)")
            return
        }
        m.publish(topic, withString: value, qos: .qos1, retained: false)
        print("[bridge] cmd publicado: \(topic) = \(value)")
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
                // Subscribe geral em haval/ecotrip/# — recebe TODOS os tópicos
                // de telemetria, sem precisar listar individualmente. Filtros
                // (skip comandos, history, etc) acontecem no handler.
                mqtt.subscribe("haval/ecotrip/#", qos: .qos0)
                print("[bridge] subscribed em haval/ecotrip/#")
            }
        }
    }
    func mqtt(_ mqtt: CocoaMQTT, didPublishMessage message: CocoaMQTTMessage, id: UInt16) {}
    func mqtt(_ mqtt: CocoaMQTT, didPublishAck id: UInt16) {}
    func mqtt(_ mqtt: CocoaMQTT, didReceiveMessage message: CocoaMQTTMessage, id: UInt16) {
        guard let str = message.string else { return }
        let topic = message.topic
        // Só interessa tópicos diretos de telemetria. Skips:
        //   ha/* (comandos HA), cmd/* (comandos), trip_a/b, trips/history,
        //   lifetime/*, charging/history — esses são dados históricos ou
        //   comandos, não state em tempo real.
        let suffix = topic.replacingOccurrences(of: "haval/ecotrip/", with: "")
        if suffix.hasPrefix("ha/") || suffix.hasPrefix("cmd/") ||
           suffix.hasPrefix("trip_a/") || suffix.hasPrefix("trip_b/") ||
           suffix.contains("/history") || suffix.hasPrefix("lifetime/") ||
           suffix == "status" || suffix == "last_update" || suffix == "app_version" ||
           suffix == "obd/snapshot" {
            return
        }
        var dict: [String: Any] = [:]

        // Tópico especial: current_trip = JSON
        if suffix == "current_trip" {
            if let data = str.data(using: .utf8),
               let obj  = try? JSONSerialization.jsonObject(with: data),
               let trip = obj as? [String: Any] {
                dict["current_trip"] = trip
            }
        }
        // charging_state vem como string ("Carregando", "Direção", "Parado")
        else if suffix == "charging_state" {
            let isCharging = str.lowercased().contains("carreg") || str.lowercased() == "charging"
            dict["charging_state"] = isCharging ? 1 : 0
            dict["charging_state_text"] = str
        }
        // Default: parse como Double (a maioria é número). Fallback: string.
        else if let v = Double(str) {
            dict[suffix] = v
        } else {
            dict[suffix] = str
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
