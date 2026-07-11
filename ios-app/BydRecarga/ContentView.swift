//
//  ContentView.swift
//  Grasi Recarga — duas abas:
//   • Recarga: dashboard completo do BYD Song Pro, atualiza em tempo real
//     (GET /api/songpro/status, poll 8s).
//   • Configuração: URL/token do bridge, toggle da Live Activity e botão de
//     reativar o card.
//
import SwiftUI
import MapKit
import Charts

// ── Cor de acento (azul clarinho, igual à Live Activity) ─────────────────────
let spAccent = Color(red: 0.45, green: 0.75, blue: 1.0)

// ── Modelo vindo do bridge ───────────────────────────────────────────────────
struct SongProStatus: Decodable {
    var soc: Double = 0
    var powerKw: Double = 0
    var sessionKwh: Double = 0
    var remainingMin: Int = 0
    var charging: Bool = false
    var finished: Bool = false
    var finishedKwh: Double = 0
    var finishedAtMs: Double = 0
    var updatedAtMs: Double = 0
    var hasData: Bool = false
    var distToPhoneKm: Double? = nil   // distância de carro até o celular do monitor
    var etaToPhoneMin: Int? = nil
    var driverName: String = ""        // feature 2: motorista identificado na ignição
    var driverDeviceId: String = ""
    var tele: Tele = Tele()

    struct Tele: Decodable {
        var soc = 0.0, socPanel = 0.0, soh = 0.0
        var powerKw = 0.0, enginePowerKw = 0.0
        var rpmFront = 0.0, rpmRear = 0.0
        var packVoltage = 0.0, batt12v = 0.0
        var cellTempMax = 0.0, cellTempMin = 0.0
        var cellVoltMax = 0.0, cellVoltMin = 0.0
        var evRangeKm = 0.0, fuelRangeKm = 0.0, fuelPct = 0.0
        var odometer = 0.0, totalDischarge = 0.0, speed = 0.0
        var carLocked = false, carOn = false, anyDoorOpen = false
        var gear = "-"
        var lat = 0.0, lng = 0.0, altitude = 0.0
        var tyrePressFL = 0.0, tyrePressFR = 0.0, tyrePressRL = 0.0, tyrePressRR = 0.0
        var tyreTempFL = 0.0, tyreTempFR = 0.0, tyreTempRL = 0.0, tyreTempRR = 0.0
        var carTime = ""
        var ts: Double = 0
    }
}

// ── Store: polling + prefs + reativar ────────────────────────────────────────
// ── Histórico de recargas ────────────────────────────────────────────────────
struct SPCharge: Decodable, Identifiable {
    var id: String
    var startMs: Double = 0
    var endMs: Double = 0
    var durationSec: Int = 0
    var socStart: Int = 0
    var socEnd: Int = 0
    var energyKwh: Double = 0
    var avgPowerKw: Double = 0
    var lat: Double = 0
    var lng: Double = 0
    var locationId: String? = nil
    var costEstimate: Double = 0
    var manual: Bool? = nil
    var date: Date { Date(timeIntervalSince1970: endMs / 1000) }
}

struct SPLocation: Decodable, Identifiable {
    var id: String
    var name: String = ""
    var lat: Double = 0
    var lng: Double = 0
    var pricePerKwh: Double = 0
    var radiusM: Double? = nil
    var free: Bool? = nil
    var configured: Bool? = nil   // false = local novo (precisa configurar)
    var isFree: Bool { free ?? false }
    var needsConfig: Bool { configured == false }
    var radius: Double { radiusM ?? 200 }
}

struct ChargesResponse: Decodable {
    var charges: [SPCharge] = []
    var locations: [SPLocation] = []
}

// Feature 10: viagem encerrada com score de condução + motorista.
struct SPTrip: Decodable, Identifiable {
    var id: String
    var startMs: Double = 0
    var endMs: Double = 0
    var durationSec: Int = 0
    var distKm: Double = 0
    var avgSpeedKmh: Int = 0
    var startSoc: Int = 0
    var endSoc: Int = 0
    var energyKwh: Double = 0
    var startLat: Double = 0
    var startLng: Double = 0
    var endLat: Double = 0
    var endLng: Double = 0
    var driverDeviceId: String? = nil
    var driverName: String = ""
    var driveScore: Int = 0
    var harshAcc: Int = 0
    var harshBrake: Int = 0
    var date: Date { Date(timeIntervalSince1970: endMs / 1000) }
}

struct TripsResponse: Decodable {
    var trips: [SPTrip] = []
    var total: Int = 0
}

// Letra do score (igual ao Haval): A 85+, B 70+, C 55+, D 40+, E abaixo.
func bydScoreLetter(_ s: Int) -> String {
    if s >= 85 { return "A" }; if s >= 70 { return "B" }
    if s >= 55 { return "C" }; if s >= 40 { return "D" }
    return "E"
}
func bydScoreColor(_ s: Int) -> Color {
    if s >= 85 { return .green }; if s >= 70 { return .mint }
    if s >= 55 { return .yellow }; if s >= 40 { return .orange }
    return .red
}

struct ClusterSample: Identifiable {
    let id = UUID()
    let t: Date
    let speed: Double
    let power: Double   // potência de tração (kW), pode ser negativa (regen)
    let lat: Double
    let lng: Double
}

// Ponto enriquecido da trilha (linha do tempo da viagem com scrubber).
struct TrailPoint: Identifiable {
    let id = UUID()
    let t: Double      // segundos desde o início da viagem
    let lat: Double
    let lng: Double
    let spd: Double    // km/h
    let kw: Double     // potência de tração (kW, +tração/−regen)
    let soc: Double    // %
}

@MainActor
final class SongProStore: ObservableObject {
    @Published var status: SongProStatus?
    @Published var prefs: [String: Bool] = [:]
    @Published var prefsNum: [String: Int] = [:]
    @Published var prefsStr: [String: String] = [:]   // byd_role, byd_name
    @Published var busy = false
    @Published var message = ""
    @Published var history: [ClusterSample] = []   // janela de 60s pro cluster
    @Published var trail: [TrailPoint] = []         // viagem em andamento (enriquecida)
    @Published var lastTrail: [TrailPoint] = []     // última viagem encerrada
    @Published var tripStartMs: Double = 0
    @Published var tripLastMs: Double = 0
    private var polling = false
    private var fastClients = 0                     // nº de telas pedindo poll rápido
    private var tick = 0

    func startPolling() {
        guard !polling else { return }
        polling = true
        Task {
            while !Task.isCancelled {
                await fetchStatus()
                // Trilha: puxada bem mais devagar (~4s) só com o Cluster aberto —
                // ela cresce devagar e pode ser grande (viagem inteira).
                if fastClients > 0 && tick % 8 == 0 { await fetchTrail() }
                tick += 1
                // Cluster aberto → 500ms (envio do carro em movimento). Senão 8s.
                let ns: UInt64 = fastClients > 0 ? 500_000_000 : 8_000_000_000
                try? await Task.sleep(nanoseconds: ns)
            }
        }
    }

    func fetchTrail() async {
        // Busca incremental: manda quantos pontos já temos; o bridge devolve só os
        // novos (full=true só na 1ª carga ou quando a trilha reseta/nova ignição).
        let since = trail.count
        guard let req = authedRequest("/api/songpro/trail?since=\(since)") else { return }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["trail"] as? [[String: Any]] else { return }
        let pts = arr.map { Self.parseTrailPoint($0) }
        let full = (obj["full"] as? Bool) ?? true
        let newStart = (obj["tripStartMs"] as? Double) ?? 0
        if full || newStart != tripStartMs {
            trail = pts                     // 1ª carga / nova viagem → substitui
        } else if !pts.isEmpty {
            trail.append(contentsOf: pts)   // incremental → anexa só os novos
        }
        tripStartMs = newStart
        tripLastMs  = (obj["tripLastMs"] as? Double) ?? 0
    }

    // Última viagem encerrada (estática) — pra linha do tempo com o carro parado.
    func fetchLastTrip() async {
        guard let req = authedRequest("/api/songpro/last-trip") else { return }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["trail"] as? [[String: Any]] else { return }
        lastTrail = arr.map { Self.parseTrailPoint($0) }
    }

    static func parseTrailPoint(_ d: [String: Any]) -> TrailPoint {
        TrailPoint(t:   (d["t"]   as? Double) ?? 0,
                   lat: (d["lat"] as? Double) ?? 0,
                   lng: (d["lng"] as? Double) ?? 0,
                   spd: (d["spd"] as? Double) ?? 0,
                   kw:  (d["kw"]  as? Double) ?? 0,
                   soc: (d["soc"] as? Double) ?? 0)
    }

    // Distância da viagem (km) somando a trilha.
    var tripKm: Double {
        guard trail.count >= 2 else { return 0 }
        var m = 0.0
        for i in 1..<trail.count {
            let a = CLLocation(latitude: trail[i-1].lat, longitude: trail[i-1].lng)
            let b = CLLocation(latitude: trail[i].lat, longitude: trail[i].lng)
            m += b.distance(from: a)
        }
        return m / 1000
    }

    func enterFast() { fastClients += 1 }
    func exitFast()  { fastClients = max(0, fastClients - 1) }

    private func appendHistory(_ s: SongProStatus) {
        let now = Date()
        history.append(ClusterSample(t: now, speed: s.tele.speed, power: s.tele.enginePowerKw,
                                     lat: s.tele.lat, lng: s.tele.lng))
        let cutoff = now.addingTimeInterval(-60)
        history.removeAll { $0.t < cutoff }
    }

    private func authedRequest(_ path: String, method: String = "GET") -> URLRequest? {
        guard let url = URL(string: BydSettings.baseURL + path) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = method
        req.addValue("Bearer " + BydSettings.bridgeToken, forHTTPHeaderField: "Authorization")
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        return req
    }

    func fetchStatus() async {
        guard let req = authedRequest("/api/songpro/status") else { return }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let s = try? JSONDecoder().decode(SongProStatus.self, from: data) else { return }
        withAnimation(.easeInOut(duration: 0.3)) { status = s }
        appendHistory(s)
        // Ignição ligada (viagem) → localização fina; desligada → econômica.
        BydPhoneLocation.shared.setActive(s.tele.carOn)
    }

    func fetchPrefs() async {
        guard let req = authedRequest("/api/notif/prefs/" + BydSettings.deviceId) else { return }
        if let (data, resp) = try? await URLSession.shared.data(for: req),
           (resp as? HTTPURLResponse)?.statusCode == 200,
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let p = obj["prefs"] as? [String: Any] {
            var dict: [String: Bool] = [:]
            var nums: [String: Int] = [:]
            var strs: [String: String] = [:]
            for (k, v) in p {
                // Chaves numéricas (minutos/limiares) por sufixo; identidade (role/name)
                // é string; o resto é boolean.
                if k.hasSuffix("_min") || k.hasSuffix("_pct") {
                    if let n = (v as? NSNumber)?.intValue { nums[k] = n }
                } else if k == "byd_role" || k == "byd_name" {
                    if let s = v as? String { strs[k] = s }
                } else if let b = v as? Bool {
                    dict[k] = b
                }
            }
            prefs = dict
            prefsNum = nums
            prefsStr = strs
        }
    }

