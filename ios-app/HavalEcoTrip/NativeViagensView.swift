//
//  NativeViagensView.swift
//  Aba Viagens — histórico (/api/autotrips). Nome (campo name + geocode de
//  fallback), custo estimado (preço×energia), filtro Hoje/período/calendário.
//  Card expansível: excluir, editar nome (/api/rename), ver trajeto (telemetry).
//

import SwiftUI
import MapKit
import CoreLocation
import Charts

private func anyNum2(_ v: Any?) -> Double {
    switch v {
    case let d as Double: return d
    case let i as Int: return Double(i)
    case let n as NSNumber: return n.doubleValue
    case let s as String: return Double(s) ?? 0
    default: return 0
    }
}

struct Trip: Identifiable {
    let raw: [String: Any]
    init(_ r: [String: Any]) { raw = r }
    private func n(_ k: String) -> Double { anyNum2(raw[k]) }

    var id: Double { let s = n("startMs"); return s > 0 ? s : n("tripId") }
    var tripId: String { (raw["tripId"] as? String) ?? String(Int(id)) }
    var date: Date { Date(timeIntervalSince1970: id / 1000) }
    var distKm: Double { n("distKm") }
    var netKwh: Double { n("netKwh") }
    var fuelL: Double { n("fuelL") }
    var timeSec: Double { n("timeSec") }
    var rawName: String? { (raw["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    var knownStart: String? { raw["knownStart"] as? String }
    var knownEnd: String? { raw["knownEnd"] as? String }
    var startCoord: CLLocationCoordinate2D? { let la = n("startLat"), lo = n("startLng"); return (la != 0 && lo != 0) ? .init(latitude: la, longitude: lo) : nil }
    var endCoord: CLLocationCoordinate2D? { let la = n("endLat"), lo = n("endLng"); return (la != 0 && lo != 0) ? .init(latitude: la, longitude: lo) : nil }
    func cost(_ pKwh: Double, _ pGas: Double) -> Double { netKwh * pKwh + fuelL * pGas }
    var consumo: Double { distKm > 0.5 ? netKwh / distKm * 100 : 0 }
    var valid: Bool { distKm > 0.1 || timeSec > 60 }
}

@MainActor
final class TripsLoader: ObservableObject {
    @Published var trips: [Trip] = []
    @Published var loading = false
    @Published var diag = ""
    @Published var geoNames: [Double: String] = [:]   // tripId(startMs) → "Bairro, Cidade"
    private let geocoder = CLGeocoder()

    private var base: String {
        let u = Settings.bridgeURL.isEmpty ? AuthConfig.bridgeURL : Settings.bridgeURL
        return u.hasSuffix("/") ? String(u.dropLast()) : u
    }
    private func req(_ path: String, _ method: String, _ body: [String: Any]? = nil) -> URLRequest? {
        guard let url = URL(string: "\(base)\(path)") else { return nil }
        var r = URLRequest(url: url); r.httpMethod = method; r.timeoutInterval = 12
        r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        if let body { r.addValue("application/json", forHTTPHeaderField: "Content-Type"); r.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        return r
    }

    func load() async {
        guard Settings.isConfigured, let r = req("/api/autotrips", "GET") else { diag = "app não configurado"; return }
        loading = true
        do {
            let (data, resp) = try await URLSession.shared.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200 else { diag = "HTTP \(code) em /api/autotrips"; loading = false; return }
            let any = try? JSONSerialization.jsonObject(with: data)
            let arr = (any as? [[String: Any]]) ?? ((any as? [String: Any])?["trips"] as? [[String: Any]]) ?? []
            trips = arr.map(Trip.init).filter { $0.valid }.sorted { $0.id > $1.id }
            diag = "recebidas \(arr.count) · válidas \(trips.count)"
        } catch { diag = "erro: \(error.localizedDescription)" }
        loading = false
    }

    /// Nome de exibição: name salvo → conhecidos → geocode (bairro+cidade) → "Trajeto".
    func displayName(_ t: Trip) -> String {
        if let n = t.rawName { return n }
        let ks = t.knownStart, ke = t.knownEnd
        if ks != nil || ke != nil { return "\(ks ?? "?") → \(ke ?? "?")" }
        return geoNames[t.id] ?? "Trajeto"
    }
    func geocodeIfNeeded(_ t: Trip) {
        guard t.rawName == nil, t.knownStart == nil, t.knownEnd == nil, geoNames[t.id] == nil, let c = t.endCoord else { return }
        geoNames[t.id] = "Trajeto"   // evita repetir
        geocoder.reverseGeocodeLocation(CLLocation(latitude: c.latitude, longitude: c.longitude)) { [weak self] places, _ in
            guard let p = places?.first else { return }
            let parts = [p.subLocality ?? p.thoroughfare, p.locality].compactMap { $0 }
            if !parts.isEmpty { Task { @MainActor in self?.geoNames[t.id] = parts.joined(separator: ", ") } }
        }
    }

    func remove(_ tripId: String) async {
        trips.removeAll { $0.tripId == tripId }
        guard let r = req("/api/autotrips/\(tripId)", "DELETE") else { return }
        _ = try? await URLSession.shared.data(for: r)
    }
    func rename(_ tripId: String, _ name: String) async {
        guard let r = req("/api/rename", "POST", ["tripId": tripId, "type": "auto", "name": name]) else { return }
        _ = try? await URLSession.shared.data(for: r)
        await load()
    }
}

struct NativeViagensView: View {
    @StateObject private var loader = TripsLoader()
    @ObservedObject private var car = CarStore.shared
    @State private var tab = 0
    @AppStorage("via_period") private var period = 0
    @AppStorage("via_from") private var fromTS: Double = 0
    @AppStorage("via_to") private var toTS: Double = 0
    @State private var showCal = false
    @State private var expandedId: Double?
    @State private var routeTrip: Trip?

    private var fromDate: Binding<Date> { Binding(get: { fromTS > 0 ? Date(timeIntervalSince1970: fromTS) : Date() }, set: { fromTS = $0.timeIntervalSince1970 }) }
    private var toDate: Binding<Date> { Binding(get: { toTS > 0 ? Date(timeIntervalSince1970: toTS) : Date() }, set: { toTS = $0.timeIntervalSince1970 }) }

    private func f0(_ v: Double) -> String { Fmt.int(v) }
    private func f1(_ v: Double) -> String { Fmt.dec2(v) }   // 2 casas
    private func km(_ v: Double) -> String { Fmt.km(v) }      // <100: 2 casas, >=100: inteiro
    private func brl(_ v: Double) -> String { Fmt.brl(v) }
    private func dur(_ s: Double) -> String { let t = Int(s), h = t/3600, m = (t%3600)/60; return h > 0 ? "\(h)h \(m)min" : "\(m) min" }
    private static let df: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR"); f.dateFormat = "d MMM · HH:mm"; return f }()

    private var filtered: [Trip] {
        let now = Date(); let cal = Calendar.current
        switch period {
        case 0: return loader.trips.filter { cal.isDate($0.date, inSameDayAs: now) }
        case 1: let lim = now.addingTimeInterval(-7*86400);  return loader.trips.filter { $0.date >= lim }
        case 2: let lim = now.addingTimeInterval(-30*86400); return loader.trips.filter { $0.date >= lim }
        case 4:
            let lo = cal.startOfDay(for: fromDate.wrappedValue)
            let hi = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: toDate.wrappedValue)) ?? toDate.wrappedValue
            return loader.trips.filter { $0.date >= lo && $0.date < hi }
        default: return loader.trips
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Picker("", selection: $tab) { Text("Histórico").tag(0); Text("Estatísticas").tag(1) }.pickerStyle(.segmented)
                periodChips
                if period == 4 && showCal {
                    DSCard {
                        VStack(spacing: 10) {
                            DatePicker("De", selection: fromDate, displayedComponents: .date)
                            DatePicker("Até", selection: toDate, in: fromDate.wrappedValue..., displayedComponents: .date)
                        }.font(.system(size: 14)).foregroundStyle(DS.text).tint(DS.green).environment(\.locale, Locale(identifier: "pt_BR"))
                    }
                }
                if tab == 0 { historico } else { estatisticas }
            }
            .padding(16)
        }
        .background(DS.bg.ignoresSafeArea())
        .overlay { if loader.loading && loader.trips.isEmpty { ProgressView().tint(DS.green) } }
        .refreshable { await loader.load() }
        .task { if loader.trips.isEmpty { await loader.load() } }
        .sheet(item: $routeTrip) { t in RouteMapSheet(trip: t) }
    }

    private var periodChips: some View {
        let opts = ["Hoje", "7 dias", "30 dias", "Tudo", "Calendário"]
        return HStack(spacing: 6) {
            ForEach(Array(opts.enumerated()), id: \.offset) { i, label in
                let on = period == i
                Button {
                    if i == 4 { showCal = (period == 4) ? !showCal : true } else { showCal = false }
                    period = i
                } label: {
                    Text(label).font(.system(size: 11, weight: .bold)).minimumScaleFactor(0.8).lineLimit(1)
                        .frame(maxWidth: .infinity).frame(height: 36)
                        .foregroundStyle(on ? .black : DS.text).background(on ? DS.green : DS.panel2).clipShape(Capsule())
                }
            }
        }
    }

    private var historico: some View {
        VStack(spacing: 14) {
            if filtered.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nenhuma viagem no período.").font(.subheadline).foregroundStyle(DS.muted)
                    if !loader.diag.isEmpty { Text(loader.diag).font(.caption2).foregroundStyle(DS.muted.opacity(0.7)) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 20)
            }
            ForEach(filtered) { t in tripCard(t) }
        }
    }

