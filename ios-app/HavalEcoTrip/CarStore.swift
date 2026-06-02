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

    private var ws: URLSessionWebSocketTask?
    private var session: URLSession = .shared
    private var pollTask: Task<Void, Never>?
    private var reconnectDelay: TimeInterval = 1
    private var started = false

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
    }

    func stop() {
        started = false
        ws?.cancel(with: .goingAway, reason: nil); ws = nil
        pollTask?.cancel(); pollTask = nil
        connected = false
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
}