    func isOn(_ key: String) -> Bool { prefs[key] ?? false }
    func numValue(_ key: String, _ def: Int) -> Int { prefsNum[key] ?? def }
    func strValue(_ key: String, _ def: String = "") -> String { prefsStr[key] ?? def }

    func setPref(_ key: String, _ value: Bool) async {
        prefs[key] = value   // atualização otimista
        guard var req = authedRequest("/api/notif/prefs/" + BydSettings.deviceId, method: "POST") else { return }
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["key": key, "value": value])
        _ = try? await URLSession.shared.data(for: req)
    }

    func setPrefNum(_ key: String, _ value: Int) async {
        prefsNum[key] = value
        guard var req = authedRequest("/api/notif/prefs/" + BydSettings.deviceId, method: "POST") else { return }
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["key": key, "value": value])
        _ = try? await URLSession.shared.data(for: req)
    }

    func setPrefStr(_ key: String, _ value: String) async {
        prefsStr[key] = value
        guard var req = authedRequest("/api/notif/prefs/" + BydSettings.deviceId, method: "POST") else { return }
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["key": key, "value": value])
        _ = try? await URLSession.shared.data(for: req)
    }

    func relaunch() async {
        busy = true; defer { busy = false }
        guard var req = authedRequest("/api/la/relaunch", method: "POST") else { return }
        req.httpBody = "{}".data(using: .utf8)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else {
            message = "⚠ Falha ao reativar. Confira a conexão."; return
        }
        let arr = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["relaunched"] as? [String]
        message = (arr?.contains("song-pro") ?? false)
            ? "✓ Card reativado na tela bloqueada"
            : "Nenhuma recarga ativa no momento."
    }

    // ── Histórico de recargas ───────────────────────────────────────────────
    @Published var charges: [SPCharge] = []
    @Published var locations: [SPLocation] = []
    // Feature 10: histórico de viagens com score (cresce a cada viagem encerrada).
    @Published var trips: [SPTrip] = []

    func fetchTrips() async {
        guard let req = authedRequest("/api/songpro/trips?limit=5000") else { return }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let r = try? JSONDecoder().decode(TripsResponse.self, from: data) else { return }
        trips = r.trips
    }

    func locName(_ id: String?) -> String {
        guard let id else { return "Sem local" }
        return locations.first { $0.id == id }?.name ?? "Local"
    }
    func location(_ id: String?) -> SPLocation? {
        guard let id else { return nil }
        return locations.first { $0.id == id }
    }

    func fetchCharges() async {
        guard let req = authedRequest("/api/songpro/charges") else { return }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let r = try? JSONDecoder().decode(ChargesResponse.self, from: data) else { return }
        charges = r.charges
        locations = r.locations
    }

    func updateLocation(_ id: String, name: String, pricePerKwh: Double, free: Bool, radiusM: Int? = nil) async {
        busy = true; defer { busy = false }
        guard var req = authedRequest("/api/songpro/locations/" + id, method: "PATCH") else { return }
        var body: [String: Any] = ["name": name, "pricePerKwh": pricePerKwh, "free": free]
        if let radiusM { body["radiusM"] = radiusM }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
        await fetchCharges()
    }

    func createLocation(name: String, lat: Double, lng: Double, radiusM: Int,
                        pricePerKwh: Double, free: Bool) async {
        busy = true; defer { busy = false }
        guard var req = authedRequest("/api/songpro/locations", method: "POST") else { return }
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "name": name, "lat": lat, "lng": lng, "radiusM": radiusM,
            "pricePerKwh": pricePerKwh, "free": free,
        ])
        _ = try? await URLSession.shared.data(for: req)
        await fetchCharges()
    }

    func addManualCharge(endMs: Double, durationSec: Int, energyKwh: Double,
                         socStart: Int, socEnd: Int,
                         locationId: String?, locationName: String?,
                         pricePerKwh: Double, free: Bool) async {
        busy = true; defer { busy = false }
        guard var req = authedRequest("/api/songpro/charges", method: "POST") else { return }
        var body: [String: Any] = [
            "endMs": endMs, "durationSec": durationSec, "energyKwh": energyKwh,
            "socStart": socStart, "socEnd": socEnd, "free": free, "pricePerKwh": pricePerKwh,
        ]
        if let locationId { body["locationId"] = locationId }
        if let locationName { body["locationName"] = locationName }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
        await fetchCharges()
    }

    // Edita uma recarga existente (energia e/ou custo). Custo = override manual.
    func updateCharge(_ id: String, energyKwh: Double?, costEstimate: Double?) async {
        busy = true; defer { busy = false }
        guard var req = authedRequest("/api/songpro/charges/" + id, method: "PATCH") else { return }
        var body: [String: Any] = [:]
        if let energyKwh { body["energyKwh"] = energyKwh }
        if let costEstimate { body["costEstimate"] = costEstimate }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
        await fetchCharges()
    }
}

// ── Raiz: setup (1ª vez) → abas ──────────────────────────────────────────────
struct ContentView: View {
    @State private var configured = BydSettings.isConfigured
    @StateObject private var store = SongProStore()
    @EnvironmentObject private var deepLink: DeepLinkRouter

    var body: some View {
        Group {
            if !configured {
                NavigationStack { SetupForm(configured: $configured, store: store) }
            } else {
                TabView {
                    RecargaDashboard(store: store)
                        .tabItem { Label("Dashboard", systemImage: "bolt.car.fill") }
                    ClusterView(store: store)
                        .tabItem { Label("Cluster", systemImage: "gauge.open.with.lines.needle.33percent") }
                    HistoryView(store: store)
                        .tabItem { Label("Histórico", systemImage: "list.bullet.rectangle.fill") }
                    ConfigTab(configured: $configured, store: store)
                        .tabItem { Label("Configuração", systemImage: "gearshape.fill") }
                }
                .tint(spAccent)
                .tabBarMinimizeOnScroll()
            }
        }
        // Sheet do trajeto compartilhado (toque na LA `SharedTrip` abre aqui).
        .sheet(item: Binding(
            get: { deepLink.sharedTripToken.map { SharedTripID(token: $0) } },
            set: { v in deepLink.sharedTripToken = v?.token }
        )) { id in
            SharedTripSheet(token: id.token)
        }
        .task {
            if configured {
                BydRemoteNotifications.enable()
                BydLiveActivityPush.shared.start()
                BydPhoneLocation.shared.start()
                await store.fetchPrefs()
                store.startPolling()
            }
        }
    }
}

/// Wrapper Identifiable pra usar token de share como item de sheet.
private struct SharedTripID: Identifiable { let token: String; var id: String { token } }

// ── DASHBOARD ────────────────────────────────────────────────────────────────
struct RecargaDashboard: View {
    @ObservedObject var store: SongProStore