    private func tripCard(_ t: Trip) -> some View {
        let cost = t.cost(car.priceKwh, car.priceGas)
        let expanded = expandedId == t.id
        return DSCard {
            VStack(alignment: .leading, spacing: 12) {
                Button { withAnimation(.easeInOut(duration: 0.2)) { expandedId = expanded ? nil : t.id } } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "car.fill").font(.caption).foregroundStyle(DS.teal)
                            Text(loader.displayName(t)).font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.text).lineLimit(1)
                            Spacer()
                            Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(DS.muted)
                        }
                        Text(Self.df.string(from: t.date)).font(.caption).foregroundStyle(DS.muted).frame(maxWidth: .infinity, alignment: .leading)
                        HStack {
                            DSMetric(value: km(t.distKm), unit: "km", label: "Distância", color: DS.teal)
                            DSMetric(value: f1(t.netKwh), unit: "kWh", label: "Energia", color: DS.green)
                            DSMetric(value: cost > 0 ? brl(cost) : "—", label: "Custo")
                        }
                    }
                }.buttonStyle(.plain)

                if expanded {
                    Divider().overlay(DS.border)
                    HStack(spacing: 14) {
                        miniLabel("Tempo", dur(t.timeSec))
                        miniLabel("Consumo", t.consumo > 0 ? "\(f1(t.consumo)) kWh/100" : "—")
                        if t.fuelL > 0.05 { miniLabel("Gasolina", "\(f1(t.fuelL)) L") }
                    }
                    RenameField(tripId: t.tripId, current: loader.displayName(t)) { name in
                        Task { await loader.rename(t.tripId, name) }
                    }
                    HStack(spacing: 10) {
                        DSActionButton(icon: "map.fill", title: "Ver trajeto", color: DS.teal) { routeTrip = t }
                        DSActionButton(icon: "trash.fill", title: "Excluir", color: DS.red) {
                            Task { await loader.remove(t.tripId); expandedId = nil }
                        }
                    }
                }
            }
        }
        .onAppear { loader.geocodeIfNeeded(t) }
    }

    private var estatisticas: some View {
        let f = filtered
        let totalKm = f.reduce(0) { $0 + $1.distKm }
        let kwh = f.reduce(0) { $0 + $1.netKwh }
        let fuel = f.reduce(0) { $0 + $1.fuelL }
        let cost = f.reduce(0) { $0 + $1.cost(car.priceKwh, car.priceGas) }
        return VStack(spacing: 14) {
            if f.isEmpty {
                Text("Sem dados no período.").font(.subheadline).foregroundStyle(DS.muted).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 20)
            } else {
                DSCard {
                    HStack {
                        DSMetric(value: "\(f.count)", label: "Viagens", color: DS.teal)
                        DSMetric(value: km(totalKm), unit: "km", label: "Distância", color: DS.green)
                        DSMetric(value: brl(cost), label: "Custo est.")
                    }
                }
                DSCard {
                    HStack {
                        DSMetric(value: totalKm > 1 ? f1(kwh/totalKm*100) : "—", unit: "kWh/100", label: "Consumo médio")
                        DSMetric(value: totalKm > 1 ? brl(cost/totalKm) : "—", label: "R$/km", color: DS.green)
                        DSMetric(value: f1(fuel), unit: "L", label: "Gasolina", color: DS.orange)
                    }
                }
                monthlyChart(f)
            }
        }
    }

    private func monthlyChart(_ f: [Trip]) -> some View {
        struct Bucket: Identifiable { let id: String; let label: String; let km: Double }
        let fmt = DateFormatter(); fmt.locale = Locale(identifier: "pt_BR"); fmt.dateFormat = "MMM/yy"
        let keyFmt = DateFormatter(); keyFmt.dateFormat = "yyyy-MM"
        var map: [String: (String, Double)] = [:]
        for t in f { let k = keyFmt.string(from: t.date); map[k] = (fmt.string(from: t.date), (map[k]?.1 ?? 0) + t.distKm) }
        let buckets = map.sorted { $0.key < $1.key }.map { Bucket(id: $0.key, label: $0.value.0, km: $0.value.1) }
        return DSCard(title: "km por mês", icon: "chart.bar.fill") {
            if buckets.count < 2 { Text("Precisa de mais de um mês de dados.").font(.caption).foregroundStyle(DS.muted) }
            else {
                Chart(buckets) { b in BarMark(x: .value("Mês", b.label), y: .value("km", b.km)).foregroundStyle(DS.teal) }
                    .frame(height: 160).chartYAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(DS.border); AxisValueLabel() } }
            }
        }
    }

    private func miniLabel(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(DS.muted)
            Text(v).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.text)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

