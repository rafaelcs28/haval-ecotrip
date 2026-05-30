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
    @Published var bridgeBaseUrl: String = UserDefaults.standard.string(forKey: "bridge_base_url") ?? "https://mac-mini.tailacc6e7.ts.net"
    @Published var bridgeAuthToken: String = UserDefaults.standard.string(forKey: "bridge_auth_token") ?? ""

    // ── LAN direta (descoberta via mDNS do APK no carro) ──────────────────
    /// URL HTTP do APK na LAN. Preenchido pelo `LocalDiscovery` quando o iPad
    /// está na mesma rede do carro. nil → não disponível, usa Tailscale.
    @Published var lanUrl: URL? = nil
    /// Toggle do user: usar LAN quando disponível. Default ON.
    @Published var useLanWhenAvailable: Bool =
        UserDefaults.standard.object(forKey: "use_lan_when_available") as? Bool ?? true
    /// Fonte ativa atual — "lan" ou "cloud". Pro indicador na topbar.
    @Published var activeSource: String = "cloud"
    /// True quando WS local tá conectado.
    @Published var lanWsConnected: Bool = false
    /// URL manual configurada pelo user (fallback quando mDNS não funciona).
    /// Ex: "http://192.168.1.100:8080" ou só "192.168.1.100".
    @Published var lanManualUrl: String =
        UserDefaults.standard.string(forKey: "lan_manual_url") ?? ""
    /// Última mensagem do "Testar conexão" — exibida nas Settings.
    @Published var lanTestResult: String = ""

    private var mqtt: CocoaMQTT?
    private weak var elm: ELM327?
    private var publishTimer: Timer?
    private var httpPollTimer: Timer?
    private var lanWsTask: URLSessionWebSocketTask?
    private var lanWsHeartbeat: Timer?
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
        UserDefaults.standard.set(useLanWhenAvailable, forKey: "use_lan_when_available")
        restartHttpPoll()
    }

    /// Chamado pelo `LocalDiscovery` quando o APK aparece/some na LAN.
    /// Decide se ativa WS local ou volta pro modo cloud.
    /// Se mDNS falhar, usa URL manual configurada pelo user (fallback).
    func updateLanUrl(_ url: URL?) {
        // Prioridade: URL do mDNS > URL manual configurada
        let resolved: URL? = url ?? parseLanManualUrl()
        let prev = lanUrl
        lanUrl = resolved
        if useLanWhenAvailable, let u = resolved {
            if prev?.absoluteString != u.absoluteString {
                connectLanWs(to: u)
                activeSource = "lan"
            }
        } else {
            disconnectLanWs()
            activeSource = "cloud"
        }
    }

    /// Aceita "192.168.x.x", "192.168.x.x:8080", "http://192.168.x.x" — normaliza.
    /// Versão sem URLComponents (que falha em URLs IPv4 raw em alguns iOS).
    private func parseLanManualUrl() -> URL? {
        var s = lanManualUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        print("[lan parse] input='\(s)'")
        guard !s.isEmpty else { return nil }
        // Adiciona scheme se faltar
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
            s = "http://\(s)"
        }
        // URL() direto — funciona com IPv4 + porta sem URLComponents
        guard let url = URL(string: s) else {
            print("[lan parse] URL() retornou nil pra '\(s)'")
            return nil
        }
        // Sem porta? Adiciona 8080
        if url.port == nil, let host = url.host {
            let scheme = url.scheme ?? "http"
            return URL(string: "\(scheme)://\(host):8080")
        }
        return url
    }

    /// Testa conectividade com URL manual. Chamado pelo botão "Testar" das Settings.
    func testLanManualUrl() async {
        guard let url = parseLanManualUrl() else {
            lanTestResult = "❌ URL inválida"
            return
        }
        lanTestResult = "⏳ Testando…"
        var req = URLRequest(url: url.appendingPathComponent("/api/state"))
        req.timeoutInterval = 3
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) {
                lanTestResult = "✅ Conectado em \(url.absoluteString)"
                UserDefaults.standard.set(lanManualUrl, forKey: "lan_manual_url")
                updateLanUrl(nil)  // re-resolve usando manual
            } else {
                lanTestResult = "⚠ APK respondeu HTTP \(status)"
            }
        } catch {
            lanTestResult = "❌ Sem resposta: \(error.localizedDescription)"
        }
    }

    func clearLanManualUrl() {
        lanManualUrl = ""
        UserDefaults.standard.set("", forKey: "lan_manual_url")
        lanTestResult = ""
        updateLanUrl(nil)
    }

    /// Toggle nas Settings. Quando vira OFF, força modo cloud.
    func setUseLan(_ on: Bool) {
        useLanWhenAvailable = on
        UserDefaults.standard.set(on, forKey: "use_lan_when_available")
        if on {
            if let u = lanUrl { connectLanWs(to: u); activeSource = "lan" }
        } else {
            disconnectLanWs()
            activeSource = "cloud"
        }
    }

    // ── WebSocket pro APK local ──────────────────────────────────────────
    private func connectLanWs(to baseUrl: URL) {
        disconnectLanWs()
        // Constrói ws:// manualmente (URLComponents.url retorna nil em alguns iOS
        // pra IPv4 com porta — mesmo bug do parseLanManualUrl)
        guard let host = baseUrl.host else {
            print("[lan ws] baseUrl sem host: \(baseUrl)")
            return
        }
        let port = baseUrl.port ?? 8080
        guard let wsUrl = URL(string: "ws://\(host):\(port)/ws/state") else {
            print("[lan ws] não consegui montar ws URL pra host=\(host) port=\(port)")
            return
        }

        let task = URLSession.shared.webSocketTask(with: wsUrl)
        lanWsTask = task
        task.resume()
        receiveLanWs(task)

        // Heartbeat ping a cada 15s
        lanWsHeartbeat?.invalidate()
        lanWsHeartbeat = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.lanWsTask?.send(.string("ping")) { err in
                    if let err = err { print("[lan ws] ping err: \(err)") }
                }
            }
        }
        lanWsConnected = true
        print("[lan ws] conectando em \(wsUrl)")
    }

    private func disconnectLanWs() {
        lanWsHeartbeat?.invalidate(); lanWsHeartbeat = nil
        lanWsTask?.cancel(with: .goingAway, reason: nil)
        lanWsTask = nil
        lanWsConnected = false
    }

    private func receiveLanWs(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let msg):
                Task { @MainActor in
                    self.handleLanWsMessage(msg)
                    self.receiveLanWs(task)
                }
            case .failure(let err):
                Task { @MainActor in
                    print("[lan ws] receive err: \(err.localizedDescription) — caindo pra cloud")
                    self.disconnectLanWs()
                    self.activeSource = "cloud"
                }
            }
        }
    }

    private func handleLanWsMessage(_ msg: URLSessionWebSocketTask.Message) {
        switch msg {
        case .string(let txt):
            if txt == "pong" { return }
            guard let data = txt.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data),
                  let dict = obj as? [String: Any] else { return }
            self.onClusterExtra?(dict)
        case .data(let data):
            guard let obj = try? JSONSerialization.jsonObject(with: data),
                  let dict = obj as? [String: Any] else { return }
            self.onClusterExtra?(dict)
        @unknown default: break
        }
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

    /// POST genérico — prefere LAN (APK direto, ~5ms) e cai pra Tailscale
    /// (Mac mini, ~200ms) se LAN falhar ou estiver desabilitada.
    func postCommand(path: String, body: [String: Any]) async {
        // Tenta LAN se ativo (path /api/X vira /api/cmd/X no APK)
        if useLanWhenAvailable, let base = lanUrl {
            let cmdPath = path.replacingOccurrences(of: "/api/", with: "/api/cmd/")
                .replacingOccurrences(of: "-", with: "_")
            let lanOk = await postCommandLan(base: base, path: cmdPath, body: body)
            if lanOk { return }
            print("[lan http] POST falhou — fallback Tailscale")
        }
        await postCommandCloud(path: path, body: body)
    }

    private func postCommandLan(base: URL, path: String, body: [String: Any]) async -> Bool {
        guard let url = URL(string: path, relativeTo: base) else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 2
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let txt = String(data: data, encoding: .utf8) ?? ""
            print("[lan http] POST \(path) → \(status) \(txt.prefix(120))")
            return (200..<300).contains(status)
        } catch {
            print("[lan http] POST \(path) erro: \(error.localizedDescription)")
            return false
        }
    }

    private func postCommandCloud(path: String, body: [String: Any]) async {
        let base = bridgeBaseUrl.hasSuffix("/") ? String(bridgeBaseUrl.dropLast()) : bridgeBaseUrl
        guard !bridgeAuthToken.isEmpty,
              let url = URL(string: "\(base)\(path)") else {
            print("[bridge http] POST cancelado: token/url ausente")
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 6
        req.setValue("Bearer \(bridgeAuthToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let txt = String(data: data, encoding: .utf8) ?? ""
            print("[bridge http] POST \(path) → \(status) \(txt.prefix(120))")
        } catch {
            print("[bridge http] POST \(path) erro: \(error.localizedDescription)")
        }
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