    var body: some View {
        NavigationStack {
            ScrollView {
                if let s = store.status, s.hasData {
                    VStack(spacing: 14) {
                        headerCard(s)
                        heroCard(s)
                        locationCard(s)
                        autonomyCard(s.tele)
                        healthCard(s.tele)
                        tyresCard(s.tele)
                        vehicleCard(s.tele)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                } else {
                    ContentUnavailableView(
                        "Sem dados do BYD ainda",
                        systemImage: "bolt.car",
                        description: Text("O dashboard aparece assim que o Song Pro enviar a primeira leitura.")
                    ).padding(.top, 60)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Dashboard")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await store.fetchStatus() }
        }
    }

    // ── Cabeçalho com marca + último envio do carro ──────────────────────────
    private func headerCard(_ s: SongProStatus) -> some View {
        let last = lastSeen(s)
        return HStack(spacing: 13) {
            ZStack {
                Circle().fill(LinearGradient(colors: [spAccent, .blue],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 50, height: 50)
                Image(systemName: "bolt.car.fill").font(.title3).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("BYD da Grasi")
                    .font(.title2.weight(.bold))
                HStack(spacing: 5) {
                    Circle().fill(last.fresh ? Color.green : Color.orange).frame(width: 7, height: 7)
                    Text("Último envio do carro \(last.text)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                // Feature 2: motorista identificado (iPhone mais próximo na ignição).
                if s.tele.carOn && !s.driverName.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "steeringwheel").font(.caption2).foregroundStyle(.blue)
                        Text("Dirigindo: \(s.driverName)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
        }
        .padding(.top, 4)
    }

    // Usa o horário do carro (carTime, UTC do MQTT); cai pro updatedAtMs se faltar.
    private func lastSeen(_ s: SongProStatus) -> (text: String, fresh: Bool) {
        var date: Date?
        if !s.tele.carTime.isEmpty {
            let f = ISO8601DateFormatter()
            date = f.date(from: s.tele.carTime)
        }
        if date == nil, s.updatedAtMs > 0 { date = Date(timeIntervalSince1970: s.updatedAtMs / 1000) }
        guard let d = date else { return ("—", false) }
        let secs = Int(Date().timeIntervalSince(d))
        let fresh = secs < 120
        let rel: String
        if secs < 5            { rel = "agora" }
        else if secs < 60      { rel = "há \(secs)s" }
        else if secs < 3600    { rel = "há \(secs/60)min" }
        else if secs < 86400   { rel = "há \(secs/3600)h" }
        else                   { rel = "há \(secs/86400)d" }
        let df = DateFormatter(); df.dateFormat = "HH:mm:ss"
        return ("\(rel) · \(df.string(from: d))", fresh)
    }

    // ── Hero: anel de SOC (bateria atual) + estado + última recarga ───────────
    private func heroCard(_ s: SongProStatus) -> some View {
        // Ligado (dirigindo) tem prioridade sobre "recarga finalizada" e "repouso".
        let on = s.tele.carOn
        let stateText = s.charging ? "Carregando"
                      : (on ? "Veículo ligado"
                      : (s.finished ? "Recarga finalizada" : "Em repouso"))
        let stateIcon = s.charging ? "bolt.fill"
                      : (on ? "car.fill"
                      : (s.finished ? "checkmark.circle.fill" : "powersleep"))
        // Cores por estado: verde=carregando · amarelo=ligado/movimento · azul=repouso/desligado.
        let accent: Color = s.charging ? .green : (on ? .yellow : .blue)
        return Card {
            VStack(spacing: 14) {
                HStack {
                    Label(stateText, systemImage: stateIcon)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(accent)
                    Spacer()
                    if s.charging && s.remainingMin > 0 {
                        Text("faltam \(remaining(s.remainingMin))")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 22) {
                    BatteryRing(soc: s.soc, accent: accent, charging: s.charging)
                        .frame(width: 124, height: 124)
                    VStack(alignment: .leading, spacing: 14) {
                        bigMetric(s.charging ? String(format: "%.1f", s.powerKw) : String(format: "%.0f", s.tele.evRangeKm),
                                  unit: s.charging ? "kW" : "km EV",
                                  icon: s.charging ? "bolt.fill" : "leaf.fill", color: accent)
                        if s.charging {
                            bigMetric(String(format: "%.2f", s.sessionKwh), unit: "kWh sessão",
                                      icon: "bolt.batteryblock.fill", color: .secondary)
                        } else {
                            bigMetric(String(format: "%.0f", s.tele.soh), unit: "% saúde",
                                      icon: "heart.fill", color: .pink)
                        }
                    }
                    Spacer()
                }
                // Última recarga concluída (data/hora + kWh) — quando não carregando.
                if !s.charging && s.finishedAtMs > 0 {
                    Divider().overlay(Color.white.opacity(0.08))
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill").font(.caption).foregroundStyle(.green)
                        Text("Última recarga: \(fmtDateTime(s.finishedAtMs)) · \(String(format: "%.2f", s.finishedKwh)) kWh")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
        }
    }

    private func fmtDateTime(_ ms: Double) -> String {
        guard ms > 0 else { return "—" }
        let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR"); f.dateFormat = "dd/MM HH:mm"
        return f.string(from: Date(timeIntervalSince1970: ms / 1000))
    }

    // ── Localização (mini-mapa escuro em tempo real) + distância até o celular ──
    @ViewBuilder private func locationCard(_ s: SongProStatus) -> some View {
        if s.tele.lat != 0 && s.tele.lng != 0 {
            Card {
                CardTitle("Localização", icon: "location.fill")
                BydMiniMap(lat: s.tele.lat, lng: s.tele.lng)
                    .frame(height: 170)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                if let km = s.distToPhoneKm, let min = s.etaToPhoneMin {
                    HStack(spacing: 8) {
                        Image(systemName: "car.fill").font(.subheadline).foregroundStyle(.blue)
                        Text("\(String(format: "%.1f", km).replacingOccurrences(of: ".", with: ",")) km · \(min) min de carro até você")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        Spacer()
                    }.padding(.top, 2)
                }
            }
        }
    }

    // ── Autonomia EV + combustível ───────────────────────────────────────────
    private func autonomyCard(_ t: SongProStatus.Tele) -> some View {
        Card {
            CardTitle("Autonomia", icon: "map.fill")
            HStack(spacing: 12) {
                statTile("\(Int(t.evRangeKm))", "km elétrico", "leaf.fill", .green)
                statTile("\(Int(t.fuelRangeKm))", "km combustível", "fuelpump.fill", .orange)
                statTile("\(Int(t.fuelPct))%", "tanque", "drop.fill", .yellow)
            }
            ProgressView(value: min(max(t.fuelPct, 0), 100), total: 100)
                .tint(.orange).padding(.top, 2)
        }
    }

    // ── Saúde da bateria ─────────────────────────────────────────────────────
    private func healthCard(_ t: SongProStatus.Tele) -> some View {
        let balance = Int((t.cellVoltMax - t.cellVoltMin) * 1000)   // mV de desequilíbrio
        return Card {
            CardTitle("Bateria de tração", icon: "minus.plus.batteryblock.fill")
            HStack(spacing: 12) {
                statTile(String(format: "%.0f%%", t.soh), "saúde (SOH)", "heart.fill", .pink)
                statTile(String(format: "%.0f V", t.packVoltage), "pack", "bolt.fill", spAccent)
                statTile(String(format: "%.1f V", t.batt12v), "12V", "minus.plus.batteryblock", .teal)
            }
            HStack(spacing: 12) {
                statTile("\(Int(t.cellTempMin))–\(Int(t.cellTempMax))°", "células (temp)", "thermometer.medium", tempColor(t.cellTempMax))
                statTile("\(balance) mV", "balanceamento", "scalemass.fill", balance <= 30 ? .green : .orange)
                statTile(String(format: "%.0f", t.totalDischarge), "kWh totais", "sum", .secondary)
            }
        }
    }

    // ── Pneus (cantos do carro) ──────────────────────────────────────────────
    private func tyresCard(_ t: SongProStatus.Tele) -> some View {
        Card {
            CardTitle("Pneus", icon: "car.side.rear.open.fill")
            HStack(spacing: 12) {
                tyre("DE", t.tyrePressFL, t.tyreTempFL)
                tyre("DD", t.tyrePressFR, t.tyreTempFR)
            }
            HStack(spacing: 12) {
                tyre("TE", t.tyrePressRL, t.tyreTempRL)
                tyre("TD", t.tyrePressRR, t.tyreTempRR)
            }
        }
    }

    // ── Estado do veículo ────────────────────────────────────────────────────
    private func vehicleCard(_ t: SongProStatus.Tele) -> some View {
        Card {
            CardTitle("Veículo", icon: "car.fill")
            HStack(spacing: 12) {
                statTile(t.carLocked ? "Trancado" : "Destrancado",
                         "trava", t.carLocked ? "lock.fill" : "lock.open.fill",
                         t.carLocked ? .green : .red)
                statTile(t.anyDoorOpen ? "Aberta" : "Fechadas", "portas",
                         t.anyDoorOpen ? "door.left.hand.open" : "door.left.hand.closed",
                         t.anyDoorOpen ? .orange : .green)
                statTile(t.gear, "marcha", "gearshift.layout.sixspeed", .secondary)
            }
            HStack(spacing: 12) {
                statTile(String(format: "%.0f", t.odometer), "km odômetro", "gauge.with.dots.needle.bottom.50percent", .secondary)
                statTile(t.carOn ? "Ligado" : "Desligado", "ignição",
                         t.carOn ? "power.circle.fill" : "power.circle", t.carOn ? .green : .secondary)
                statTile("\(Int(t.altitude)) m", "altitude", "mountain.2.fill", .secondary)
            }
        }
    }

    // ── Helpers de UI ─────────────────────────────────────────────────────────
    private func bigMetric(_ value: String, unit: String, icon: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon).font(.caption).foregroundStyle(color)
            Text(value).font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit()
            Text(unit).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func statTile(_ value: String, _ label: String, _ icon: String, _ color: Color) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon).font(.callout).foregroundStyle(color)
            Text(value).font(.subheadline.weight(.bold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func tyre(_ pos: String, _ psi: Double, _ temp: Double) -> some View {
        let ok = psi >= 30 && psi <= 38
        return HStack(spacing: 10) {
            Text(pos).font(.caption.weight(.bold)).foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(String(format: "%.1f psi", psi))
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(ok ? Color.primary : Color.orange)
                Text(String(format: "%.0f°C", temp)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(ok ? .green : .orange)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9).padding(.horizontal, 10)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func tempColor(_ c: Double) -> Color { c >= 45 ? .red : (c >= 38 ? .orange : .green) }
    private func remaining(_ min: Int) -> String {
        let h = min / 60, m = min % 60
        return h > 0 ? "\(h)h\(String(format: "%02d", m))" : "\(m)min"
    }
}

// ── Anel de SOC ──────────────────────────────────────────────────────────────
struct BatteryRing: View {
    let soc: Double
    let accent: Color
    let charging: Bool
    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.10), lineWidth: 13)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(soc, 0), 100) / 100))
                .stroke(accent, style: StrokeStyle(lineWidth: 13, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.5), value: soc)
            VStack(spacing: 0) {
                if charging {
                    Image(systemName: "bolt.fill").font(.caption).foregroundStyle(accent)
                }
                Text("\(Int(soc.rounded()))")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Text("% SOC").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// ── Container de card ─────────────────────────────────────────────────────────
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

struct CardTitle: View {
    let text: String; let icon: String
    init(_ text: String, icon: String) { self.text = text; self.icon = icon }
    var body: some View {
        Label(text, systemImage: icon)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}

// ── CLUSTER (mapa full + infos por cima) ─────────────────────────────────────
struct ClusterView: View {
    @ObservedObject var store: SongProStore
    @State private var camera: MapCameraPosition = .automatic
    @State private var following = true   // segue o carro; pausa ao mexer no mapa
    @State private var showTimeline = false

    private var tele: SongProStatus.Tele { store.status?.tele ?? .init() }
    private var curCoord: CLLocationCoordinate2D {
        if let p = store.history.last(where: { $0.lat != 0 || $0.lng != 0 }) {
            return CLLocationCoordinate2D(latitude: p.lat, longitude: p.lng)
        }
        return CLLocationCoordinate2D(latitude: tele.lat, longitude: tele.lng)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            mapFull
            overlay
        }
        .overlay(alignment: .topTrailing) {
            VStack(spacing: 10) {
                Button {
                    following = true
                    followCamera(curCoord, speed: tele.speed)
                } label: {
                    Image(systemName: following ? "location.fill" : "location")
                        .font(.headline)
                        .foregroundStyle(following ? spAccent : .primary)
                        .padding(11)
                        .glassControl(in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.12)))
                }
                Button { showTimeline = true } label: {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.headline).foregroundStyle(.primary)
                        .padding(11)
                        .glassControl(in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.12)))
                }
            }
            .padding(.top, 60).padding(.trailing, 16)
        }
        .sheet(isPresented: $showTimeline) { TripTimelineSheet(store: store) }
        .ignoresSafeArea(edges: .top)
        .onAppear {
            store.enterFast()
            Task { await store.fetchTrail() }   // carrega a trilha já na abertura
            followCamera(curCoord, speed: tele.speed)
        }
        .onDisappear { store.exitFast() }
    }

    // ── Mapa em tela cheia ───────────────────────────────────────────────────
    private var mapFull: some View {
        // Trilha do trajeto desde a última partida (vem do bridge, limpa ao ligar).
        let coords = store.trail
            .filter { $0.lat != 0 || $0.lng != 0 }
            .map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) }
        let cur = coords.last ?? curCoord
        return Map(position: $camera) {
            if coords.count >= 2 {
                MapPolyline(coordinates: coords).stroke(spAccent, lineWidth: 6)
            }
            if cur.latitude != 0 || cur.longitude != 0 {
                Annotation("BYD da Grasi", coordinate: cur) {
                    ZStack {
                        Circle().fill(spAccent.opacity(0.25)).frame(width: 40, height: 40)
                        Image(systemName: "car.fill")
                            .font(.callout).foregroundStyle(.white)
                            .padding(8).background(spAccent).clipShape(Circle())
                    }
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .all))
        .onChange(of: cur.latitude) { _, _ in followCamera(cur, speed: tele.speed) }
        .onChange(of: tele.speed)   { _, _ in followCamera(cur, speed: tele.speed) }
        // Ao arrastar ou dar zoom, pausa o auto-follow (recentraliza no botão).
        .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in following = false })
        .simultaneousGesture(MagnificationGesture().onChanged { _ in following = false })
    }

    // ── Overlay translúcido por cima do mapa ─────────────────────────────────
    private var overlay: some View {
        VStack(spacing: 10) {
            headerRow
            tilesRow
            miniGraph("POTÊNCIA", unit: "kW", color: spAccent, cur: tele.enginePowerKw,
                      fmt: "%.1f", pick: { $0.power }, zeroMid: true)
            miniGraph("VELOCIDADE", unit: "km/h", color: .green, cur: tele.speed,
                      fmt: "%.0f", pick: { $0.speed }, zeroMid: false)
        }
        .padding(14)
        .glassPanel(in: RoundedRectangle(cornerRadius: 24), stroke: .white.opacity(0.08))
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
    }

    // Cabeçalho: marcha (esq) · velocidade (centro) · viagem dist+tempo (dir).
    private var headerRow: some View {
        HStack(alignment: .center, spacing: 6) {
            VStack(spacing: 1) {
                Text(tele.gear.isEmpty ? "-" : tele.gear)
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .foregroundStyle(spAccent)
                Text("marcha").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .frame(width: 76)
            VStack(spacing: 0) {
                Text("\(Int(tele.speed.rounded()))")
                    .font(.system(size: 50, weight: .heavy, design: .rounded))
                    .monospacedDigit().foregroundStyle(.primary)
                    .contentTransition(.numericText())
                Text("km/h").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            VStack(alignment: .trailing, spacing: 1) {
                Text(String(format: "%.1f km", store.tripKm))
                    .font(.callout.weight(.bold)).monospacedDigit()
                Text(tripTimeStr).font(.caption2).foregroundStyle(.secondary)
                Text(tripStatusStr)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tele.carOn ? .green : .secondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(width: 104, alignment: .trailing)
        }
    }

    // Status da viagem: em andamento (carro ligado) ou finalizada + horário.
    private var tripStatusStr: String {
        let last = store.tripLastMs
        let idleMin = last > 0 ? (Date().timeIntervalSince1970 * 1000 - last) / 60000 : .infinity
        // "em andamento" só se ligado E moveu nos últimos 60min (igual ao corte do
        // bridge). Parado-ligado por mais tempo → finalizada (não infla a viagem).
        if tele.carOn && idleMin < 60 { return "em andamento" }
        guard store.tripStartMs > 0, last > 0 else { return "viagem" }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return "finalizada · \(f.string(from: Date(timeIntervalSince1970: last / 1000)))"
    }

    // Fileira simétrica: Elétrico · Térmico · Bateria · Consumo.
    private var tilesRow: some View {
        HStack(spacing: 8) {
            ctile("bolt.fill", tele.enginePowerKw < 0 ? .green : spAccent,
                  String(format: "%.0f", tele.enginePowerKw), "kW",
                  "\(Int(tele.rpmFront.rounded()))", "rpm")
            ctile("engine.combustion.fill", .orange,
                  tele.rpmRear > 0 ? "\(Int(tele.rpmRear.rounded()))" : "—", "térmico", "", "")
            ctile("minus.plus.batteryblock.fill", .green,
                  "\(Int(tele.soc.rounded()))%", "bateria",
                  "\(Int(tele.evRangeKm.rounded()))", "km EV")
            ctile("leaf.fill", .teal, consumoStr, "kWh/100", "", "")
        }
    }

    private func ctile(_ icon: String, _ color: Color, _ v1: String, _ l1: String,
                       _ v2: String, _ l2: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon).font(.caption).foregroundStyle(color)
            Text(v1).font(.callout.weight(.bold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.5)
            Text(l1).font(.system(size: 9)).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(v2.isEmpty ? " " : v2).font(.subheadline.weight(.semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.5)
            Text(l2.isEmpty ? " " : l2).font(.system(size: 9)).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.black.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // Consumo instantâneo (kWh/100km). Negativo = regenerando. "—" parado.
    private var consumoStr: String {
        let v = tele.speed, p = tele.enginePowerKw
        guard v > 3 else { return "—" }
        return String(format: "%.0f", p / v * 100)
    }

    // Tempo de viagem (congela quando o carro desliga).
    private var tripTimeStr: String {
        let start = store.tripStartMs, last = store.tripLastMs
        guard start > 0, last >= start else { return "—" }
        let s = Int((last - start) / 1000)
        let h = s / 3600, m = (s % 3600) / 60
        return h > 0 ? "\(h)h\(String(format: "%02d", m))" : "\(m) min"
    }

    // ── Mini-gráfico translúcido (últimos 60s) ───────────────────────────────
    private func miniGraph(_ title: String, unit: String, color: Color, cur: Double,
                           fmt: String, pick: @escaping (ClusterSample) -> Double,
                           zeroMid: Bool) -> some View {
        let data = store.history
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(String(format: fmt, cur)) \(unit)")
                    .font(.caption.weight(.bold)).foregroundStyle(color).monospacedDigit()
            }
            if data.count < 2 {
                Text("coletando… (aparece com o carro em uso)")
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            } else {
                Chart(data) { s in
                    AreaMark(x: .value("t", s.t), y: .value(title, pick(s)))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(LinearGradient(colors: [color.opacity(0.45), color.opacity(0.03)],
                                                        startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("t", s.t), y: .value(title, pick(s)))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 2))
                }
                .chartXAxis(.hidden).chartYAxis(.hidden)
                .chartYScale(domain: zeroMid ? -50...50 : 0...160)
                .frame(height: 48)
            }
        }
    }

    // Zoom automático por velocidade: parado afasta (vê o entorno), acelerando
    // aproxima (foco na via). 0 km/h → ~2.2km de span; ≥110 km/h → ~450m.
    private func spanFor(_ speed: Double) -> Double {
        let s = min(max(speed, 0), 110)
        return max(0.004, 0.02 - (s / 110) * 0.016)
    }
    private func followCamera(_ c: CLLocationCoordinate2D, speed: Double) {
        guard following else { return }   // usuário mexeu no mapa → não recentraliza
        guard c.latitude != 0 || c.longitude != 0 else { return }
        let d = spanFor(speed)
        withAnimation(.easeInOut(duration: 0.6)) {
            camera = .region(MKCoordinateRegion(center: c,
                span: MKCoordinateSpan(latitudeDelta: d, longitudeDelta: d)))
        }
    }
}

// ── LINHA DO TEMPO DA VIAGEM (scrubber) ──────────────────────────────────────
// Mostra velocidade/potência/SOC de cada ponto do trajeto. Em andamento usa a
// trilha ao vivo; parado, a última viagem. Arraste o cursor pra inspecionar.
struct TripTimelineSheet: View {
    @ObservedObject var store: SongProStore
    @Environment(\.dismiss) private var dismiss
    @State private var idx: Double = 0

    private var live: Bool { store.status?.tele.carOn ?? false }
    private var pts: [TrailPoint] { live ? store.trail : store.lastTrail }
    private var sel: TrailPoint? {
        guard !pts.isEmpty else { return nil }
        return pts[min(max(0, Int(idx)), pts.count - 1)]
    }

    var body: some View {
        NavigationStack {
            Group {
                if pts.count < 2 {
                    VStack(spacing: 10) {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                            .font(.largeTitle).foregroundStyle(.secondary)
                        Text(live ? "Coletando o trajeto…" : "Sem viagem registrada ainda.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    content
                }
            }
            .navigationTitle(live ? "Viagem em andamento" : "Última viagem")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fechar") { dismiss() } } }
        }
        .task {
            if live { await store.fetchTrail() } else { await store.fetchLastTrip() }
            idx = Double(max(0, pts.count - 1))   // começa no ponto mais recente
        }
    }

    private var content: some View {
        let s = sel ?? pts[pts.count - 1]
        let coords = pts.filter { $0.lat != 0 || $0.lng != 0 }
                        .map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) }
        let selCoord = CLLocationCoordinate2D(latitude: s.lat, longitude: s.lng)
        return ScrollView {
            VStack(spacing: 14) {
                // Leitura no ponto selecionado
                HStack(spacing: 0) {
                    tlMetric("\(Int(s.spd.rounded()))", "km/h", .green)
                    tlMetric(String(format: "%.1f", s.kw), "kW", spAccent)
                    tlMetric("\(Int(s.soc.rounded()))", "% SOC", .blue)
                    tlMetric(mmss(s.t), "tempo", .secondary)
                }
                // Mini-mapa com o ponto selecionado
                if coords.count >= 2 {
                    Map {
                        MapPolyline(coordinates: coords).stroke(spAccent.opacity(0.7), lineWidth: 4)
                        Annotation("", coordinate: selCoord) {
                            Circle().fill(.white).frame(width: 14, height: 14)
                                .overlay(Circle().fill(spAccent).frame(width: 8, height: 8))
                                .shadow(radius: 3)
                        }
                    }
                    .frame(height: 180).clipShape(RoundedRectangle(cornerRadius: 16))
                    .allowsHitTesting(false)
                }
                // Gráficos com cursor no ponto
                tlChart("VELOCIDADE", unit: "km/h", color: .green, sel: s) { $0.spd }
                tlChart("POTÊNCIA",   unit: "kW",   color: spAccent, sel: s) { $0.kw }
                tlChart("BATERIA",    unit: "%",    color: .blue,  sel: s) { $0.soc }
                // Scrubber
                Slider(value: $idx, in: 0...Double(max(1, pts.count - 1)), step: 1)
                    .tint(spAccent)
                Text("arraste pra inspecionar o trajeto")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(16)
        }
    }

    private func tlMetric(_ v: String, _ u: String, _ c: Color) -> some View {
        VStack(spacing: 2) {
            Text(v).font(.system(size: 24, weight: .heavy, design: .rounded)).monospacedDigit().foregroundStyle(c)
            Text(u).font(.system(size: 10)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }

    private func tlChart(_ title: String, unit: String, color: Color, sel: TrailPoint,
                         pick: @escaping (TrailPoint) -> Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            Chart {
                ForEach(pts) { p in
                    LineMark(x: .value("t", p.t), y: .value(title, pick(p)))
                        .interpolationMethod(.monotone).foregroundStyle(color)
                }
                RuleMark(x: .value("t", sel.t)).foregroundStyle(.white.opacity(0.5))
                PointMark(x: .value("t", sel.t), y: .value(title, pick(sel)))
                    .foregroundStyle(color)
            }
            .chartXAxis(.hidden).chartYAxis(.automatic)
            .frame(height: 70)
        }
    }

    private func mmss(_ s: Double) -> String {
        let t = Int(s); return String(format: "%d:%02d", t / 60, t % 60)
    }
}

// ── HISTÓRICO DE RECARGAS ────────────────────────────────────────────────────
private func brl(_ v: Double) -> String {
    String(format: "R$ %.2f", v).replacingOccurrences(of: ".", with: ",")
}
private func monthKey(_ d: Date) -> String {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM"; return f.string(from: d)
}
private func monthLabel(_ key: String) -> String {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM"
    guard let d = f.date(from: key) else { return key }
    let o = DateFormatter(); o.locale = Locale(identifier: "pt_BR"); o.dateFormat = "MMM/yyyy"
    return o.string(from: d).capitalized
}

enum ChargePeriod: String, CaseIterable, Identifiable {
    case all = "Tudo", d7 = "7 dias", d30 = "30 dias", month = "Mês", custom = "Período"
    var id: String { rawValue }
}

struct HistoryView: View {
    @ObservedObject var store: SongProStore
    @State private var selLoc: String? = nil
    @State private var period: ChargePeriod = .all
    @State private var selMonth: String? = nil
    @State private var customStart = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    @State private var customEnd = Date()
    @State private var configLoc: SPLocation?
    @State private var showAdd = false
    @State private var editCharge: SPCharge?

    private var months: [String] {
        Array(Set(store.charges.map { monthKey($0.date) })).sorted(by: >)
    }

    // Intervalo [início, fim) do período selecionado (nil = sem limite).
    private var range: (Date, Date)? {
        let cal = Calendar.current, now = Date()
        switch period {
        case .all: return nil
        case .d7:  return (cal.date(byAdding: .day, value: -7, to: now)!, now)
        case .d30: return (cal.date(byAdding: .day, value: -30, to: now)!, now)
        case .month:
            guard let m = selMonth else { return nil }
            let f = DateFormatter(); f.dateFormat = "yyyy-MM"
            guard let s = f.date(from: m) else { return nil }
            return (s, cal.date(byAdding: .month, value: 1, to: s)!)
        case .custom:
            let s = cal.startOfDay(for: customStart)
            let e = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: customEnd))!
            return (s, e)
        }
    }

    private var filtered: [SPCharge] {
        store.charges.filter { c in
            (selLoc == nil || c.locationId == selLoc) &&
            (range == nil || (c.date >= range!.0 && c.date < range!.1))
        }
    }
    private var totalEnergy: Double { filtered.reduce(0) { $0 + $1.energyKwh } }
    private var totalCost: Double { filtered.reduce(0) { $0 + $1.costEstimate } }

    // Quebra por local (energia + custo) dentro do filtro atual.
    private var byLocation: [(loc: String, energy: Double, cost: Double)] {
        var m: [String: (Double, Double)] = [:]
        for c in filtered {
            let key = c.locationId ?? "—"
            let cur = m[key] ?? (0, 0)
            m[key] = (cur.0 + c.energyKwh, cur.1 + c.costEstimate)
        }
        return m.map { (store.locName($0.key == "—" ? nil : $0.key), $0.value.0, $0.value.1) }
            .sorted { $0.energy > $1.energy }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        TripsListView(store: store)
                    } label: {
                        Label("Viagens (com score)", systemImage: "car.fill")
                    }
                }
                filterSection
                summarySection
                chargesSection
            }
            .navigationTitle("Recargas")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(item: $configLoc) { loc in
                LocationEditor(store: store, loc: loc, isNew: true)
            }
            .sheet(isPresented: $showAdd) {
                ManualChargeForm(store: store)
            }
            .sheet(item: $editCharge) { c in
                ChargeEditor(store: store, charge: c)
            }
            .task {
                await store.fetchCharges()
                await store.fetchTrips()
                configLoc = store.locations.first { $0.needsConfig }
            }
            .refreshable { await store.fetchCharges(); await store.fetchTrips() }
        }
    }

