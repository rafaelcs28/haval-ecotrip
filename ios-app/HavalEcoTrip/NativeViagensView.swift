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
import Combine

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
    var updatedMs: Double { n("_updated_ms") }
    var rawName: String? { (raw["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    // O bridge grava o nome do local em startKp/endKp (reprocess-places + Locais
    // Conhecidos). knownStart/knownEnd são legado/fallback.
    var knownStart: String? { ((raw["startKp"] ?? raw["knownStart"]) as? String).flatMap { $0.isEmpty ? nil : $0 } }
    var knownEnd: String? { ((raw["endKp"] ?? raw["knownEnd"]) as? String).flatMap { $0.isEmpty ? nil : $0 } }
    var startCoord: CLLocationCoordinate2D? { let la = n("startLat"), lo = n("startLng"); return (la != 0 && lo != 0) ? .init(latitude: la, longitude: lo) : nil }
    var endCoord: CLLocationCoordinate2D? { let la = n("endLat"), lo = n("endLng"); return (la != 0 && lo != 0) ? .init(latitude: la, longitude: lo) : nil }
    func cost(_ pKwh: Double, _ pGas: Double) -> Double { netKwh * pKwh + fuelL * pGas }
    var consumo: Double { distKm > 0.5 ? netKwh / distKm * 100 : 0 }
    var valid: Bool { distKm > 0.1 || timeSec > 60 }
}

@MainActor
final class TripsLoader: ObservableObject {
    let sync = SyncedList(name: "autotrips", path: "/api/autotrips", idKeys: ["startMs", "tripId"], incremental: true, tombstoneKey: "autotrips")
    @Published var loading = false
    @Published var diag = ""
    @Published var geoNames: [Double: String] = [:]   // tripId(startMs) → "Bairro, Cidade"
    private let geocoder = CLGeocoder()
    private var bag: AnyCancellable?
    private var prefetching = false

    init() { bag = sync.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() } }

    var trips: [Trip] { sync.items.map(Trip.init).filter { $0.valid }.sorted { $0.id > $1.id } }

    private var base: String {
        let u = Settings.bridgeURL.isEmpty ? AuthConfig.bridgeURL : Settings.bridgeURL
        return u.hasSuffix("/") ? String(u.dropLast()) : u
    }

    /// Baixa em background o trajeto (samples) das viagens que ainda não estão em
    /// disco OU cujo cache ficou velho (resume/reprocess bumpou _updated_ms). Roda
    /// sozinho a cada load() — sem botão. ~23 MB pra coleção inteira; depois cada
    /// viagem abre offline. Silencioso: falhas (offline) só ficam pra próxima vez.
    func prefetchTrajetos() async {
        guard !prefetching, Settings.isConfigured else { return }
        prefetching = true; defer { prefetching = false }
        for t in trips {
            let id = t.tripId
            let cachedMs = OfflineCache.trajMtimeMs(id)
            if cachedMs > 0 && t.updatedMs <= cachedMs { continue }   // já em disco e fresco
            guard let url = URL(string: "\(base)/api/telemetry/\(id)") else { continue }
            var req = URLRequest(url: url); req.timeoutInterval = 20
            req.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
            if let (d, resp) = try? await URLSession.shared.data(for: req),
               let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                OfflineCache.saveTraj(id, d)
            }
        }
    }

    func load() async {
        loading = sync.items.isEmpty
        await sync.sync()
        diag = "itens \(sync.items.count) · válidas \(trips.count)\(sync.pendingCount > 0 ? " · \(sync.pendingCount) pend." : "")"
        loading = false
        // Em background, baixa os trajetos que faltam/ficaram velhos (sem bloquear a UI).
        Task { await prefetchTrajetos() }
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
        // localId = startMs (id da lista). Remove local + enfileira DELETE.
        if let it = sync.items.first(where: { ("\($0["tripId"] ?? "")") == tripId }) {
            let lid = "\(it["startMs"] ?? tripId)"
            await sync.mutate(localId: lid, apply: { $0 }, method: "DELETE", opPath: "/api/autotrips/\(tripId)", body: nil)
        } else {
            await sync.mutate(localId: tripId, apply: { $0 }, method: "DELETE", opPath: "/api/autotrips/\(tripId)", body: nil)
        }
    }
    func rename(_ tripId: String, _ name: String) async {
        if let it = sync.items.first(where: { ("\($0["tripId"] ?? "")") == tripId }) {
            let lid = "\(it["startMs"] ?? tripId)"
            await sync.mutate(localId: lid, apply: { var d = $0; d["name"] = name; return d },
                              method: "POST", opPath: "/api/rename", body: ["tripId": tripId, "type": "auto", "name": name])
        }
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
    @State private var search = ""

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
        let base: [Trip]
        switch period {
        case 0: base = loader.trips.filter { cal.isDate($0.date, inSameDayAs: now) }
        case 1: let lim = now.addingTimeInterval(-7*86400);  base = loader.trips.filter { $0.date >= lim }
        case 2: let lim = now.addingTimeInterval(-30*86400); base = loader.trips.filter { $0.date >= lim }
        case 4:
            let lo = cal.startOfDay(for: fromDate.wrappedValue)
            let hi = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: toDate.wrappedValue)) ?? toDate.wrappedValue
            base = loader.trips.filter { $0.date >= lo && $0.date < hi }
        default: base = loader.trips
        }
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return base }
        // Busca por nome ignora o período — procura em todas as viagens.
        return loader.trips.filter { loader.displayName($0).localizedCaseInsensitiveContains(q) }
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
                if tab == 0 { searchBar; historico } else { estatisticas }
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

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(DS.muted)
            TextField("Buscar por local", text: $search)
                .font(.system(size: 15)).foregroundStyle(DS.text)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(DS.muted) }
            }
        }
        .padding(.horizontal, 12).frame(height: 40)
        .background(DS.panel2).clipShape(RoundedRectangle(cornerRadius: 10))
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

