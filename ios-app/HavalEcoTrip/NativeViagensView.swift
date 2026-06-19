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
    var startSoc: Double { n("startSocPct") }
    var endSoc: Double { n("endSocPct") }
    var elevGain: Double { n("elevGainM") }
    var elevLoss: Double { n("elevLossM") }
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
    // Mostra também o consumo PARADO (0 km / 0 s mas energia gasta — HVAC/pré-clima/
    // standby). Espelha o que o bridge decide manter (descarta só se dist≈0 E energia
    // <0.10 E <60s). Importante pra estatística de consumo de energia.
    var valid: Bool { distKm > 0.1 || timeSec > 60 || netKwh >= 0.10 || fuelL >= 0.05 }
    // Score de condução calculado no bridge (economia + suavidade). nil = viagem antiga.
    var driveScore: Int? { raw["driveScore"] == nil ? nil : Int(n("driveScore")) }
    var harshAcc: Int { Int(n("harshAcc")) }
    var harshBrake: Int { Int(n("harshBrake")) }
    var outsideTemp: Double? { raw["outsideTemp"] == nil ? nil : n("outsideTemp") }
}

@MainActor
final class TripsLoader: ObservableObject {
    // Singleton: Dash, Viagens, ChargeForecast e Preclimat compartilham UM loader —
    // antes cada tela criava o seu, sincronizando /api/autotrips em duplicata e
    // mantendo cópias separadas da mesma coleção em memória.
    static let shared = TripsLoader()

    let sync = SyncedList(name: "autotrips", path: "/api/autotrips", idKeys: ["startMs", "tripId"], incremental: true, tombstoneKey: "autotrips")
    @Published var loading = false
    @Published var diag = ""
    @Published var geoStart: [Double: String] = [:]   // tripId(startMs) → "Bairro, Cidade" (origem)
    @Published var geoEnd:   [Double: String] = [:]   // tripId(startMs) → "Bairro, Cidade" (destino)
    private let geocoder = CLGeocoder()
    private var bag: AnyCancellable?
    private var prefetching = false

    // Cacheado: recomputa map/filter/sort SÓ quando sync.items muda. Antes era um
    // computed var refeito a cada acesso (filtered, estatísticas, cada card, 7 sheets)
    // → dezenas de map+sort sobre a lista inteira por render.
    @Published private(set) var trips: [Trip] = []

    init() {
        // $items emite o valor atual na subscrição + a cada mudança. Setar `trips`
        // (@Published) já dispara o rebuild da view — não precisa relay manual.
        bag = sync.$items.sink { [weak self] items in
            self?.trips = items.map(Trip.init).filter { $0.valid }.sorted { $0.id > $1.id }
        }
    }

    private var base: String {
        let u = Settings.bridgeURL.isEmpty ? AuthConfig.bridgeURL : Settings.bridgeURL
        return u.hasSuffix("/") ? String(u.dropLast()) : u
    }