    private var filterSection: some View {
        Section("Filtro") {
            Picker("Local", selection: $selLoc) {
                Text("Todos").tag(String?.none)
                ForEach(store.locations) { l in Text(l.name).tag(String?.some(l.id)) }
            }
            Picker("Período", selection: $period) {
                ForEach(ChargePeriod.allCases) { p in Text(p.rawValue).tag(p) }
            }
            if period == .month {
                Picker("Mês", selection: $selMonth) {
                    Text("Todos").tag(String?.none)
                    ForEach(months, id: \.self) { m in Text(monthLabel(m)).tag(String?.some(m)) }
                }
            }
            if period == .custom {
                DatePicker("De", selection: $customStart, displayedComponents: .date)
                DatePicker("Até", selection: $customEnd, displayedComponents: .date)
            }
        }
    }

    private var summarySection: some View {
        Section("Resumo") {
            HStack {
                Label("\(filtered.count) recargas", systemImage: "bolt.fill")
                Spacer()
                Text(String(format: "%.2f kWh", totalEnergy)).bold().monospacedDigit()
            }
            HStack {
                Label("Custo estimado", systemImage: "brazilianrealsign.circle")
                Spacer()
                Text(brl(totalCost)).bold().monospacedDigit().foregroundStyle(.green)
            }
            if byLocation.count > 1 {
                ForEach(byLocation, id: \.loc) { row in
                    HStack {
                        Text(row.loc).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.1f kWh · %@", row.energy, brl(row.cost)))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        }
    }

    private var chargesSection: some View {
        Section("Recargas") {
            if filtered.isEmpty {
                Text("Nenhuma recarga ainda. Use o + pra lançar uma manualmente.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(filtered) { c in
                    Button { editCharge = c } label: { chargeRow(c) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private func chargeRow(_ c: SPCharge) -> some View {
        let loc = store.location(c.locationId)
        let df = DateFormatter(); df.locale = Locale(identifier: "pt_BR"); df.dateFormat = "dd/MM HH:mm"
        let free = loc?.isFree ?? false
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(store.locName(c.locationId)).font(.subheadline.weight(.semibold))
                if c.manual == true {
                    Text("manual").font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15)).clipShape(Capsule())
                }
                Spacer()
                Text(free ? "Grátis" : brl(c.costEstimate))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(free ? Color.secondary : Color.green).monospacedDigit()
            }
            HStack(spacing: 10) {
                Text(df.string(from: c.date))
                Text("·"); Text(String(format: "%.2f kWh", c.energyKwh))
                Text("·"); Text("\(c.socStart)→\(c.socEnd)%")
            }.font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Label(durStr(c.durationSec), systemImage: "clock")
                Label(String(format: "%.1f kW méd", c.avgPowerKw), systemImage: "gauge.medium")
            }.font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func durStr(_ sec: Int) -> String {
        let h = sec / 3600, m = (sec % 3600) / 60
        return h > 0 ? "\(h)h\(String(format: "%02d", m))" : "\(m)min"
    }
}

// Editor de um local (nome, grátis, preço). Usado no prompt de local novo e na lista.
struct LocationEditor: View {
    @ObservedObject var store: SongProStore
    let loc: SPLocation
    var isNew: Bool = false
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var free = false
    @State private var price = ""
    @State private var radius: Double = 200

    var body: some View {
        NavigationStack {
            Form {
                if isNew {
                    Section { Text("O carro recarregou num local novo. Dê um nome e informe o preço da energia (ou marque grátis).").font(.callout) }
                }
                Section("Local") {
                    TextField("Nome (ex.: Casa, Trabalho, Shopping)", text: $name)
                }
                Section("Raio") {
                    HStack {
                        Text("\(Int(radius)) m").monospacedDigit().frame(width: 70, alignment: .leading)
                        Slider(value: $radius, in: 50...1000, step: 10)
                    }
                }
                Section("Energia") {
                    Toggle("Grátis", isOn: $free)
                    if !free {
                        HStack {
                            Text("R$ / kWh")
                            Spacer()
                            TextField("0,00", text: $price)
                                .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                                .frame(width: 110)
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "Local novo" : "Editar local")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar") {
                        let p = Double(price.replacingOccurrences(of: ",", with: ".")) ?? 0
                        Task {
                            await store.updateLocation(loc.id, name: name.isEmpty ? loc.name : name,
                                                       pricePerKwh: p, free: free, radiusM: Int(radius))
                            dismiss()
                        }
                    }.disabled(store.busy)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
            .onAppear {
                name = loc.name
                free = loc.isFree
                price = loc.pricePerKwh > 0 ? String(format: "%.2f", loc.pricePerKwh) : ""
                radius = loc.radius
            }
        }
    }
}

// Lista de locais pra editar nome/preço; "+" cria um novo pelo mapa (ponto+raio).
struct LocationsEditor: View {
    @ObservedObject var store: SongProStore
    @State private var editing: SPLocation?
    @State private var adding = false
    var body: some View {
        List {
            Section {
                Text("Pré-configure os locais onde costuma carregar (ponto + raio + preço). Quando o carro recarregar dentro do raio, já puxa nome e custo automático.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if store.locations.isEmpty {
                Text("Nenhum local ainda. Toque em + pra criar pelo mapa.")
                    .foregroundStyle(.secondary)
            }
            ForEach(store.locations) { l in
                Button { editing = l } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(l.name).foregroundStyle(.primary)
                            Text("raio \(Int(l.radius)) m\(l.needsConfig ? " · não configurado" : "")")
                                .font(.caption2).foregroundStyle(l.needsConfig ? .orange : .secondary)
                        }
                        Spacer()
                        Text(l.isFree ? "Grátis" : brl(l.pricePerKwh) + "/kWh")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Locais e preços")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { adding = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(item: $editing) { l in LocationEditor(store: store, loc: l) }
        .sheet(isPresented: $adding) {
            MapLocationPicker(store: store, start: store.status?.tele)
        }
    }
}

// Cria um local pelo mapa: arrasta o mapa pra centralizar o ponto + ajusta o raio.
struct MapLocationPicker: View {
    @ObservedObject var store: SongProStore
    let start: SongProStatus.Tele?
    @Environment(\.dismiss) private var dismiss
    @State private var camera: MapCameraPosition = .automatic
    @State private var center = CLLocationCoordinate2D(latitude: -16.6, longitude: -49.25)
    @State private var radius: Double = 200
    @State private var name = ""
    @State private var free = false
    @State private var price = ""
    @State private var searchText = ""
    @State private var searching = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    Map(position: $camera) {
                        MapCircle(center: center, radius: radius)
                            .foregroundStyle(spAccent.opacity(0.18))
                            .stroke(spAccent, lineWidth: 2)
                    }
                    .onMapCameraChange(frequency: .continuous) { ctx in center = ctx.region.center }
                    Image(systemName: "mappin")
                        .font(.title).foregroundStyle(spAccent)
                        .shadow(radius: 2)
                }
                .frame(height: 260)
                .overlay(alignment: .top) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Buscar endereço…", text: $searchText)
                            .submitLabel(.search)
                            .autocorrectionDisabled()
                            .onSubmit { Task { await searchAddress() } }
                        if searching {
                            ProgressView()
                        } else if !searchText.isEmpty {
                            Button { searchText = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .glassControl(in: Capsule())
                    .padding(10)
                }
                Form {
                    Section("Local") { TextField("Nome (ex.: Casa, Trabalho)", text: $name) }
                    Section("Raio") {
                        HStack {
                            Text("\(Int(radius)) m").monospacedDigit().frame(width: 70, alignment: .leading)
                            Slider(value: $radius, in: 50...1000, step: 10)
                        }
                    }
                    Section("Energia") {
                        Toggle("Grátis", isOn: $free)
                        if !free {
                            HStack { Text("R$ / kWh"); Spacer()
                                TextField("0,00", text: $price).keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing).frame(width: 110)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Novo local")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar") {
                        let p = Double(price.replacingOccurrences(of: ",", with: ".")) ?? 0
                        Task {
                            await store.createLocation(name: name.isEmpty ? "Local" : name,
                                lat: center.latitude, lng: center.longitude,
                                radiusM: Int(radius), pricePerKwh: p, free: free)
                            dismiss()
                        }
                    }.disabled(store.busy || name.isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
            }
            .onAppear {
                if let t = start, t.lat != 0 || t.lng != 0 {
                    center = CLLocationCoordinate2D(latitude: t.lat, longitude: t.lng)
                }
                camera = .region(MKCoordinateRegion(center: center,
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)))
            }
        }
    }

    // Geocoding do endereço digitado → centraliza o mapa no resultado.
    private func searchAddress() async {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true; defer { searching = false }
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = q
        req.region = MKCoordinateRegion(center: center, latitudinalMeters: 60000, longitudinalMeters: 60000)
        guard let resp = try? await MKLocalSearch(request: req).start(),
              let item = resp.mapItems.first else { return }
        let c = item.placemark.coordinate
        center = c
        camera = .region(MKCoordinateRegion(center: c,
            span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)))
        if name.isEmpty, let n = item.name { name = n }
    }
}

// Lançamento manual de uma recarga (ex.: recargas antigas).
struct ManualChargeForm: View {
    @ObservedObject var store: SongProStore
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var energy = ""
    @State private var durMin = ""
    @State private var socStart = ""
    @State private var socEnd = ""
    @State private var useExisting = false
    @State private var locId: String?
    @State private var newName = ""
    @State private var free = false
    @State private var price = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Quando") { DatePicker("Fim da recarga", selection: $date) }
                Section("Dados") {
                    field("Energia (kWh)", $energy)
                    field("Duração (min)", $durMin)
                    field("SOC início (%)", $socStart)
                    field("SOC fim (%)", $socEnd)
                }
                Section("Local") {
                    if !store.locations.isEmpty {
                        Toggle("Usar local existente", isOn: $useExisting)
                    }
                    if useExisting {
                        Picker("Local", selection: $locId) {
                            Text("Selecione").tag(String?.none)
                            ForEach(store.locations) { l in Text(l.name).tag(String?.some(l.id)) }
                        }
                    } else {
                        TextField("Nome do local", text: $newName)
                        Toggle("Grátis", isOn: $free)
                        if !free {
                            HStack { Text("R$ / kWh"); Spacer()
                                TextField("0,00", text: $price).keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing).frame(width: 110)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Nova recarga")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar") { save() }.disabled(store.busy || (Double(energy.replacingOccurrences(of: ",", with: ".")) ?? 0) <= 0)
                }
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
            }
        }
    }

    private func field(_ label: String, _ text: Binding<String>) -> some View {
        HStack { Text(label); Spacer()
            TextField("0", text: text).keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing).frame(width: 110)
        }
    }

    private func save() {
        let e = Double(energy.replacingOccurrences(of: ",", with: ".")) ?? 0
        let p = Double(price.replacingOccurrences(of: ",", with: ".")) ?? 0
        Task {
            await store.addManualCharge(
                endMs: date.timeIntervalSince1970 * 1000,
                durationSec: (Int(durMin) ?? 0) * 60,
                energyKwh: e,
                socStart: Int(socStart) ?? 0, socEnd: Int(socEnd) ?? 0,
                locationId: useExisting ? locId : nil,
                locationName: useExisting ? nil : (newName.isEmpty ? "Local" : newName),
                pricePerKwh: p, free: free)
            dismiss()
        }
    }
}

// ── Catálogo de notificações ─────────────────────────────────────────────────
struct NotifItem: Identifiable { let key, title, sub: String; var id: String { key } }
struct NotifGroup: Identifiable { let title, icon: String; let items: [NotifItem]; var id: String { title } }

let NOTIF_GROUPS: [NotifGroup] = [
    NotifGroup(title: "Recarga", icon: "bolt.fill", items: [
        NotifItem(key: "byd_charge_start",   title: "Recarga iniciada",     sub: "Quando o BYD começa a carregar"),
        NotifItem(key: "byd_charge_end",     title: "Recarga finalizada",   sub: "Quando termina (SOC + kWh)"),
        NotifItem(key: "byd_charge_target",  title: "Atingiu o alvo",       sub: "Chegou a 100%"),
        NotifItem(key: "byd_charge_stopped", title: "Parou antes do alvo",  sub: "Interrompeu antes de completar"),
        NotifItem(key: "byd_charge_slow",    title: "Carregamento lento",   sub: "Potência abaixo de 3 kW"),
    ]),
    NotifGroup(title: "Segurança", icon: "lock.shield.fill", items: [
        NotifItem(key: "byd_unlocked",     title: "Carro destrancado",  sub: "Após X min com o motor desligado"),
        NotifItem(key: "byd_door_open",    title: "Porta aberta",       sub: ""),
        NotifItem(key: "byd_ignition_on",  title: "Ignição ligada",     sub: "Alguém ligou o carro"),
    ]),
    NotifGroup(title: "Bateria", icon: "minus.plus.batteryblock.fill", items: [
        NotifItem(key: "byd_soc_low",         title: "Bateria baixa",          sub: "SOC < 20% parado"),
        NotifItem(key: "byd_batt12_low",      title: "12V baixa",              sub: ""),
        NotifItem(key: "byd_cell_temp_high",  title: "Bateria quente",         sub: "Célula ≥ 45 °C"),
        NotifItem(key: "byd_cell_imbalance",  title: "Células desbalanceadas", sub: "Δ ≥ 50 mV"),
    ]),
    NotifGroup(title: "Pneus", icon: "car.side.rear.open.fill", items: [
        NotifItem(key: "byd_tyre_pressure",  title: "Pressão fora da faixa", sub: "30–38 psi"),
        NotifItem(key: "byd_tyre_temp_high", title: "Pneu quente",           sub: ""),
    ]),
    NotifGroup(title: "Movimento e locais", icon: "location.fill", items: [
        NotifItem(key: "byd_moving",              title: "Começou a andar",      sub: ""),
        NotifItem(key: "byd_parked",              title: "Estacionou",           sub: "Carro desligou"),
        NotifItem(key: "byd_geofence_arrival",    title: "Chegou em um local",   sub: "Quando o carro é desligado dentro de um local configurado"),
        NotifItem(key: "byd_geofence_departure",  title: "Saiu de um local",     sub: ""),
    ]),
    NotifGroup(title: "Manutenção", icon: "wrench.and.screwdriver.fill", items: [
        NotifItem(key: "byd_maintenance_km", title: "Revisão por km", sub: "A cada 12.000 km"),
    ]),
]

// Grupo expansível com estado (aberto/fechado) PERSISTIDO via @AppStorage.
struct NotifGroupView: View {
    @ObservedObject var store: SongProStore
    let group: NotifGroup
    @AppStorage private var expanded: Bool
    init(store: SongProStore, group: NotifGroup) {
        self.store = store; self.group = group
        _expanded = AppStorage(wrappedValue: false, "ng_open_" + group.title)
    }
    private var isGeofence: (String) -> Bool {
        { $0 == "byd_geofence_arrival" || $0 == "byd_geofence_departure" }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(group.items) { item in
                if isGeofence(item.key) {
                    geofenceItem(item)
                } else if item.key == "byd_unlocked" {
                    unlockedItem(item)
                } else {
                    masterToggle(item)
                }
            }
        } label: {
            Label(group.title, systemImage: group.icon).font(.subheadline.weight(.semibold))
        }
    }

    private func masterToggle(_ item: NotifItem) -> some View {
        Toggle(isOn: Binding(
            get: { store.isOn(item.key) },
            set: { v in Task { await store.setPref(item.key, v) } }
        )) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                if !item.sub.isEmpty { Text(item.sub).font(.caption2).foregroundStyle(.secondary) }
            }
        }
    }

    // Destrancado: master + (quando ligado) o tempo (min) com motor desligado.
    @ViewBuilder private func unlockedItem(_ item: NotifItem) -> some View {
        masterToggle(item)
        if store.isOn(item.key) {
            Stepper(value: Binding(
                get: { store.numValue("byd_unlocked_min", 5) },
                set: { v in Task { await store.setPrefNum("byd_unlocked_min", v) } }
            ), in: 0...60) {
                HStack {
                    Text("Avisar após").font(.subheadline)
                    Spacer()
                    Text("\(store.numValue("byd_unlocked_min", 5)) min")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 18)
        }
    }

    // Geofence: master + (quando ligado) seleção de locais. Cada local default
    // marcado; sub-pref = byd_geofence_<arrival|departure>_<locId>.
    @ViewBuilder private func geofenceItem(_ item: NotifItem) -> some View {
        masterToggle(item)
        if store.isOn(item.key) {
            if store.locations.isEmpty {
                Text("Cadastre locais em Histórico › Locais e preços pra escolher quais notificar.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                ForEach(store.locations) { loc in
                    Toggle(isOn: Binding(
                        get: { store.prefs["\(item.key)_\(loc.id)"] ?? true },
                        set: { v in Task { await store.setPref("\(item.key)_\(loc.id)", v) } }
                    )) {
                        Text(loc.name).font(.subheadline)
                    }
                    .padding(.leading, 18)
                    .tint(.secondary)
                }
            }
        }
    }
}

// Edita uma recarga existente: energia e custo (custo manual sobrepõe o auto).
struct ChargeEditor: View {
    @ObservedObject var store: SongProStore
    let charge: SPCharge
    @Environment(\.dismiss) private var dismiss
    @State private var energy = ""
    @State private var cost = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Recarga") {
                    LabeledContent("Local", value: store.locName(charge.locationId))
                    LabeledContent("Data") {
                        Text(charge.date.formatted(date: .abbreviated, time: .shortened))
                    }
                    LabeledContent("SOC", value: "\(charge.socStart)→\(charge.socEnd)%")
                }
                Section("Energia") {
                    HStack { Text("kWh"); Spacer()
                        TextField("0", text: $energy).keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing).frame(width: 120)
                    }
                }
                Section {
                    HStack { Text("Custo R$"); Spacer()
                        TextField("0,00", text: $cost).keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing).frame(width: 120)
                    }
                } header: {
                    Text("Custo")
                } footer: {
                    Text("Editar o custo aqui sobrepõe o valor automático e não muda quando você alterar o preço do local.")
                }
            }
            .navigationTitle("Editar recarga")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar") {
                        let e = energy.isEmpty ? nil : Double(energy.replacingOccurrences(of: ",", with: "."))
                        let c = cost.isEmpty ? nil : Double(cost.replacingOccurrences(of: ",", with: "."))
                        Task { await store.updateCharge(charge.id, energyKwh: e, costEstimate: c); dismiss() }
                    }.disabled(store.busy)
                }
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
            }
            .onAppear {
                energy = String(format: "%.2f", charge.energyKwh)
                cost = String(format: "%.2f", charge.costEstimate)
            }
        }
    }
}

