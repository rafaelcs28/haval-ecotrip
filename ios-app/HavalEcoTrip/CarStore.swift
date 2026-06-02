//
//  CarStore.swift
//  Camada de dados NATIVA do app (migração PWA→SwiftUI, Bloco 0).
//
//  Consome o MESMO bridge da PWA: WebSocket /ws?token=<token> pra estado ao vivo,
//  com fallback de polling GET /api/state. Mantém um snapshot [String: Any] (o
//  bridge devolve um JSON grande, com tipos mistos String/Number) e expõe
//  acessores tipados e tolerantes. Comandos via POST /api/<path>.
//
//  Reusa Settings.bridgeURL / Settings.bridgeToken (App Group), iguais à PWA.
//

import Foundation
import Combine
import CoreLocation

@MainActor
final class CarStore: ObservableObject {
    static let shared = CarStore()

    /// Snapshot bruto do estado do carro (merge incremental das mensagens).
    @Published private(set) var raw: [String: Any] = [:]
    @Published private(set) var connected = false
    @Published private(set) var lastUpdate: Date?
    @Published private(set) var address: String = ""
    /// LAN direta com o APK do carro ativa (mesma Wi-Fi). Overlay de telemetria
    /// rápida + comandos sem passar pelo Mac mini.
    @Published private(set) var lanConnected = false

    private let geocoder = CLGeocoder()
    private var lastGeoCoord: CLLocationCoordinate2D?
    private var lastGeoAt: Date = .distantPast

    private var ws: URLSessionWebSocketTask?
    private var session: URLSession = .shared
    private var pollTask: Task<Void, Never>?
    private var reconnectDelay: TimeInterval = 1
    private var started = false

    // LAN
    private let lan = LANDiscovery()
    private var lanWS: URLSessionWebSocketTask?
    private var lanHostPort: (String, Int)?

    private var base: String {
        let u = Settings.bridgeURL.isEmpty ? AuthConfig.bridgeURL : Settings.bridgeURL
        return u.hasSuffix("/") ? String(u.dropLast()) : u
    }
    private var token: String { Settings.bridgeToken }

    // MARK: - Ciclo de vida

    func start() {
        guard !started, Settings.isConfigured else { return }
        started = true
        connectWS()
        startPolling()
        // LAN direta é OPCIONAL (default off). Ligar Bonjour dispara o prompt de
        // "Rede Local" do iOS; se negado, pode bloquear a rota até o carro/bridge
        // na Wi-Fi de casa. Só liga quando o usuário ativa em Configurações.
        if UserDefaults.standard.bool(forKey: "lan_enabled") {
            lan.onResolve = { [weak self] hostPort in
                guard let self else { return }
                if let hp = hostPort { self.connectLAN(host: hp.0, port: hp.1) }
                else { self.disconnectLAN() }
            }
            lan.start()
        }
    }

    func stop() {
        started = false
        ws?.cancel(with: .goingAway, reason: nil); ws = nil
        pollTask?.cancel(); pollTask = nil
        connected = false
        lan.stop(); disconnectLAN()
    }

    // MARK: - WebSocket (ao vivo)

