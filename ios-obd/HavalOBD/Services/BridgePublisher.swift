import Foundation
import CocoaMQTT
import CommonCrypto
import Network

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
    private var lanWsConn: NWConnection?
    private var lanWsHeartbeat: Timer?
    private var lanHttpPollTimer: Timer?
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
    /// Decide se ativa LAN (WS + HTTP poll local) ou volta pro modo cloud.
    /// Se mDNS falhar, usa URL manual configurada pelo user (fallback).
    func updateLanUrl(_ url: URL?) {
        // Prioridade: URL do mDNS > URL manual configurada
        let resolved: URL? = url ?? parseLanManualUrl()
        let prev = lanUrl
        lanUrl = resolved
        if useLanWhenAvailable, let u = resolved {
            if prev?.absoluteString != u.absoluteString {
                activeSource = "lan"
                // WS via NWConnection (única forma que funciona em LAN no iOS —
                // URLSession é bloqueado pelo Local Network Privacy)
                connectLanWs(to: u)
            }
        } else {
            disconnectLanWs()
            stopLanHttpPoll()
            activeSource = "cloud"
        }
    }

    // HTTP poll local NÃO funciona (URLSession bloqueado pelo Local Network
    // Privacy do iOS). Mantido só como no-op pra não quebrar callers.
    private func startLanHttpPoll(base: URL) {
        // Sem fallback HTTP — se o WS NWConnection cair, vai pra cloud.
        if !lanWsConnected { activeSource = "cloud" }
    }
    private func stopLanHttpPoll() {
        lanHttpPollTimer?.invalidate()
        lanHttpPollTimer = nil
    }

    /// Parse defensivo — quebra IP:porta manual pra evitar qualquer surpresa
    /// do URL() do iOS. Aceita "192.168.x.x", "192.168.x.x:8088",
    /// "http://192.168.x.x:8088".
    private func parseLanManualUrl() -> URL? {
        // Sanitize agressivo — remove whitespace, controle, qualquer não-printável
        var s = lanManualUrl.unicodeScalars
            .filter { $0.value > 0x20 && $0.value < 0x7F }
            .map { Character($0) }
            .reduce("") { $0 + String($1) }
        print("[lan parse] raw='\(lanManualUrl)' cleaned='\(s)' bytes=\(Array(lanManualUrl.utf8))")
        guard !s.isEmpty else { return nil }
        // Tira scheme se já tiver
        if s.lowercased().hasPrefix("http://") { s = String(s.dropFirst(7)) }
        else if s.lowercased().hasPrefix("https://") { s = String(s.dropFirst(8)) }
        // Separa host e port manualmente
        let parts = s.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let host = String(parts[0])
        let port: Int = parts.count > 1 ? (Int(parts[1]) ?? 8088) : 8088
        guard !host.isEmpty else {
            print("[lan parse] host vazio")
            return nil
        }
        let urlStr = "http://\(host):\(port)"
        let url = URL(string: urlStr)
        print("[lan parse] resultado: '\(urlStr)' → \(url?.absoluteString ?? "nil")")
        return url
    }

    /// Testa conectividade com URL manual. Chamado pelo botão "Testar" das Settings.
    func testLanManualUrl() async {
        guard let url = parseLanManualUrl() else {
            lanTestResult = "❌ Não consegui montar URL — veja log Xcode"
            return
        }
        lanTestResult = "⏳ Testando \(url.absoluteString)…"
        let stateUrl = URL(string: "\(url.absoluteString)/api/state") ?? url
        var req = URLRequest(url: stateUrl)
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

    // ── WebSocket pro APK local — via Network framework (NWConnection) ────
    // URLSession dá timeout em IPs locais por causa do Local Network Privacy
    // do iOS, mesmo com permissão concedida. NWConnection usa a mesma stack do
    // NWBrowser (que funciona pra mDNS), então respeita a permissão certo.
    // NanoWSD aceita upgrade WS em qualquer path, então conecta na raiz "/".
    private func connectLanWs(to baseUrl: URL) {
        disconnectLanWs()
        guard let host = baseUrl.host else {
            print("[lan ws] baseUrl sem host: \(baseUrl)")
            return
        }
        let port = UInt16(baseUrl.port ?? 8088)

        let wsOpts = NWProtocolWebSocket.Options()
        wsOpts.autoReplyPing = true
        // Path do upgrade HTTP — NanoWSD aceita qualquer, usamos /ws/state
        wsOpts.setAdditionalHeaders([("Host", "\(host):\(port)")])

        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(wsOpts, at: 0)

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        let conn = NWConnection(to: endpoint, using: params)
        lanWsConn = conn

        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self = self else { return }
                switch state {
                case .ready:
                    print("[lan ws] NWConnection ready — WS conectado")
                    self.receiveNwWs(conn)
                case .failed(let err):
                    print("[lan ws] NWConnection falhou: \(err) — HTTP poll local")
                    self.lanWsConnected = false
                    self.lanWsConn = nil
                    if let u = self.lanUrl { self.startLanHttpPoll(base: u) }
                case .cancelled:
                    self.lanWsConnected = false
                default: break
                }
            }
        }
        conn.start(queue: .main)
        print("[lan ws] tentando NWConnection WS em ws://\(host):\(port)/")
    }

    private func disconnectLanWs() {
        lanWsHeartbeat?.invalidate(); lanWsHeartbeat = nil
        lanWsConn?.cancel()
        lanWsConn = nil
        lanWsConnected = false
    }

    private func receiveNwWs(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, context, _, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                Task { @MainActor in
                    if !self.lanWsConnected {
                        self.lanWsConnected = true
                        self.stopLanHttpPoll()
                        print("[lan ws] 1ª msg recebida — WS push ativo, HTTP poll parado")
                    }
                    if let obj = try? JSONSerialization.jsonObject(with: data),
                       let dict = obj as? [String: Any] {
                        self.onClusterExtra?(dict)
                    }
                }
            }
            if let error = error {
                Task { @MainActor in
                    print("[lan ws] receive err: \(error) — HTTP poll local")
                    self.lanWsConnected = false
                    if let u = self.lanUrl { self.startLanHttpPoll(base: u) }
                }
                return
            }
            // Continua recebendo enquanto a conexão estiver viva
            if conn.state == .ready { self.receiveNwWs(conn) }
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

    /// POST genérico — se WS LAN conectado, manda comando via WS (NWConnection,
    /// ~5ms). Senão usa Tailscale (Mac mini, ~200ms). NÃO tenta HTTP LAN via
    /// URLSession (bloqueado pelo Local Network Privacy do iOS).
    func postCommand(path: String, body: [String: Any]) async {
        if useLanWhenAvailable, lanWsConnected, lanWsConn != nil {
            // Extrai o comando do path: "/api/esp" → "esp", "/api/drive-mode" → "drive_mode"
            let cmd = path.replacingOccurrences(of: "/api/", with: "")
                .replacingOccurrences(of: "-", with: "_")
            if sendLanCommandWs(cmd: cmd, body: body) { return }
            print("[lan ws] envio de comando falhou — fallback Tailscale")
        }
        await postCommandCloud(path: path, body: body)
    }

    /// Envia comando pelo WS (frame texto JSON). APK processa em onMessage.
    private func sendLanCommandWs(cmd: String, body: [String: Any]) -> Bool {
        guard let conn = lanWsConn, lanWsConnected else { return false }
        var payload = body
        payload["__cmd"] = cmd
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "cmd", metadata: [meta])
        conn.send(content: data, contentContext: ctx, isComplete: true, completion: .contentProcessed { err in
            if let err = err { print("[lan ws] send cmd erro: \(err)") }
            else { print("[lan ws] cmd '\(cmd)' enviado via WS") }
        })
        return true
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