// Campo de edição de nome (estado local + salvar)
private struct RenameField: View {
    let tripId: String
    let current: String
    let onSave: (String) -> Void
    @State private var text = ""
    @State private var loaded = false
    var body: some View {
        HStack {
            TextField("Nome da viagem", text: $text)
                .foregroundStyle(DS.text).padding(8).background(DS.panel2)
                .clipShape(RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(DS.border, lineWidth: 1))
            Button("Salvar") { if !text.isEmpty { onSave(text) } }
                .font(.system(size: 13, weight: .bold)).foregroundStyle(DS.green)
        }
        .onAppear { if !loaded { text = current; loaded = true } }
    }
}

// MARK: - Trajeto: mapa + linha do tempo (velocidade/potência/rpm/SOC/kWh acum.)
struct TripSample: Identifiable {
    let id = UUID()
    let min: Double      // minuto da viagem
    let spd: Double
    let rpm: Double
    let pwr: Double
    let soc: Double
    let cumKwh: Double
}

struct RouteMapSheet: View {
    let trip: Trip
    @Environment(\.dismiss) private var dismiss
    @State private var coords: [CLLocationCoordinate2D] = []
    @State private var samples: [TripSample] = []
    @State private var loading = true
    @State private var metric = 0   // 0=Vel,1=Pot,2=RPM,3=SOC,4=kWh