    private func connectWS() {
        guard started else { return }
        // ws:// pra http, wss:// pra https
        let wsBase = base
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")
        guard let url = URL(string: "\(wsBase)/ws?token=\(token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token)") else { return }
        let task = session.webSocketTask(with: url)
        ws = task
        task.resume()
        receiveLoop(task)
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                Task { @MainActor in
                    self.reconnectDelay = 1
                    self.connected = true
                    switch message {
                    case .string(let s): self.merge(s)
                    case .data(let d):   self.merge(String(data: d, encoding: .utf8) ?? "")
                    @unknown default: break
                    }
                    // continua escutando
                    if self.ws === task { self.receiveLoop(task) }
                }
            case .failure:
                Task { @MainActor in
                    self.connected = false
                    if self.ws === task { self.scheduleReconnect() }
                }
            }
        }
    }

    private func scheduleReconnect() {
        guard started else { return }
        ws = nil
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 15)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if self.started, self.ws == nil { self.connectWS() }
        }
    }

    // MARK: - Polling (fallback / cold start)

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while let self, self.started, !Task.isCancelled {
                // Só puxa por HTTP quando o WS não está fresco (evita dobrar tráfego).
                if !self.connected || (self.lastUpdate.map { Date().timeIntervalSince($0) > 5 } ?? true) {
                    await self.pollOnce()
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func pollOnce() async {
        guard let url = URL(string: "\(base)/api/state") else { return }
        var req = URLRequest(url: url); req.timeoutInterval = 6
        req.addValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await session.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
            merge(String(data: data, encoding: .utf8) ?? "")
        } catch { /* silencioso — o WS é a fonte primária */ }
    }

    // MARK: - Merge

    private func merge(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        for (k, v) in obj { raw[k] = v }
        lastUpdate = Date()
        updateAddressIfNeeded()
    }

    /// Geocodifica o endereço da posição atual — só quando move >60m e no
    /// máximo a cada 20s (CLGeocoder tem rate limit).
    private func updateAddressIfNeeded() {
        guard hasGps else { return }
        let c = coordinate
        if let last = lastGeoCoord {
            let moved = CLLocation(latitude: last.latitude, longitude: last.longitude)
                .distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
            if moved < 60 && Date().timeIntervalSince(lastGeoAt) < 20 { return }
        }
        lastGeoCoord = c; lastGeoAt = Date()
        geocoder.reverseGeocodeLocation(CLLocation(latitude: c.latitude, longitude: c.longitude)) { [weak self] places, _ in
            guard let p = places?.first else { return }
            var line = ""
            if let r = p.thoroughfare {
                line = r
                if let n = p.subThoroughfare { line += ", \(n)" }
            }
            let bairro = p.subLocality ?? p.locality ?? ""
            if !bairro.isEmpty { line = line.isEmpty ? bairro : "\(line) · \(bairro)" }
            Task { @MainActor in self?.address = line }
        }
    }

    // MARK: - LAN direta (ws://host:port/ws/state com o APK)

    private func connectLAN(host: String, port: Int) {
        if let cur = lanHostPort, cur.0 == host, cur.1 == port, lanWS != nil { return }
        disconnectLAN()
        lanHostPort = (host, port)
        guard let url = URL(string: "ws://\(host):\(port)/ws/state") else { return }
        let task = session.webSocketTask(with: url)
        lanWS = task
        task.resume()
        lanReceive(task)
    }

    private func disconnectLAN() {
        lanWS?.cancel(with: .goingAway, reason: nil); lanWS = nil
        lanHostPort = nil
        if lanConnected { lanConnected = false }
    }

    private func lanReceive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let msg):
                Task { @MainActor in
                    self.lanConnected = true
                    switch msg {
                    case .string(let s): self.mergeLAN(s)
                    case .data(let d):   self.mergeLAN(String(data: d, encoding: .utf8) ?? "")
                    @unknown default: break
                    }
                    if self.lanWS === task { self.lanReceive(task) }
                }
            case .failure:
                Task { @MainActor in
                    if self.lanWS === task {
                        self.lanConnected = false; self.lanWS = nil
                        // tenta reabrir com o mesmo host (a descoberta segue ativa)
                        if let hp = self.lanHostPort, self.started {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            if self.started, self.lanWS == nil { self.connectLAN(host: hp.0, port: hp.1) }
                        }
                    }
                }
            }
        }
    }

    /// O APK serve um SUBCONJUNTO RAW (sem GPS/fuel/trip). Sobrepõe só as chaves
    /// de telemetria rápida com semântica idêntica à do cloud; remapeia as poucas
    /// com nome diferente; ignora o resto (cloud continua dono).
    private static let lanPassthrough: Set<String> = [
        "speed_kmh", "motor_power_kw", "engine_rpm", "batt_power_pct", "steering_angle",
        "gear", "odometer_km", "soc_pct", "battery_current_a", "batt_12v_pct",
        "charge_power_kw", "charge_remaining_min", "outside_temp", "inside_temp",
        "hvac_driver_temp", "hvac_passenger_temp", "hvac_fan_speed", "hvac_cycle_mode",
        "hvac_acmax", "hvac_anion", "hvac_aqs", "hvac_heating", "hvac_front_defrost",
        "hvac_rear_defrost", "hvac_auto_defrost", "hvac_blower_mode", "hvac_power_mode",
        "drive_mode", "power_reserve", "charge_soc_target", "terrain_mode",
        "regen_level", "steer_mode", "one_pedal", "esp_enable",
    ]
    private static let lanRename: [String: String] = [
        "ac_state": "hvac_ac_enable", "hvac_sync_enable": "hvac_sync",
        "hvac_auto_enable": "hvac_auto", "seat_vent_drv": "hvac_seat_vent_drv",
        "seat_vent_pass": "hvac_seat_vent_pass",
    ]

    private func mergeLAN(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        for (k, v) in obj {
            if v is NSNull { continue }
            if Self.lanPassthrough.contains(k) { raw[k] = v }
            else if let renamed = Self.lanRename[k] { raw[renamed] = v }
        }
        lastUpdate = Date()
    }

    /// Envia comando pela LAN se conectado. `cmd` no formato do APK (ex.: "drive_mode",
    /// "hvac/power"). Retorna true se despachou pela LAN.
    private func sendLAN(_ cmd: String, _ value: Any) -> Bool {
        guard lanConnected, let ws = lanWS else { return false }
        let payload: [String: Any] = ["__cmd": cmd, "value": value]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let s = String(data: data, encoding: .utf8) else { return false }
        ws.send(.string(s)) { _ in }
        return true
    }

    // MARK: - Acessores tolerantes (o JSON mistura String e Number)

    func num(_ key: String) -> Double {
        switch raw[key] {
        case let d as Double: return d
        case let i as Int:    return Double(i)
        case let s as String: return Double(s) ?? 0
        case let b as Bool:   return b ? 1 : 0
        default: return 0
        }
    }
    func str(_ key: String) -> String {
        switch raw[key] {
        case let s as String: return s
        case let d as Double: return String(d)
        case let i as Int:    return String(i)
        default: return ""
        }
    }
    func bool(_ key: String) -> Bool {
        switch raw[key] {
        case let b as Bool:   return b
        case let i as Int:    return i != 0
        case let d as Double: return d != 0
        case let s as String: return s == "1" || s.lowercased() == "true"
        default: return false
        }
    }
    func has(_ key: String) -> Bool { raw[key] != nil }
    /// Int ou nil (campos null = desconhecido, ex. drive_mode).
    func intOrNil(_ key: String) -> Int? {
        switch raw[key] {
        case let i as Int: return i
        case let d as Double: return Int(d)
        case let s as String: return Int(s)
        default: return nil
        }
    }

    // Atalhos usados nas telas (expandir por bloco)
    var speedKmh: Double      { max(0, num("speed_kmh")) }   // -1 = desconhecido → 0
    var motorPowerKw: Double   { num("motor_power_kw") }
    var engineRpm: Int         { max(0, Int(num("engine_rpm"))) }
    var socPct: Double         { num("soc_pct") }
    var gear: String           { str("gear") }
    /// Marcha só quando válida (P/R/N/D). "" = desconhecida (carro desligado → -1).
    var gearDisplay: String    { ["P", "R", "N", "D"].contains(gear) ? gear : "" }
    var insideTemp: Double     { num("inside_temp") }
    var outsideTemp: Double    { num("outside_temp") }
    var rangeEvKm: Double      { num("range_ev_km") }
    var chargingState: String  { str("charging_state") }
    var carOnline: Bool {
        let age = Date().timeIntervalSince1970 * 1000 - num("last_apk_ms")
        return num("last_apk_ms") > 0 && age < 60_000
    }

    // GPS (mapa do Painel)
    var lat: Double { num("gps_lat") }
    var lng: Double { num("gps_lng") }
    var hasGps: Bool { lat != 0 && lng != 0 }
    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lng) }
    var heading: Double { num("car_heading") }   // rumo (graus, 0=N) p/ girar o ícone

    // Bateria 12V, hodômetro, pneus
    var batt12vPct: Double { num("batt_12v_pct") }
    var odometerKm: Double  { num("odometer_km") }
    var tyreFL: Double { num("tyre_pressure_fl") }
    var tyreFR: Double { num("tyre_pressure_fr") }
    var tyreRL: Double { num("tyre_pressure_rl") }
    var tyreRR: Double { num("tyre_pressure_rr") }

    // Recarga
    var isCharging: Bool       { chargingState == "Carregando" }
    var chargePowerKw: Double  { num("charge_power_kw") }
    var chargeSessionKwh: Double { num("charge_session_kwh") }
    var chargeRemainingMin: Int { Int(num("charge_remaining_min")) }

    // Status de condução (leitura — controles vêm no Bloco 2)
    var driveModeLabel: String {
        switch intOrNil("drive_mode") { case 0: return "HEV"; case 1: return "Prior. EV"; case 3: return "EV Puro"; default: return "" }
    }
    var regenLabel: String {
        switch intOrNil("regen_level") { case 0: return "Normal"; case 1: return "Alto"; case 2: return "Baixo"; default: return "" }
    }
    var onePedalOn: Bool { intOrNil("one_pedal") == 1 }
    var espOn: Bool { intOrNil("esp_enable") == 1 }

    // Viagem em curso (objeto current_trip, publicado pelo carro)
    var trip: [String: Any]? { raw["current_trip"] as? [String: Any] }
    var tripActive: Bool { trip != nil }
    private func tnum(_ k: String) -> Double {
        switch trip?[k] { case let d as Double: return d; case let i as Int: return Double(i); case let s as String: return Double(s) ?? 0; default: return 0 }
    }
    var tripDistKm: Double  { tnum("distKm") }
    var tripTimeSec: Int    { Int(tnum("timeSec")) }
    var tripNetKwh: Double  { tnum("netKwh") }
    var tripFuelL: Double   { tnum("fuelL") }
    var tripAvgKmh: Double  { tnum("avgSpeedKmh") }

    // Motor térmico (autonomia + tanque)
    var rangeIceKm: Double { num("range_ice_km") }
    var fuelL: Double      { num("fuel_l") }

    // Preços atuais (p/ estimar custo de viagem — autotrips não guarda custo)
    var priceKwh: Double { num("price_kwh") }
    var priceGas: Double { num("price_gas_per_l") }

    // Custo por km (médias ponderadas + consumo rolante do state)
    var battAvgPrice: Double { num("battery_avg_price_per_kwh") }
    var tankAvgPrice: Double { num("tank_avg_price_per_l") }
    private var rolling: [String: Any]? { raw["rolling"] as? [String: Any] }
    private func roll(_ k: String) -> Double {
        switch rolling?[k] { case let d as Double: return d; case let i as Int: return Double(i); case let s as String: return Double(s) ?? 0; default: return 0 }
    }
    var kwhPer100: Double { roll("kwh_per_100km") }
    var kmPerL: Double    { roll("km_per_l") }
    var costPerKmEv: Double { (battAvgPrice > 0 ? battAvgPrice : priceKwh) * kwhPer100 / 100 }
    var costPerKmGas: Double { kmPerL > 0 ? (tankAvgPrice > 0 ? tankAvgPrice : priceGas) / kmPerL : 0 }

    // Motor / trava / AC
    var engineOn: Bool { str("engine_state") == "1" }
    /// lock_state: 'off'=trancado, 'on'=destrancado (semântica do bridge).
    var lockKnown: Bool { let s = str("lock_state"); return s == "on" || s == "off" }
    var isLocked: Bool  { str("lock_state") == "off" }
    /// AC ligado: mestre hvac_power_mode (1) OU ventilador girando — fallback ac_state.
    var acOn: Bool { hvacPowerOn || fanSpeed > 0 || str("ac_state") == "on" }

    // HVAC (campos hvac_* do estado)
    var hvacPowerOn: Bool { ["1", "on", "true"].contains(str("hvac_power_mode").lowercased()) }
    var acEnable: Bool    { bool("hvac_ac_enable") }
    var fanSpeed: Int     { Int(num("hvac_fan_speed")) }       // 0–7
    var blowerMode: Int   { Int(num("hvac_blower_mode")) }     // 0–4
    var cycleMode: Int    { Int(num("hvac_cycle_mode")) }      // 0=recirc, 1=externo
    var driverTemp: Double { num("hvac_driver_temp") }         // 16–32
    var passengerTemp: Double { num("hvac_passenger_temp") }
    var acmax: Bool       { bool("hvac_acmax") }
    var autoMode: Bool    { bool("hvac_auto") }
    var syncTemp: Bool    { bool("hvac_sync") }
    var anion: Bool       { bool("hvac_anion") }
    var aqs: Bool         { bool("hvac_aqs") }
    var heating: Bool     { bool("hvac_heating") }
    var frontDefrost: Bool { bool("hvac_front_defrost") }
    var rearDefrost: Bool  { bool("hvac_rear_defrost") }
    var autoDefrost: Bool  { bool("hvac_auto_defrost") }
    var seatVentDrv: Int  { Int(num("hvac_seat_vent_drv")) }   // 0–3
    var seatVentPass: Int { Int(num("hvac_seat_vent_pass")) }

    // Sub-modos de condução / terreno / direção
    var powerReserve: Int?    { intOrNil("power_reserve") }    // 1=Inteligente, 2=Prioritário
    var chargeSocTarget: Int  { Int(num("charge_soc_target")) }// 20–80
    var terrainMode: Int?     { intOrNil("terrain_mode") }     // 0/1/2/3/4/5/11
    var steerMode: Int?       { intOrNil("steer_mode") }       // 0=Normal,1=Sport,2=Conforto

    // Portas / janelas / teto abertos ('on' = aberto)
    private func openLabels(_ map: [(String, String)]) -> [String] {
        map.filter { str($0.0) == "on" }.map { $0.1 }
    }
    var openings: [String] {
        openLabels([
            ("door_fl", "Porta diant. esq."), ("door_fr", "Porta diant. dir."),
            ("door_rl", "Porta tras. esq."),  ("door_rr", "Porta tras. dir."),
            ("door_trunk", "Porta-malas"),
            ("window_fl", "Vidro diant. esq."), ("window_fr", "Vidro diant. dir."),
            ("window_rl", "Vidro tras. esq."),  ("window_rr", "Vidro tras. dir."),
            ("sunroof", "Teto solar"),
        ])
    }

    // MARK: - Comandos (POST /api/<path>)

    @discardableResult
    func command(_ path: String, body: [String: Any]) async -> Bool {
        guard let url = URL(string: "\(base)\(path)") else { return false }
        var req = URLRequest(url: url); req.httpMethod = "POST"; req.timeoutInterval = 8
        req.addValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (_, resp) = try await session.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch { return false }
    }

    // Atalhos de comando (mesmos endpoints/payloads do PWA)
    @discardableResult func action(_ name: String) async -> Bool {
        await command("/api/action/\(name)", body: [:])
    }
    // Comandos suportados pela LAN vão pelo WS local (ws __cmd) quando conectado;
    // senão caem no POST cloud. Trava/motor (action) NÃO existem na LAN → só cloud.
    @discardableResult func setDriveMode(_ mode: Int) async -> Bool {
        if sendLAN("drive_mode", mode) { return true }
        return await command("/api/drive-mode", body: ["mode": mode])
    }
    @discardableResult func setRegen(_ level: Int) async -> Bool {
        if sendLAN("regen_level", level) { return true }
        return await command("/api/regen-level", body: ["level": level])
    }
    @discardableResult func setOnePedal(_ on: Bool) async -> Bool {
        if sendLAN("one_pedal", on ? 1 : 0) { return true }
        return await command("/api/one-pedal", body: ["enable": on ? 1 : 0])
    }
    @discardableResult func setEsp(_ on: Bool) async -> Bool {
        if sendLAN("esp", on ? 1 : 0) { return true }
        return await command("/api/esp", body: ["enable": on ? 1 : 0])
    }
    @discardableResult func setAcPower(_ on: Bool) async -> Bool {
        if sendLAN("hvac/power", on ? 1 : 0) { return true }
        return await command("/api/hvac/power", body: ["value": on ? 1 : 0])
    }
    /// Pisca-alerta (4 setas). Sem estado legível → controlado por toggle local.
    @discardableResult func setHazard(_ on: Bool) async -> Bool {
        if sendLAN("hazard", on ? 1 : 0) { return true }
        return await command("/api/hazard", body: ["value": on ? 1 : 0])
    }
    @discardableResult func setPowerReserve(_ mode: Int) async -> Bool {
        if sendLAN("power_reserve", mode) { return true }
        return await command("/api/power-reserve", body: ["mode": mode])
    }
    @discardableResult func setChargeSocTarget(_ pct: Int) async -> Bool {
        if sendLAN("charge_soc_target", pct) { return true }
        return await command("/api/charge-soc-target", body: ["pct": pct])
    }
    @discardableResult func setTerrain(_ mode: Int) async -> Bool {
        if sendLAN("terrain_mode", mode) { return true }
        return await command("/api/terrain-mode", body: ["mode": mode])
    }
    @discardableResult func setSteer(_ mode: Int) async -> Bool {
        if sendLAN("steer_mode", mode) { return true }
        return await command("/api/steer-mode", body: ["mode": mode])
    }
    /// HVAC genérico: LAN __cmd "hvac/<control>" ou POST /api/hvac/<control>.
    @discardableResult func setHvac(_ control: String, _ value: Double) async -> Bool {
        if sendLAN("hvac/\(control)", value) { return true }
        return await command("/api/hvac/\(control)", body: ["value": value])
    }
    @discardableResult func setHvac(_ control: String, on: Bool) async -> Bool {
        if sendLAN("hvac/\(control)", on ? 1 : 0) { return true }
        return await command("/api/hvac/\(control)", body: ["value": on ? 1 : 0])
    }
}