    /// Baixa em background o trajeto (samples) das viagens que ainda não estão em
    /// disco OU cujo cache ficou velho (resume/reprocess bumpou _updated_ms). Roda
    /// sozinho a cada load() — sem botão. Limitado às 30 mais recentes (a coleção
    /// inteira eram ~23 MB por sessão); viagens antigas baixam ao abrir o detalhe
    /// (TripDetail.load já cacheia). Silencioso: falhas ficam pra próxima vez.
    func prefetchTrajetos() async {
        guard !prefetching, Settings.isConfigured else { return }
        prefetching = true; defer { prefetching = false }
        for t in trips.prefix(30) {
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

    /// Nome de exibição: name salvo → "origem → destino", onde cada lado é o local
    /// conhecido (startKp/endKp) ou, se não cadastrado, o bairro/cidade via geocode.
    func displayName(_ t: Trip) -> String {
        if let n = t.rawName { return n }
        let start = t.knownStart ?? geoStart[t.id]
        let end   = t.knownEnd   ?? geoEnd[t.id]
        if start == nil && end == nil { return "Trajeto" }
        return "\(start ?? "…") → \(end ?? "…")"
    }
    /// Geocodifica QUALQUER ponta sem local conhecido (origem e/ou destino),
    /// pra não sobrar "?" quando só um lado é cadastrado.
    func geocodeIfNeeded(_ t: Trip) {
        guard t.rawName == nil else { return }
        if t.knownStart == nil, geoStart[t.id] == nil, let c = t.startCoord {
            geoStart[t.id] = "…"
            reverseGeo(c) { [weak self] name in self?.geoStart[t.id] = name }
        }
        if t.knownEnd == nil, geoEnd[t.id] == nil, let c = t.endCoord {
            geoEnd[t.id] = "…"
            reverseGeo(c) { [weak self] name in self?.geoEnd[t.id] = name }
        }
    }
    private func reverseGeo(_ c: CLLocationCoordinate2D, _ done: @escaping (String) -> Void) {
        geocoder.reverseGeocodeLocation(CLLocation(latitude: c.latitude, longitude: c.longitude)) { places, _ in
            guard let p = places?.first else { return }
            let parts = [p.subLocality ?? p.thoroughfare, p.locality].compactMap { $0 }
            if !parts.isEmpty { Task { @MainActor in done(parts.joined(separator: ", ")) } }
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
    @ObservedObject private var loader = TripsLoader.shared
    @ObservedObject private var car = CarStore.shared
    @State private var tab = 0
    @AppStorage("via_period") private var period = 0
    @AppStorage("via_from") private var fromTS: Double = 0
    @AppStorage("via_to") private var toTS: Double = 0
    @State private var showCal = false
    @State private var expandedId: Double?
    @State private var routeTrip: Trip?
    @State private var search = ""
    @State private var showInsights = false
    @State private var showEco = false
    @State private var showReport = false
    @State private var showRoutes = false
    @State private var showMilestones = false
    @State private var showTemp = false
    @State private var showByMode = false
    @State private var showSavings = false

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
                if tab == 0 { searchBar; historico } else { estatisticas; statsGrid }
            }
            .padding(16)
        }
        .background(DS.bg.ignoresSafeArea())
        .overlay { if loader.loading && loader.trips.isEmpty { ProgressView().tint(DS.green) } }
        .refreshable { await loader.load() }
        // Sincroniza SEMPRE ao abrir (não só com cache vazio): senão viagens novas
        // só entravam via pull-to-refresh manual. Mesmo ajuste feito em Recargas.
        .task { await loader.load() }
        .sheet(item: $routeTrip) { t in RouteMapSheet(trip: t) }
        .sheet(isPresented: $showInsights) {
            InsightsSheet(trips: loader.trips, priceKwh: car.priceKwh, priceGas: car.priceGas, kmPerLGas: car.kmPerL)
        }
        .sheet(isPresented: $showEco) { EcoScoreSheet(trips: loader.trips) }
        .sheet(isPresented: $showReport) {
            MonthlyReportSheet(trips: loader.trips, priceKwh: car.priceKwh, priceGas: car.priceGas, kmPerLGas: car.kmPerL)
        }
        .sheet(isPresented: $showRoutes) { RouteCompareSheet(trips: loader.trips) }
        .sheet(isPresented: $showMilestones) { MilestonesSheet(odometerKm: car.num("odometer_km"), trips: loader.trips) }
        .sheet(isPresented: $showTemp) { TempConsumptionSheet(trips: loader.trips) }
        .sheet(isPresented: $showByMode) { ModeEconomySheet() }
        .sheet(isPresented: $showSavings) { SavingsSheet() }
    }

    private var statsGrid: some View {
        let cols = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
        let ecoVal: Int? = Eco.avg(loader.trips.filter { $0.date > Date().addingTimeInterval(-7*86400) }) ?? Eco.avg(loader.trips)
        return VStack(alignment: .leading, spacing: 10) {
            sectionHeader("DESTE PERÍODO")
            LazyVGrid(columns: cols, spacing: 10) {
                gridTile(icon: "leaf.fill", title: "Economia", color: DS.green, value: economiaValue) { showInsights = true }
                gridTile(icon: "gauge.with.dots.needle.67percent", title: "Score", color: DS.teal,
                         value: ecoVal.map { "\($0)" }, valueColor: ecoVal.map { Eco.color($0) }) { showEco = true }
            }
            sectionHeader("EXPLORAR").padding(.top, 4)
            LazyVGrid(columns: cols, spacing: 10) {
                gridTile(icon: "doc.text.fill", title: "Relatório", color: DS.blue) { showReport = true }
                gridTile(icon: "arrow.triangle.swap", title: "Trajetos", color: DS.orange) { showRoutes = true }
                gridTile(icon: "trophy.fill", title: "Marcos", color: DS.yellow) { showMilestones = true }
                gridTile(icon: "thermometer.medium", title: "Consumo × temp", color: DS.blue) { showTemp = true }
                gridTile(icon: "slider.horizontal.3", title: "Por modo", color: DS.green) { showByMode = true }
                gridTile(icon: "leaf.fill", title: "Economia total", color: DS.green) { showSavings = true }
            }
        }
    }

    private var economiaValue: String? {
        let f = filtered
        guard !f.isEmpty else { return nil }
        let baselineKmL = car.kmPerL > 1 ? car.kmPerL : 11
        let gasL = car.priceGas > 0 ? car.priceGas : 6.0
        let saved = f.reduce(0.0) { acc, t in
            acc + max((t.distKm / baselineKmL) * gasL - (t.netKwh * car.priceKwh + t.fuelL * gasL), 0)
        }
        return saved > 0 ? brl(saved) : nil
    }

    private func sectionHeader(_ s: String) -> some View {
        Text(s).font(.system(size: 11, weight: .bold)).foregroundStyle(DS.muted).kerning(0.5)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func gridTile(icon: String, title: String, color: Color, value: String? = nil,
                          valueColor: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: icon).font(.title3).foregroundStyle(color)
                    Spacer()
                    if let v = value { Text(v).font(.headline).foregroundStyle(valueColor ?? DS.text) }
                }
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(DS.text)
                    .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1).minimumScaleFactor(0.8)
            }
            .padding(14).frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
            .background(DS.panel).clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(DS.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
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
        // LazyVStack: renderiza só os cards visíveis. Com filtro "Tudo" o histórico
        // inteiro (centenas) era materializado de uma vez num VStack normal.
        LazyVStack(spacing: 14) {
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
                        DSMetric(value: f1(abs(t.netKwh)), unit: "kWh", label: t.netKwh < -0.01 ? "Recuperado" : "Energia", color: DS.green)
                        DSMetric(value: cost > 0 ? brl(cost) : "—", label: "Custo")
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { expandedId = expanded ? nil : t.id } }

                if expanded {
                    Divider().overlay(DS.border)
                    HStack(spacing: 14) {
                        miniLabel("Tempo", dur(t.timeSec))
                        miniLabel("Consumo", t.consumo > 0 ? "\(f1(t.consumo)) kWh/100" : "—")
                        if t.fuelL > 0.05 { miniLabel("Gasolina", "\(f1(t.fuelL)) L") }
                    }
                    if t.elevGain > 0 || t.elevLoss > 0 {
                        HStack(spacing: 14) {
                            miniLabel("Subida", "↑ \(Fmt.int(t.elevGain)) m")
                            miniLabel("Descida", "↓ \(Fmt.int(t.elevLoss)) m")
                        }
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
                    HStack(spacing: 6) {
                        DSMetric(value: totalKm > 1 ? f1(kwh/totalKm*100) : "—", unit: "kWh/100", label: "Consumo médio", compact: true)
                        DSMetric(value: totalKm > 1 ? brl(cost/totalKm) : "—", label: "R$/km", color: DS.green, compact: true)
                        DSMetric(value: f1(kwh), unit: "kWh", label: "Energia", color: DS.teal, compact: true)
                        DSMetric(value: f1(fuel), unit: "L", label: "Gasolina", color: DS.orange, compact: true)
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
    let alt: Double      // altitude (m) do GPS — linha do tempo de altimetria
    let cumKwh: Double
    let cumKm: Double
}

// Mini-gráfico (sparkline) da série inteira de uma métrica do trajeto, com marcador
// na posição atual do scrubber. `signed` desenha a linha do zero (ex: potência/regen).
private struct TripSparkline: View {
    let title: String
    let unit: String
    let values: [Double]
    let color: Color
    let progress: Double            // 0...1 — posição atual no tempo
    let signed: Bool
    let fmt: (Double) -> String
    var body: some View {
        let lo = values.min() ?? 0
        let hi = values.max() ?? 1
        let range = (hi - lo) > 0.001 ? (hi - lo) : 1
        let n = max(1, values.count - 1)
        let curIdx = max(0, min(values.count - 1, Int((progress * Double(n)).rounded())))
        let curVal = values.isEmpty ? 0 : values[curIdx]
        VStack(spacing: 2) {
            HStack {
                Text(title).font(.caption2).foregroundStyle(DS.muted)
                Spacer()
                Text("\(fmt(curVal)) \(unit)").font(.caption.weight(.bold)).foregroundStyle(color)
            }
            Canvas { ctx, size in
                guard values.count > 1 else { return }
                let w = size.width, h = size.height
                func pt(_ i: Int) -> CGPoint {
                    CGPoint(x: w * Double(i) / Double(n), y: h - (values[i] - lo) / range * h)
                }
                if signed && lo < 0 && hi > 0 {
                    let zy = h - (0 - lo) / range * h
                    var z = Path(); z.move(to: CGPoint(x: 0, y: zy)); z.addLine(to: CGPoint(x: w, y: zy))
                    ctx.stroke(z, with: .color(.gray.opacity(0.4)), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                }
                var p = Path(); p.move(to: pt(0))
                for i in 1..<values.count { p.addLine(to: pt(i)) }
                ctx.stroke(p, with: .color(color), lineWidth: 1.5)
                let mx = w * progress
                var m = Path(); m.move(to: CGPoint(x: mx, y: 0)); m.addLine(to: CGPoint(x: mx, y: h))
                ctx.stroke(m, with: .color(.white.opacity(0.7)), lineWidth: 1)
            }
            .frame(height: 32)
        }
    }
}

struct RouteMapSheet: View {
    let trip: Trip
    @Environment(\.dismiss) private var dismiss
    @State private var coords: [CLLocationCoordinate2D] = []
    @State private var samples: [TripSample] = []
    @State private var gpxURL: URL?
    @State private var cardURL: URL?
    @State private var loading = true
    @State private var idx: Double = 0
    @State private var cam: MapCameraPosition = .automatic
    @State private var follow = true   // mapa segue a posição da linha do tempo
    @State private var playing = false
    @State private var speed = 1        // 1×/2×/4× (replay completo em ~20s/velocidade)
    private let replaySeconds = 20.0
    private let playTimer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()
    // Calculado 1× após load(). Antes era computeDriving() dentro do body → varria
    // todos os samples a cada frame do slider de timeline.
    @State private var driving: (avg: Double, max: Double, pwr: Double, regenPct: Double, regenKwh: Double) = (0, 0, 0, 0, 0)

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
                    .onChange(of: idx) { _, _ in
                        guard follow, let c = cur?.coord else { return }
                        withAnimation(.easeOut(duration: 0.25)) {
                            cam = .region(MKCoordinateRegion(center: c, span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)))
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        Button { follow.toggle(); if follow, let c = cur?.coord { cam = .region(MKCoordinateRegion(center: c, span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))) } } label: {
                            Image(systemName: follow ? "location.fill" : "location")
                                .font(.system(size: 16, weight: .bold)).foregroundStyle(follow ? .black : DS.text)
                                .frame(width: 40, height: 40)
                                .background(follow ? DS.green : DS.panel2).clipShape(Circle())
                                .overlay(Circle().stroke(DS.border, lineWidth: 1))
                        }.padding(.top, 60).padding(.trailing, 14)
                    }
                } else {
                    DS.bg.ignoresSafeArea()
                    if loading { ProgressView().tint(DS.green) } else { Text("Trajeto indisponível.").foregroundStyle(DS.muted) }
                }

                // Valores do instante (topo) + scrubber (base)
                VStack {
                    if let s = cur {
                        DSCard(glass: true) {
                            HStack {
                                DSMetric(value: "\(Fmt.adjSpeed(s.spd))", unit: "km/h", label: "Velocidade", color: DS.text)
                                DSMetric(value: f1(s.pwr), unit: "kW", label: "Potência", color: s.pwr < 0 ? DS.green : DS.blue)
                                DSMetric(value: s.rpm > 0 ? f0(s.rpm) : "—", unit: "rpm", label: "Motor", color: DS.orange)
                            }
                            HStack {
                                DSMetric(value: f0(s.soc), unit: "%", label: "SOC", color: DS.green)
                                DSMetric(value: f1(s.cumKwh), unit: "kWh", label: "Acumulado", color: DS.teal)
                                DSMetric(value: f1(s.cumKm), unit: "km", label: "Distância", color: DS.muted)
                            }
                        }.padding(.horizontal, 12).padding(.top, 8)
                    }
                    Spacer()
                    if samples.count > 1 {
                        let prog = Double(min(samples.count - 1, max(0, Int(idx)))) / Double(samples.count - 1)
                        DSCard(glass: true) {
                            VStack(spacing: 8) {
                                // Linha do tempo completa de velocidade e potência (picos/vales do trajeto)
                                TripSparkline(title: "Velocidade", unit: "km/h", values: samples.map { Double(Fmt.adjSpeed($0.spd)) },
                                              color: DS.text, progress: prog, signed: false, fmt: f0)
                                TripSparkline(title: "Potência", unit: "kW", values: samples.map { $0.pwr },
                                              color: DS.blue, progress: prog, signed: true, fmt: f1)
                                if samples.contains(where: { $0.alt != 0 }) {
                                    TripSparkline(title: "Altitude", unit: "m", values: samples.map { $0.alt },
                                                  color: DS.green, progress: prog, signed: false, fmt: f0)
                                }
                                HStack(spacing: 12) {
                                    Button { togglePlay() } label: {
                                        Image(systemName: playing ? "pause.fill" : "play.fill")
                                            .font(.system(size: 15, weight: .bold)).foregroundStyle(.black)
                                            .frame(width: 38, height: 38).background(DS.green).clipShape(Circle())
                                    }.buttonStyle(.plain)
                                    Slider(value: $idx, in: 0...Double(samples.count - 1), step: 1).tint(DS.green)
                                    Button { speed = speed == 1 ? 2 : (speed == 2 ? 4 : 1) } label: {
                                        Text("\(speed)×").font(.system(size: 14, weight: .bold)).foregroundStyle(DS.green)
                                            .frame(width: 40, height: 38).background(DS.panel2).clipShape(RoundedRectangle(cornerRadius: 10))
                                    }.buttonStyle(.plain)
                                }
                                HStack {
                                    Text("Início").font(.caption2).foregroundStyle(DS.muted)
                                    Spacer()
                                    Text(tStr(cur?.t ?? 0)).font(.caption.weight(.bold)).foregroundStyle(DS.green)
                                    Spacer()
                                    Text(tStr(samples.last?.t ?? 0)).font(.caption2).foregroundStyle(DS.muted)
                                }
                            }
                        }.padding(.horizontal, 12).padding(.bottom, 8)
                        drivingStatsCard.padding(.horizontal, 12).padding(.bottom, 10)
                    }
                }
            }
            .navigationTitle("Trajeto").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Concluído") { dismiss() } }
                if gpxURL != nil || cardURL != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            if let c = cardURL { ShareLink(item: c, preview: SharePreview("Viagem", image: Image(systemName: "map"))) { Label("Cartão (imagem)", systemImage: "photo") } }
                            if let g = gpxURL { ShareLink(item: g) { Label("Trajeto (GPX)", systemImage: "point.topleft.down.curvedto.point.bottomright.up") } }
                        } label: { Image(systemName: "square.and.arrow.up") }
                    }
                }
            }
        }
        .task { await load() }
        .onReceive(playTimer) { _ in
            guard playing, samples.count > 1 else { return }
            // Trajeto inteiro reproduz em ~replaySeconds/velocidade; tick de 0.05s.
            let step = Double(samples.count - 1) / replaySeconds * Double(speed) * 0.05
            let next = idx + step
            if next >= Double(samples.count - 1) { idx = Double(samples.count - 1); playing = false }
            else { idx = next }
        }
    }

    private func togglePlay() {
        if !playing, idx >= Double(samples.count - 1) { idx = 0 }   // reinicia se no fim
        playing.toggle()
    }

    // Cartão compartilhável: mapa do trajeto INTEIRO (mapRect = limites da rota +
    // margem) na área acima da barra de stats, então a rota nunca fica cortada
    // nem coberta. Mostra km, kWh, condução e velocidade média/máx.
    private func makeTripCard() {
        guard coords.count > 1 else { return }
        var rect = MKMapRect.null
        for c in coords { let p = MKMapPoint(c); rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0)) }
        guard rect.size.width > 0 || rect.size.height > 0 else { return }

        let size = CGSize(width: 1080, height: 1350)
        let barH: CGFloat = 290
        let mapH = size.height - barH

        let opts = MKMapSnapshotter.Options()
        // Margem generosa pra rota não encostar nas bordas (zoom afastado o bastante).
        let padX = max(rect.size.width, 1) * 0.16, padY = max(rect.size.height, 1) * 0.16
        opts.mapRect = MKMapRect(x: rect.minX - padX, y: rect.minY - padY,
                                 width: rect.size.width + 2 * padX, height: rect.size.height + 2 * padY)
        opts.size = CGSize(width: size.width, height: mapH)   // só a área do mapa (acima da barra)
        opts.traitCollection = UITraitCollection(userInterfaceStyle: .dark)

        let date = self.trip.date, distKm = self.trip.distKm, netKwh = self.trip.netKwh
        let score = Eco.score(self.trip), title = cardTitle(), d = Self.computeDriving(samples)
        MKMapSnapshotter(options: opts).start(with: DispatchQueue.global(qos: .userInitiated)) { snapshot, _ in
            guard let snapshot else { return }
            let img = UIGraphicsImageRenderer(size: size).image { _ in
                UIColor.black.setFill(); UIRectFill(CGRect(origin: .zero, size: size))
                snapshot.image.draw(at: .zero)   // mapa ocupa o topo (0..mapH)
                let path = UIBezierPath()
                for (i, c) in coords.enumerated() {
                    let pt = snapshot.point(for: c)   // coords mapeadas dentro do snapshot (0..mapH)
                    if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                }
                UIColor(red: 0.13, green: 0.83, blue: 0.93, alpha: 1).setStroke()
                path.lineWidth = 9; path.lineJoinStyle = .round; path.lineCapStyle = .round; path.stroke()
                // Barra inferior + textos
                UIColor(white: 0.04, alpha: 1).setFill(); UIRectFill(CGRect(x: 0, y: mapH, width: size.width, height: barH))
                func draw(_ s: String, _ y: CGFloat, _ sz: CGFloat, _ color: UIColor, _ weight: UIFont.Weight) {
                    let a: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: sz, weight: weight), .foregroundColor: color]
                    NSAttributedString(string: s, attributes: a).draw(at: CGPoint(x: 44, y: y))
                }
                let df = DateFormatter(); df.locale = Locale(identifier: "pt_BR"); df.dateFormat = "d 'de' MMM yyyy · HH:mm"
                let teal = UIColor(red: 0.13, green: 0.83, blue: 0.93, alpha: 1)
                draw("🚗 " + title, mapH + 22, 42, .white, .bold)
                draw(df.string(from: date), mapH + 82, 28, UIColor(white: 0.65, alpha: 1), .regular)
                var l1 = "\(Fmt.km(distKm)) km · \(Fmt.dec1(netKwh)) kWh"
                if let sc = score { l1 += " · condução \(sc)" }
                draw(l1, mapH + 132, 38, teal, .semibold)
                draw("⌀ \(Int(d.avg.rounded())) km/h · máx \(Int(d.max.rounded())) km/h", mapH + 188, 34, UIColor(white: 0.85, alpha: 1), .regular)
                draw("Haval Hub", mapH + barH - 50, 24, UIColor(white: 0.45, alpha: 1), .medium)
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("haval-cartao-\(self.trip.tripId).png")
            try? img.pngData()?.write(to: url)
            DispatchQueue.main.async { self.cardURL = url }
        }
    }

    private func cardTitle() -> String {
        if let n = trip.rawName { return n }
        if let a = trip.knownStart, let b = trip.knownEnd { return "\(a) → \(b)" }
        return trip.knownEnd ?? "Viagem"
    }

    private func buildGPX() {
        let pts = samples.filter { $0.coord != nil }
        guard pts.count > 1 else { return }
        let iso = ISO8601DateFormatter()
        var s = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<gpx version=\"1.1\" creator=\"Haval Hub\" xmlns=\"http://www.topografix.com/GPX/1/1\">\n<trk><name>Haval \(trip.tripId)</name><trkseg>\n"
        for sm in pts {
            guard let c = sm.coord else { continue }
            let t = iso.string(from: trip.date.addingTimeInterval(sm.t))
            s += "<trkpt lat=\"\(c.latitude)\" lon=\"\(c.longitude)\"><time>\(t)</time></trkpt>\n"
        }
        s += "</trkseg></trk></gpx>"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("haval-trajeto-\(trip.tripId).gpx")
        try? s.data(using: .utf8)?.write(to: url)
        gpxURL = url
    }

    // Estatísticas de condução a partir dos samples (velocidade/potência/tempo).
    // nonisolated static: roda off-main no parse do trajeto.
    nonisolated static func computeDriving(_ samples: [TripSample]) -> (avg: Double, max: Double, pwr: Double, regenPct: Double, regenKwh: Double) {
        let spds = samples.map { $0.spd }
        let maxSpd = spds.max() ?? 0
        let moving = spds.filter { $0 > 3 }
        let avgSpd = moving.isEmpty ? 0 : moving.reduce(0, +) / Double(moving.count)
        let maxPwr = samples.map { $0.pwr }.max() ?? 0
        let regenPct = samples.isEmpty ? 0 : Double(samples.filter { $0.pwr < -0.5 }.count) / Double(samples.count) * 100
        var regenKwh = 0.0
        if samples.count > 1 {
            for i in 1..<samples.count {
                let dt = samples[i].t - samples[i-1].t
                if dt > 0 && dt < 30 && samples[i].pwr < 0 { regenKwh += -samples[i].pwr * dt / 3600 }
            }
        }
        // avg/max só vão pra display (card de stats + cartão compartilhável) → corrige
        // pro velocímetro. pwr/regen seguem crus (não são velocidade).
        return (Double(Fmt.adjSpeed(avgSpd)), Double(Fmt.adjSpeed(maxSpd)), maxPwr, regenPct, regenKwh)
    }

    @ViewBuilder private var drivingStatsCard: some View {
        let d = driving
        DSCard(glass: true) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Condução").font(.caption).foregroundStyle(DS.muted)
                HStack(spacing: 12) {
                    DSMetric(value: f0(d.avg), unit: "km/h", label: "Vel. média", color: DS.text, compact: true)
                    DSMetric(value: f0(d.max), unit: "km/h", label: "Vel. máx", color: DS.text, compact: true)
                    DSMetric(value: f1(d.pwr), unit: "kW", label: "Pico potência", color: DS.blue, compact: true)
                }
                HStack(spacing: 12) {
                    DSMetric(value: f0(d.regenPct), unit: "%", label: "Em regeneração", color: DS.green, compact: true)
                    DSMetric(value: f1(d.regenKwh), unit: "kWh", label: "Recuperado", color: DS.green, compact: true)
                    DSMetric(value: "\(samples.count)", unit: "", label: "Amostras", color: DS.muted, compact: true)
                }
            }
        }
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
        guard let data else { return }
        // Parse + integração (kWh/km acumulado) + decimação rodam OFF-MAIN: o JSON
        // pode ter milhares de samples (~23MB) e travava a UI ao abrir o trajeto.
        guard let parsed = await Task.detached(priority: .userInitiated, operation: {
            () -> (coords: [CLLocationCoordinate2D], samples: [TripSample],
                   driving: (avg: Double, max: Double, pwr: Double, regenPct: Double, regenKwh: Double))? in
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let raw = obj["samples"] as? [[String: Any]] else { return nil }
            let coords: [CLLocationCoordinate2D] = raw.compactMap { s in
                let la = anyNum2(s["lat"]), lo = anyNum2(s["lng"])
                return (la != 0 && lo != 0) ? CLLocationCoordinate2D(latitude: la, longitude: lo) : nil
            }
            // kWh acumulado: integra evKw × dt (igual ao PWA — positivo=consumo).
            // Guard de gap <30s: salto grande = carro desligado entre trechos (resume),
            // sem energia fluindo no buraco — evita o acumulado "cair e recomeçar".
            var cum = 0.0, cumKm = 0.0, lastT = 0.0, first = true
            var out: [TripSample] = []
            for s in raw {
                let t = anyNum2(s["t"]), kw = anyNum2(s["evKw"]), spd = anyNum2(s["spd"])
                if !first { let rawDt = t - lastT; let dt = (rawDt > 0 && rawDt < 30) ? rawDt : 0; cum += kw * dt / 3600.0; cumKm += spd * dt / 3600.0 }
                first = false; lastT = t
                let la = anyNum2(s["lat"]), lo = anyNum2(s["lng"])
                out.append(TripSample(t: t, coord: (la != 0 && lo != 0) ? .init(latitude: la, longitude: lo) : nil,
                                      spd: spd, rpm: anyNum2(s["rpm"]), pwr: kw, soc: anyNum2(s["soc"]),
                                      alt: anyNum2(s["altM"]), cumKwh: cum, cumKm: cumKm))
            }
            if out.count > 600 { let step = out.count / 600 + 1; out = out.enumerated().filter { $0.offset % step == 0 }.map { $0.element } }
            return (coords, out, RouteMapSheet.computeDriving(out))
        }).value else { return }

        coords = parsed.coords
        samples = parsed.samples
        driving = parsed.driving
        buildGPX()
        makeTripCard()
        if let first = coords.first {
            cam = .region(MKCoordinateRegion(center: first, span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)))
        }
    }
}