    private let metrics = ["Velocidade", "Potência", "RPM", "SOC", "kWh acum."]
    private let units = ["km/h", "kW", "rpm", "%", "kWh"]
    private let colors = [DS.teal, DS.blue, DS.orange, DS.green, DS.yellow]

    private var base: String {
        let u = Settings.bridgeURL.isEmpty ? AuthConfig.bridgeURL : Settings.bridgeURL
        return u.hasSuffix("/") ? String(u.dropLast()) : u
    }
    private func value(_ s: TripSample) -> Double {
        switch metric { case 0: return s.spd; case 1: return s.pwr; case 2: return s.rpm; case 3: return s.soc; default: return s.cumKwh }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if coords.count > 1 {
                        Map {
                            MapPolyline(coordinates: coords).stroke(DS.green, lineWidth: 4)
                            if let s = coords.first { Marker("Início", coordinate: s).tint(.green) }
                            if let e = coords.last { Marker("Fim", coordinate: e).tint(.red) }
                        }
                        .mapStyle(.standard(pointsOfInterest: .excludingAll))
                        .environment(\.colorScheme, .dark)
                        .frame(height: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    } else if !loading {
                        Text("Mapa indisponível.").font(.subheadline).foregroundStyle(DS.muted)
                    }

                    if !samples.isEmpty {
                        DSCard(title: "Linha do tempo", icon: "waveform.path.ecg") {
                            VStack(spacing: 10) {
                                Picker("", selection: $metric) {
                                    ForEach(Array(metrics.enumerated()), id: \.offset) { i, m in Text(m).tag(i) }
                                }.pickerStyle(.segmented)
                                Chart(samples) { s in
                                    LineMark(x: .value("min", s.min), y: .value("v", value(s)))
                                        .foregroundStyle(colors[metric]).interpolationMethod(.monotone)
                                }
                                .frame(height: 200)
                                .chartXAxisLabel("min")
                                .chartYAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(DS.border); AxisValueLabel() } }
                                Text(units[metric]).font(.caption2).foregroundStyle(DS.muted).frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }
                    } else if loading {
                        ProgressView().tint(DS.green).padding(.top, 30)
                    }
                }
                .padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Trajeto").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Concluído") { dismiss() } } }
        }
        .task { await load() }
    }

    private func load() async {
        guard let url = URL(string: "\(base)/api/telemetry/\(trip.tripId)") else { loading = false; return }
        var req = URLRequest(url: url); req.timeoutInterval = 15
        req.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        defer { loading = false }
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["samples"] as? [[String: Any]] else { return }
        coords = raw.compactMap { s in
            let la = anyNum2(s["lat"]), lo = anyNum2(s["lng"])
            return (la != 0 && lo != 0) ? CLLocationCoordinate2D(latitude: la, longitude: lo) : nil
        }
        var cum = 0.0; var lastT = 0.0; var out: [TripSample] = []
        for s in raw {
            let t = anyNum2(s["t"])
            let pwr = anyNum2(s["pwr"]) != 0 ? anyNum2(s["pwr"]) : anyNum2(s["evKw"])
            let dt = max(0, t - lastT); lastT = t
            cum += pwr * dt / 3600.0
            out.append(TripSample(min: t / 60.0, spd: anyNum2(s["spd"]), rpm: anyNum2(s["rpm"]),
                                  pwr: pwr, soc: anyNum2(s["soc"]), cumKwh: cum))
        }
        // Reduz pontos pra render fluida (máx ~400)
        if out.count > 400 { let step = out.count / 400 + 1; out = out.enumerated().filter { $0.offset % step == 0 }.map { $0.element } }
        samples = out
    }
}