// ── CONFIGURAÇÃO ──────────────────────────────────────────────────────────────
struct ConfigTab: View {
    @Binding var configured: Bool
    @ObservedObject var store: SongProStore

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    IdentityRow(store: store)
                } header: {
                    Text("Identidade")
                } footer: {
                    Text("Quem é este iPhone? A Grasi recebe alertas quando outros aparelhos (companions) estão se aproximando dela. O nome também identifica quem está dirigindo (o iPhone mais perto do carro no momento da ignição).")
                }

                Section("Live Activity") {
                    Toggle("Mostrar recarga do BYD", isOn: Binding(
                        get: { store.isOn("la_songpro") },
                        set: { v in Task { await store.setPref("la_songpro", v) } }
                    ))
                    Toggle("Mostrar deslocamento do BYD", isOn: Binding(
                        get: { store.isOn("la_songpro_trip") },
                        set: { v in Task { await store.setPref("la_songpro_trip", v) } }
                    ))
                    Button {
                        Task { await store.relaunch() }
                    } label: {
                        Label("Reativar card na tela bloqueada", systemImage: "arrow.clockwise")
                    }.disabled(store.busy)
                    Text("Se fechar o card sem querer, toque em Reativar pra trazê-lo de volta enquanto a recarga estiver acontecendo.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    NavigationLink {
                        LocationsEditor(store: store)
                    } label: {
                        Label("Locais e preços", systemImage: "mappin.and.ellipse")
                    }
                } header: {
                    Text("Locais")
                } footer: {
                    Text("Cadastre os pontos onde costuma carregar (nome, preço/kWh e raio). São usados no custo das recargas e nas notificações de chegada/saída.")
                }

                Section {
                    ForEach(NOTIF_GROUPS) { g in NotifGroupView(store: store, group: g) }
                } header: {
                    Text("Notificações")
                } footer: {
                    Text("Escolha o que este aparelho recebe. Cada um configura o seu — a Grasi e você podem ter alertas diferentes.")
                }

                Section("Conexão") {
                    LabeledContent("Bridge") {
                        Text(BydSettings.bridgeURL).font(.caption.monospaced())
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    LabeledContent("Device") {
                        Text(BydSettings.deviceId.suffix(12)).font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Button("Reconfigurar URL / token", role: .destructive) {
                        configured = false
                    }
                }

                if !store.message.isEmpty {
                    Section { Text(store.message).font(.callout).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Configuração")
            .task { await store.fetchPrefs(); await store.fetchCharges() }
        }
    }
}

// ── IDENTIDADE DO DEVICE ─────────────────────────────────────────────────────
// Picker "Sou Grasi / Companion / Outro" + nome livre. O role da Grasi
// determina quem recebe a LA "companion a caminho"; o nome dela é usado pra
// identificar o motorista (iPhone mais próximo do carro na ignição).
struct IdentityRow: View {
    @ObservedObject var store: SongProStore
    @State private var nameDraft = ""

    var body: some View {
        let role = store.strValue("byd_role", "other")
        let saved = store.strValue("byd_name", "")
        return VStack(alignment: .leading, spacing: 10) {
            Picker("Sou", selection: Binding(
                get: { role },
                set: { v in Task { await store.setPrefStr("byd_role", v) } }
            )) {
                Text("Grasi (recebe alertas)").tag("grasi")
                Text("Companion (Rafael, etc)").tag("companion")
                Text("Outro").tag("other")
            }
            HStack {
                Text("Nome").foregroundStyle(.secondary)
                Spacer()
                TextField("Como me chamar (ex.: Grasi, Rafael)", text: $nameDraft, onCommit: {
                    Task { await store.setPrefStr("byd_name", nameDraft) }
                })
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
            }
        }
        .onAppear { nameDraft = saved }
        .onChange(of: saved) { _, new in
            if nameDraft != new { nameDraft = new }
        }
    }
}

// ── HISTÓRICO DE VIAGENS (Feature 10) ────────────────────────────────────────
// Lista de viagens encerradas com score de condução, motorista identificado e
// métricas básicas. Toque na linha pra detalhe (placeholder por ora — pode ser
// expandido depois).
struct TripsListView: View {
    @ObservedObject var store: SongProStore
    @State private var selected: SPTrip?

    var body: some View {
        List {
            if store.trips.isEmpty {
                Section {
                    ContentUnavailableView("Sem viagens registradas",
                        systemImage: "car.fill",
                        description: Text("Cada viagem encerrada (>60min sem mover) vira uma linha aqui com score de condução."))
                }
            } else {
                Section("Últimas viagens") {
                    ForEach(store.trips) { t in
                        Button { selected = t } label: { tripRow(t) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle("Viagens")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.fetchTrips() }
        .refreshable { await store.fetchTrips() }
        .sheet(item: $selected) { t in TripDetailSheet(trip: t) }
    }

    private func tripRow(_ t: SPTrip) -> some View {
        let df = DateFormatter(); df.locale = Locale(identifier: "pt_BR"); df.dateFormat = "dd/MM HH:mm"
        return HStack(spacing: 12) {
            ZStack {
                Circle().fill(bydScoreColor(t.driveScore).opacity(0.18))
                Text(bydScoreLetter(t.driveScore))
                    .font(.title3.weight(.heavy)).monospacedDigit()
                    .foregroundStyle(bydScoreColor(t.driveScore))
            }
            .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(df.string(from: t.date)).font(.subheadline.weight(.semibold))
                    if !t.driverName.isEmpty {
                        Text("· \(t.driverName)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(t.driveScore)").font(.subheadline.weight(.bold))
                        .foregroundStyle(bydScoreColor(t.driveScore)).monospacedDigit()
                }
                HStack(spacing: 8) {
                    Text(String(format: "%.1f km", t.distKm)
                        .replacingOccurrences(of: ".", with: ","))
                    Text("·")
                    Text(durStr(t.durationSec))
                    Text("·")
                    Text("\(t.startSoc)→\(t.endSoc)%")
                    Spacer()
                    if t.harshAcc + t.harshBrake > 0 {
                        Label("\(t.harshAcc + t.harshBrake)", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func durStr(_ sec: Int) -> String {
        let h = sec / 3600, m = (sec % 3600) / 60
        return h > 0 ? "\(h)h\(String(format: "%02d", m))" : "\(m)min"
    }
}

// ── DETALHE DA VIAGEM ────────────────────────────────────────────────────────
// Sheet expandido com score explicado, métricas detalhadas, alertas (aceleração
// e frenagem brusca com thresholds reais), energia e mini-mapa início→fim.
struct TripDetailSheet: View {
    let trip: SPTrip
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    headerCard
                    scoreCard
                    metricsCard
                    energyCard
                    alertsCard
                    if trip.startLat != 0 || trip.endLat != 0 { mapCard }
                }
                .padding(.horizontal, 16).padding(.top, 4)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Viagem")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fechar") { dismiss() } } }
        }
    }

    // Cabeçalho com data/hora completa + motorista.
    private var headerCard: some View {
        let dfd = DateFormatter(); dfd.locale = Locale(identifier: "pt_BR"); dfd.dateFormat = "EEEE, dd 'de' MMMM"
        let dft = DateFormatter(); dft.locale = Locale(identifier: "pt_BR"); dft.dateFormat = "HH:mm"
        let endTime = dft.string(from: trip.date)
        let startTime = dft.string(from: Date(timeIntervalSince1970: trip.startMs / 1000))
        return HStack(spacing: 13) {
            ZStack {
                Circle().fill(LinearGradient(colors: [spAccent, .blue],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 50, height: 50)
                Image(systemName: "car.fill").font(.title3).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(dfd.string(from: trip.date).capitalized)
                    .font(.headline).lineLimit(1).minimumScaleFactor(0.7)
                HStack(spacing: 5) {
                    Image(systemName: "clock").font(.caption2).foregroundStyle(.secondary)
                    Text("\(startTime) → \(endTime)").font(.caption).foregroundStyle(.secondary)
                }
                if !trip.driverName.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "steeringwheel").font(.caption2).foregroundStyle(.blue)
                        Text("Motorista: \(trip.driverName)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
        }
    }

    // Score grande + explicação curta de como é calculado.
    private var scoreCard: some View {
        let c = bydScoreColor(trip.driveScore)
        return Card {
            CardTitle("Score de condução", icon: "rosette")
            HStack(spacing: 18) {
                ZStack {
                    Circle().stroke(c.opacity(0.18), lineWidth: 8)
                    Circle().trim(from: 0, to: CGFloat(trip.driveScore) / 100)
                        .stroke(c, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: -2) {
                        Text(bydScoreLetter(trip.driveScore))
                            .font(.system(size: 28, weight: .heavy, design: .rounded))
                            .foregroundStyle(c)
                        Text("\(trip.driveScore)/100").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }
                }.frame(width: 88, height: 88)
                VStack(alignment: .leading, spacing: 6) {
                    Text(scoreVerdict(trip.driveScore)).font(.subheadline.weight(.semibold))
                        .foregroundStyle(c)
                    Text("Combina **eficiência** (energia gasta por 100km vs baseline de 17,5 kWh) com **suavidade** (acelerações e frenagens bruscas por km).")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    // Métricas: distância, duração, velocidade média.
    private var metricsCard: some View {
        Card {
            CardTitle("Viagem", icon: "ruler")
            HStack(spacing: 12) {
                statTile(String(format: "%.1f", trip.distKm).replacingOccurrences(of: ".", with: ","),
                         "km percorridos", "ruler.fill", spAccent)
                statTile(durFull(trip.durationSec), "duração", "clock.fill", .secondary)
                statTile("\(trip.avgSpeedKmh)", "km/h média", "speedometer", .teal)
            }
        }
    }

    // SOC start→end + energia consumida (kWh).
    private var energyCard: some View {
        let consumed = max(0, trip.startSoc - trip.endSoc)
        return Card {
            CardTitle("Energia", icon: "minus.plus.batteryblock.fill")
            HStack(spacing: 12) {
                statTile("\(trip.startSoc)→\(trip.endSoc)%", "SOC inicial → final",
                         "battery.75", consumed > 30 ? .orange : .green)
                statTile(String(format: "%.2f", trip.energyKwh).replacingOccurrences(of: ".", with: ","),
                         "kWh gastos", "bolt.fill", .yellow)
                statTile(consumeStr, "kWh/100km", "leaf.fill",
                         trip.distKm >= 1 && trip.energyKwh / trip.distKm * 100 < 17.5 ? .green : .orange)
            }
        }
    }

    private var consumeStr: String {
        guard trip.distKm >= 1 else { return "—" }
        let v = trip.energyKwh / trip.distKm * 100
        return String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",")
    }

    // EXPLICAÇÃO dos alertas — o que conta, o threshold, e o impacto.
    private var alertsCard: some View {
        let total = trip.harshAcc + trip.harshBrake
        let perKm = trip.distKm > 0.5 ? Double(total) / trip.distKm : 0
        return Card {
            CardTitle("Alertas de direção", icon: "exclamationmark.triangle.fill")
            HStack(spacing: 12) {
                alertTile("\(trip.harshAcc)", "acelerações bruscas",
                         "bolt.car.fill", .orange,
                         desc: "acima de 9 km/h por segundo (~2,5 m/s²)")
                alertTile("\(trip.harshBrake)", "frenagens bruscas",
                         "car.side.front.lock.open", .red,
                         desc: "menos de −11 km/h por segundo (~3,0 m/s²)")
            }
            if total > 0 {
                Divider().overlay(Color.white.opacity(0.08))
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle.fill").font(.caption).foregroundStyle(spAccent)
                        Text("Por que conta?").font(.caption.weight(.semibold))
                    }
                    Text("Acelerar ou frear forte gasta mais energia, desgasta pneus/freios e indica direção menos previsível. **O score perde ~18 pontos por evento/km** — esta viagem teve \(String(format: "%.2f", perKm).replacingOccurrences(of: ".", with: ",")) evento/km.")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text("Dica: solte o pé do acelerador antes de freadas planejadas — o one-pedal recupera energia em vez de jogar fora.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text("Direção suave — nenhum evento brusco nesta viagem.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // Mini-mapa com pinos de início e fim. Se for o "ponto e ponto" muito
    // próximo (viagem curta), zoom mais amplo.
    @ViewBuilder private var mapCard: some View {
        let pStart = (trip.startLat != 0 || trip.startLng != 0) ? CLLocationCoordinate2D(latitude: trip.startLat, longitude: trip.startLng) : nil
        let pEnd   = (trip.endLat != 0 || trip.endLng != 0)     ? CLLocationCoordinate2D(latitude: trip.endLat,   longitude: trip.endLng)   : nil
        Card {
            CardTitle("Origem e destino", icon: "map.fill")
            Map {
                if let s = pStart {
                    Annotation("Saída", coordinate: s) {
                        ZStack {
                            Circle().fill(.green.opacity(0.3)).frame(width: 28, height: 28)
                            Image(systemName: "flag.fill").foregroundStyle(.white)
                                .padding(6).background(.green).clipShape(Circle())
                        }
                    }
                }
                if let e = pEnd {
                    Annotation("Chegada", coordinate: e) {
                        ZStack {
                            Circle().fill(.red.opacity(0.3)).frame(width: 28, height: 28)
                            Image(systemName: "flag.checkered").foregroundStyle(.white)
                                .padding(6).background(.red).clipShape(Circle())
                        }
                    }
                }
                if let s = pStart, let e = pEnd {
                    MapPolyline(coordinates: [s, e]).stroke(spAccent, style: StrokeStyle(lineWidth: 3, dash: [6, 4]))
                }
            }
            .mapStyle(.standard(elevation: .flat))
            .frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            Text("Linha tracejada é só a referência ponto-a-ponto (não o caminho real).")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func statTile(_ value: String, _ label: String, _ icon: String, _ color: Color) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon).font(.callout).foregroundStyle(color)
            Text(value).font(.subheadline.weight(.bold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.5)
            Text(label).font(.caption2).foregroundStyle(.secondary)
                .lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func alertTile(_ value: String, _ label: String, _ icon: String, _ color: Color, desc: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.title3).foregroundStyle(color)
            Text(value).font(.title.weight(.heavy)).monospacedDigit().foregroundStyle(color)
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.7)
            Text(desc).font(.system(size: 9)).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center).lineLimit(3).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 12)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func scoreVerdict(_ s: Int) -> String {
        if s >= 85 { return "Excelente" }; if s >= 70 { return "Muito bom" }
        if s >= 55 { return "Razoável" };   if s >= 40 { return "Pode melhorar" }
        return "Direção agressiva"
    }

    private func durFull(_ sec: Int) -> String {
        let h = sec / 3600, m = (sec % 3600) / 60
        if h > 0 { return "\(h)h \(m)min" }
        return "\(m) min"
    }
}

// ── TRAJETO COMPARTILHADO (share do Haval) ───────────────────────────────────
// Sheet aberta pelo deep link grasi-recarga://shared-trip?token=<TOKEN> (toque
// na LA SharedTrip). Lê /api/share/:token/state (endpoint público, sem auth) e
// mostra carro ao vivo: destino, ETA, SOC, posição etc.
struct SharedTripState: Decodable {
    var on: Bool = false
    var lat: Double = 0
    var lng: Double = 0
    var speedKmh: Double = 0
    var soc: Int = 0
    var rangeEvKm: Int = 0
    var evRemainKm: Int = 0
    var iceRemainKm: Int = 0
    var gear: String = "--"
    var tempIn: Double = 0
    var tempOut: Double = 0
    var moving: Bool = false
    var dest: Dest? = nil
    var recipient: Recipient? = nil

    struct Dest: Decodable {
        var name: String = ""; var distKm: Double = 0; var etaMin: Int = 0; var etaClock: String = ""
    }
    struct Recipient: Decodable {
        var name: String = ""; var role: String = ""; var paired: Bool = false
    }
}

struct SharedTripSheet: View {
    let token: String
    @Environment(\.dismiss) private var dismiss
    @State private var trip: SharedTripState?
    @State private var loading = true
    @State private var expired = false

    var body: some View {
        NavigationStack {
            ScrollView {
                if expired {
                    ContentUnavailableView("Link expirado",
                        systemImage: "lock.fill",
                        description: Text("O Rafael revogou esse compartilhamento ou ele já expirou."))
                        .padding(.top, 80)
                } else if let t = trip {
                    VStack(spacing: 14) {
                        header(t)
                        if let d = t.dest, !d.name.isEmpty { destCard(d) }
                        metricsGrid(t)
                        if t.lat != 0 || t.lng != 0 {
                            BydMiniMap(lat: t.lat, lng: t.lng)
                                .frame(height: 220)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                    }
                    .padding(.horizontal, 16).padding(.top, 6)
                } else {
                    ProgressView().padding(.top, 120)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Trajeto compartilhado")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fechar") { dismiss() } } }
            .task { await poll() }
            .refreshable { await fetchOnce() }
        }
    }

    private func header(_ t: SharedTripState) -> some View {
        HStack(spacing: 13) {
            ZStack {
                Circle().fill(LinearGradient(colors: [.cyan, .blue],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 50, height: 50)
                Image(systemName: "shared.with.you").font(.title3).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Trajeto compartilhado").font(.title2.weight(.bold))
                Text(t.moving ? "Carro em movimento" : (t.on ? "Carro ligado" : "Em repouso"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func destCard(_ d: SharedTripState.Dest) -> some View {
        Card {
            CardTitle("Destino", icon: "mappin.and.ellipse")
            VStack(alignment: .leading, spacing: 4) {
                Text(d.name).font(.headline)
                HStack(spacing: 8) {
                    Label(String(format: "%.1f km", d.distKm).replacingOccurrences(of: ".", with: ","),
                          systemImage: "ruler")
                    Text("·")
                    Label("\(d.etaMin) min", systemImage: "clock")
                    if !d.etaClock.isEmpty { Text("·"); Text(d.etaClock) }
                }.font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private func metricsGrid(_ t: SharedTripState) -> some View {
        Card {
            CardTitle("Estado do carro", icon: "car.fill")
            HStack(spacing: 12) {
                tile("\(t.soc)", "% SOC", "minus.plus.batteryblock.fill", .green)
                tile("\(Int(t.speedKmh.rounded()))", "km/h", "speedometer", .blue)
                tile(t.gear, "marcha", "gearshift.layout.sixspeed", .secondary)
            }
            HStack(spacing: 12) {
                tile("\(t.evRemainKm)", "km EV", "leaf.fill", .green)
                tile("\(t.iceRemainKm)", "km gás", "fuelpump.fill", .orange)
                tile(String(format: "%.0f°", t.tempOut), "externa", "thermometer.medium", .blue)
            }
        }
    }

    private func tile(_ v: String, _ l: String, _ i: String, _ c: Color) -> some View {
        VStack(spacing: 5) {
            Image(systemName: i).font(.callout).foregroundStyle(c)
            Text(v).font(.subheadline.weight(.bold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(l).font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func poll() async {
        while !Task.isCancelled {
            await fetchOnce()
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    private func fetchOnce() async {
        guard BydSettings.isConfigured,
              let url = URL(string: BydSettings.baseURL + "/api/share/" + token + "/state") else { return }
        var req = URLRequest(url: url, timeoutInterval: 8)
        // /api/share/:token/state é endpoint público (não exige Bearer) — token
        // já vale como auth. Mas mandar o Bearer também não atrapalha.
        req.addValue("Bearer " + BydSettings.bridgeToken, forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return }
        if (resp as? HTTPURLResponse)?.statusCode == 404 { expired = true; loading = false; return }
        guard let t = try? JSONDecoder().decode(SharedTripState.self, from: data) else { return }
        trip = t; loading = false
    }
}

// ── SETUP inicial ─────────────────────────────────────────────────────────────
struct SetupForm: View {
    @Binding var configured: Bool
    @ObservedObject var store: SongProStore
    @State private var urlField = BydSettings.bridgeURL
    @State private var tokenField = BydSettings.bridgeToken

    var body: some View {
        Form {
            Section("Configuração") {
                TextField("URL do bridge (https://…)", text: $urlField)
                    .autocorrectionDisabled().textInputAutocapitalization(.never).keyboardType(.URL)
                SecureField("Token / senha do bridge", text: $tokenField)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                Button("Salvar e ativar") {
                    BydSettings.bridgeURL = urlField
                    BydSettings.bridgeToken = tokenField
                    guard BydSettings.isConfigured else { return }
                    configured = true
                    BydRemoteNotifications.enable()
                    BydLiveActivityPush.shared.start()
                    Task {
                        await store.setPref("la_songpro", true)
                        await store.fetchPrefs()
                        store.startPolling()
                    }
                }.disabled(urlField.isEmpty || tokenField.isEmpty)
                Text("Use a mesma URL e token do app principal do Haval. O device é registrado só pra Live Activity da recarga do BYD.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Grasi Recarga")
    }
}