// MARK: - Trajeto: mapa de fundo + scrubber (igual PWA — arrasta a linha do tempo
// e os valores daquele instante aparecem por cima do mapa)
struct TripSample: Identifiable {
    let id = UUID()
    let t: Double        // segundos desde o início
    let coord: CLLocationCoordinate2D?
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
    @State private var idx: Double = 0
    @State private var cam: MapCameraPosition = .automatic

    private var base: String {
        let u = Settings.bridgeURL.isEmpty ? AuthConfig.bridgeURL : Settings.bridgeURL
        return u.hasSuffix("/") ? String(u.dropLast()) : u
    }
    private var cur: TripSample? { samples.isEmpty ? nil : samples[min(samples.count - 1, max(0, Int(idx)))] }
    private func f0(_ v: Double) -> String { String(format: "%.0f", v) }
    private func f1(_ v: Double) -> String { String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",") }
    private func tStr(_ s: Double) -> String { let t = Int(s), m = t/60, sec = t%60; return String(format: "%d:%02d", m, sec) }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                if coords.count > 1 {
                    Map(position: $cam, interactionModes: .all) {
                        MapPolyline(coordinates: coords).stroke(DS.green, lineWidth: 4)
                        if let c = cur?.coord {
                            Annotation("", coordinate: c) {
                                ZStack {
                                    Circle().fill(DS.green.opacity(0.25)).frame(width: 34, height: 34)
                                    Circle().fill(DS.green).frame(width: 14, height: 14).overlay(Circle().stroke(.white, lineWidth: 2))
                                }
                            }
                        }
                    }
                    .mapStyle(.standard(pointsOfInterest: .excludingAll))
                    .environment(\.colorScheme, .dark)
                    .ignoresSafeArea()
                } else {
                    DS.bg.ignoresSafeArea()
                    if loading { ProgressView().tint(DS.green) } else { Text("Trajeto indisponível.").foregroundStyle(DS.muted) }
                }

                // Valores do instante (topo) + scrubber (base)
                VStack {
                    if let s = cur {
                        DSCard(glass: true) {
                            HStack {
                                DSMetric(value: f0(s.spd), unit: "km/h", label: "Velocidade", color: DS.text)
                                DSMetric(value: f1(s.pwr), unit: "kW", label: "Potência", color: s.pwr < 0 ? DS.green : DS.blue)
                                DSMetric(value: s.rpm > 0 ? f0(s.rpm) : "—", unit: "rpm", label: "Motor", color: DS.orange)
                            }
                            HStack {
                                DSMetric(value: f0(s.soc), unit: "%", label: "SOC", color: DS.green)
                                DSMetric(value: f1(s.cumKwh), unit: "kWh", label: "Acumulado", color: DS.teal)
                                DSMetric(value: tStr(s.t), label: "Tempo", color: DS.muted)
                            }
                        }.padding(.horizontal, 12).padding(.top, 8)
                    }
                    Spacer()
                    if samples.count > 1 {
                        DSCard(glass: true) {
                            VStack(spacing: 4) {
                                Slider(value: $idx, in: 0...Double(samples.count - 1), step: 1).tint(DS.green)
                                HStack {
                                    Text("Início").font(.caption2).foregroundStyle(DS.muted)
                                    Spacer()
                                    Text(tStr(cur?.t ?? 0)).font(.caption.weight(.bold)).foregroundStyle(DS.green)
                                    Spacer()
                                    Text(tStr(samples.last?.t ?? 0)).font(.caption2).foregroundStyle(DS.muted)
                                }
                            }
                        }.padding(.horizontal, 12).padding(.bottom, 8)
                    }
                }
            }
            .navigationTitle("Trajeto").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Concluído") { dismiss() } } }
        }
        .task { await load() }
    }

    private func load() async {
        guard let url = URL(string: "\(base)/api/telemetry/\(trip.tripId)") else { loading = false; return }
        var req = URLRequest(url: url); req.timeoutInterval = 15
        req.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        defer { loading = false }
        // Online: busca e cacheia em disco. Offline/erro: usa o cache (se já abriu antes).
        var data: Data?
        if let (d, resp) = try? await URLSession.shared.data(for: req),
           let http = resp as? HTTPURLResponse, http.statusCode == 200 {
            data = d
            OfflineCache.saveTraj(trip.tripId, d)
        } else {
            data = OfflineCache.loadTraj(trip.tripId)
        }
        guard let data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["samples"] as? [[String: Any]] else { return }
        coords = raw.compactMap { s in
            let la = anyNum2(s["lat"]), lo = anyNum2(s["lng"])
            return (la != 0 && lo != 0) ? CLLocationCoordinate2D(latitude: la, longitude: lo) : nil
        }
        // kWh acumulado: integra evKw × dt (igual ao PWA — positivo=consumo).
        // Guard de gap <30s: salto grande = carro desligado entre trechos (resume),
        // sem energia fluindo no buraco — evita o acumulado "cair e recomeçar".
        var cum = 0.0; var lastT = 0.0; var first = true; var out: [TripSample] = []
        for s in raw {
            let t = anyNum2(s["t"])
            let kw = anyNum2(s["evKw"])
            if !first { let rawDt = t - lastT; let dt = (rawDt > 0 && rawDt < 30) ? rawDt : 0; cum += kw * dt / 3600.0 }
            first = false; lastT = t
            let la = anyNum2(s["lat"]), lo = anyNum2(s["lng"])
            out.append(TripSample(t: t, coord: (la != 0 && lo != 0) ? .init(latitude: la, longitude: lo) : nil,
                                  spd: anyNum2(s["spd"]), rpm: anyNum2(s["rpm"]), pwr: kw, soc: anyNum2(s["soc"]), cumKwh: cum))
        }
        if out.count > 600 { let step = out.count / 600 + 1; out = out.enumerated().filter { $0.offset % step == 0 }.map { $0.element } }
        samples = out
        if let first = coords.first {
            cam = .region(MKCoordinateRegion(center: first, span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)))
        }
    }
}
