//
//  ViagensV2View.swift
//  Viagens v2 — hero km + card expandido (5a), sheet trajeto com player (5b),
//  Insights drill-down (5c). design-v2/README.md §3. V1 intacta; troca via ui_v2.
//

import SwiftUI
import MapKit
import CoreLocation

// MARK: - helpers compartilhados 5a/5b

enum TrajV2 {
    /// Baixa (ou lê do cache) e parseia o trajeto. Mesma lógica do RouteMapSheet.load.
    static func load(_ trip: Trip) async -> (coords: [CLLocationCoordinate2D], samples: [TripSample])? {
        let u = BridgeRouter.shared.currentURL
        let base = u.hasSuffix("/") ? String(u.dropLast()) : u
        var data: Data?
        if let url = URL(string: "\(base)/api/telemetry/\(trip.tripId)") {
            var req = URLRequest(url: url); req.timeoutInterval = 15
            req.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
            if let (d, resp) = try? await URLSession.shared.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200 {
                data = d
                OfflineCache.saveTraj(trip.tripId, d)
            }
        }
        if data == nil { data = OfflineCache.loadTraj(trip.tripId) }
        guard let data else { return nil }
        return await Task.detached(priority: .userInitiated) {
            () -> (coords: [CLLocationCoordinate2D], samples: [TripSample])? in
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let raw = obj["samples"] as? [[String: Any]] else { return nil }
            func num(_ v: Any?) -> Double {
                switch v {
                case let d as Double: return d
                case let i as Int: return Double(i)
                case let n as NSNumber: return n.doubleValue
                case let s as String: return Double(s) ?? 0
                default: return 0
                }
            }
            var cum = 0.0, cumKm = 0.0, lastT = 0.0, first = true
            var out: [TripSample] = []
            var coords: [CLLocationCoordinate2D] = []
            for s in raw {
                let t = num(s["t"])
                let kw = s["evKw"] != nil ? num(s["evKw"]) : num(s["pwr"])
                let spd = num(s["spd"])
                if !first { let dt0 = t - lastT; let dt = (dt0 > 0 && dt0 < 30) ? dt0 : 0; cum += kw * dt / 3600; cumKm += spd * dt / 3600 }
                first = false; lastT = t
                let la = num(s["lat"]), lo = num(s["lng"])
                let c: CLLocationCoordinate2D? = (la != 0 && lo != 0) ? .init(latitude: la, longitude: lo) : nil
                if let c { coords.append(c) }
                out.append(TripSample(t: t, coord: c, spd: spd, rpm: num(s["rpm"]), pwr: kw,
                                      soc: num(s["soc"]), alt: num(s["altM"]), cumKwh: cum, cumKm: cumKm))
            }
            if out.count > 600 { let step = out.count / 600 + 1; out = out.enumerated().filter { $0.offset % step == 0 }.map { $0.element } }
            return (coords, out)
        }.value
    }

    /// Classe de velocidade pra polyline colorida: 0 lento / 1 fluindo / 2 rápido.
    static func speedClass(_ kmh: Double) -> Int { kmh < 15 ? 0 : (kmh < 60 ? 1 : 2) }
    static let classColors: [Color] = [DS.teal, DS.green, DS.orange]
    static let classNames = ["lento", "fluindo", "rápido"]

    /// Segmenta os samples com GPS em runs contíguos da mesma classe de velocidade.
    static func segments(_ samples: [TripSample]) -> [(cls: Int, coords: [CLLocationCoordinate2D])] {
        let pts = samples.filter { $0.coord != nil }
        guard pts.count > 1 else { return [] }
        var segs: [(Int, [CLLocationCoordinate2D])] = []
        var cur: [CLLocationCoordinate2D] = [pts[0].coord!]
        var curCls = speedClass(pts[0].spd)
        for p in pts.dropFirst() {
            let cls = speedClass(p.spd)
            cur.append(p.coord!)
            if cls != curCls {
                segs.append((curCls, cur))
                cur = [p.coord!]
                curCls = cls
            }
        }
        segs.append((curCls, cur))
        return segs.filter { $0.1.count > 1 }
    }

    static func region(_ coords: [CLLocationCoordinate2D], pad: Double = 1.35) -> MKCoordinateRegion? {
        guard let f = coords.first else { return nil }
        var minLa = f.latitude, maxLa = f.latitude, minLo = f.longitude, maxLo = f.longitude
        for c in coords {
            minLa = min(minLa, c.latitude); maxLa = max(maxLa, c.latitude)
            minLo = min(minLo, c.longitude); maxLo = max(maxLo, c.longitude)
        }
        return MKCoordinateRegion(
            center: .init(latitude: (minLa + maxLa) / 2, longitude: (minLo + maxLo) / 2),
            span: .init(latitudeDelta: max(0.004, (maxLa - minLa) * pad),
                        longitudeDelta: max(0.004, (maxLo - minLo) * pad)))
    }

    static func rect(_ coords: [CLLocationCoordinate2D], pad: Double = 0.18) -> MKMapRect? {
        var r = MKMapRect.null
        for c in coords { let p = MKMapPoint(c); r = r.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0)) }
        guard r.size.width > 0 || r.size.height > 0 else { return nil }
        let px = max(r.size.width, 1) * pad, py = max(r.size.height, 1) * pad
        return MKMapRect(x: r.minX - px, y: r.minY - py, width: r.size.width + 2 * px, height: r.size.height + 2 * py)
    }

    /// Prévia estática do trajeto (5a): snapshot dark + polyline colorida por velocidade.
    static func preview(_ samples: [TripSample], size: CGSize) async -> UIImage? {
        let pts = samples.filter { $0.coord != nil }
        guard pts.count > 1, let rect = rect(pts.map { $0.coord! }) else { return nil }
        let opts = MKMapSnapshotter.Options()
        opts.mapRect = rect
        opts.size = size
        opts.traitCollection = UITraitCollection(userInterfaceStyle: .dark)
        opts.pointOfInterestFilter = .excludingAll
        guard let snap = try? await MKMapSnapshotter(options: opts).start() else { return nil }
        return UIGraphicsImageRenderer(size: size).image { _ in
            snap.image.draw(at: .zero)
            for seg in segments(samples) {
                let path = UIBezierPath()
                for (i, c) in seg.coords.enumerated() {
                    let p = snap.point(for: c)
                    if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                UIColor(classColors[seg.cls]).setStroke()
                path.lineWidth = 3; path.lineJoinStyle = .round; path.lineCapStyle = .round; path.stroke()
            }
        }
    }

    static func gpx(_ trip: Trip, _ samples: [TripSample]) -> URL? {
        let pts = samples.filter { $0.coord != nil }
        guard pts.count > 1 else { return nil }
        let iso = ISO8601DateFormatter()
        var s = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<gpx version=\"1.1\" creator=\"Haval Hub\" xmlns=\"http://www.topografix.com/GPX/1/1\">\n<trk><name>Haval \(trip.tripId)</name><trkseg>\n"
        for sm in pts {
            guard let c = sm.coord else { continue }
            s += "<trkpt lat=\"\(c.latitude)\" lon=\"\(c.longitude)\"><time>\(iso.string(from: trip.date.addingTimeInterval(sm.t)))</time></trkpt>\n"
        }
        s += "</trkseg></trk></gpx>"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("haval-trajeto-\(trip.tripId).gpx")
        try? s.data(using: .utf8)?.write(to: url)
        return url
    }

    static func shareURL(_ trip: Trip) async -> URL? {
        let base = BridgeRouter.shared.currentURL
        guard let url = URL(string: "\(base)/api/autotrips/\(trip.tripId)/share") else { return nil }
        var req = URLRequest(url: url); req.httpMethod = "POST"; req.timeoutInterval = 8
        req.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = j["token"] as? String else { return nil }
        return URL(string: "https://mac-mini.tailacc6e7.ts.net/t/\(token)")
    }

    /// Cartão compartilhável (mesmo layout do v1, polyline colorida por velocidade).
    static func card(_ trip: Trip, _ coords: [CLLocationCoordinate2D], _ samples: [TripSample], title: String) async -> URL? {
        guard coords.count > 1 else { return nil }
        var rect = MKMapRect.null
        for c in coords { let p = MKMapPoint(c); rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0)) }
        guard rect.size.width > 0 || rect.size.height > 0 else { return nil }
        let size = CGSize(width: 1080, height: 1350)
        let barH: CGFloat = 290, mapH = size.height - barH
        let opts = MKMapSnapshotter.Options()
        let padX = max(rect.size.width, 1) * 0.16, padY = max(rect.size.height, 1) * 0.16
        opts.mapRect = MKMapRect(x: rect.minX - padX, y: rect.minY - padY,
                                 width: rect.size.width + 2 * padX, height: rect.size.height + 2 * padY)
        opts.size = CGSize(width: size.width, height: mapH)
        opts.traitCollection = UITraitCollection(userInterfaceStyle: .dark)
        guard let snapshot = try? await MKMapSnapshotter(options: opts).start() else { return nil }
        let d = RouteMapSheet.computeDriving(samples)
        let date = trip.date, distKm = trip.distKm, netKwh = trip.netKwh, score = Eco.score(trip)
        let img = UIGraphicsImageRenderer(size: size).image { _ in
            UIColor.black.setFill(); UIRectFill(CGRect(origin: .zero, size: size))
            snapshot.image.draw(at: .zero)
            let path = UIBezierPath()
            for (i, c) in coords.enumerated() {
                let pt = snapshot.point(for: c)
                if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
            UIColor(red: 0.13, green: 0.77, blue: 0.37, alpha: 1).setStroke()
            path.lineWidth = 9; path.lineJoinStyle = .round; path.lineCapStyle = .round; path.stroke()
            UIColor(white: 0.04, alpha: 1).setFill(); UIRectFill(CGRect(x: 0, y: mapH, width: size.width, height: barH))
            func draw(_ s: String, _ y: CGFloat, _ sz: CGFloat, _ color: UIColor, _ weight: UIFont.Weight) {
                NSAttributedString(string: s, attributes: [.font: UIFont.systemFont(ofSize: sz, weight: weight), .foregroundColor: color])
                    .draw(at: CGPoint(x: 44, y: y))
            }
            let df = DateFormatter(); df.locale = Locale(identifier: "pt_BR"); df.dateFormat = "d 'de' MMM yyyy · HH:mm"
            let green = UIColor(red: 0.13, green: 0.77, blue: 0.37, alpha: 1)
            draw("🚗 " + title, mapH + 22, 42, .white, .bold)
            draw(df.string(from: date), mapH + 82, 28, UIColor(white: 0.65, alpha: 1), .regular)
            var l1 = "\(Fmt.km(distKm)) km · \(Fmt.dec1(netKwh)) kWh"
            if let sc = score { l1 += " · condução \(sc)" }
            draw(l1, mapH + 132, 38, green, .semibold)
            draw("⌀ \(Int(d.avg.rounded())) km/h · máx \(Int(d.max.rounded())) km/h", mapH + 188, 34, UIColor(white: 0.85, alpha: 1), .regular)
            draw("Haval Hub", mapH + barH - 50, 24, UIColor(white: 0.45, alpha: 1), .medium)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("haval-cartao-\(trip.tripId).png")
        try? img.pngData()?.write(to: url)
        return url
    }
}

// MARK: - 5a · aba Viagens

struct ViagensV2View: View {
    @ObservedObject private var loader = TripsLoader.shared
    @ObservedObject private var car = CarStore.shared
    @AppStorage("via2_kind") private var kind = 2          // 0 hoje · 1 7d · 2 30d · 3 mês · 4 personalizado
    @AppStorage("via2_month") private var monthOffset = 0
    @AppStorage("via2_from") private var fromTS: Double = 0
    @AppStorage("via2_to") private var toTS: Double = 0
    @State private var showSearch = false
    @State private var showInsights = false
    @State private var search = ""
    @State private var showAll = false
    @State private var routeTrip: Trip?
    // Viagem cujo TRECHO (origem→destino) está sendo comparado com o histórico.
    @State private var compareTrip: Trip?
    // Trajeto por viagem (vel. máx + mini-mapa + share/GPX) — carrega async ao expandir.
    @State private var featCache: [String: FeatData] = [:]
    @State private var loadingIds: Set<String> = []
    @State private var renamingTrip: Trip?
    @State private var renameText = ""
    // Persistência do estado aberto/fechado (overrides sobre o default "só a mais
    // recente aberta"). CSV de Trip.id porque @AppStorage não guarda Set.
    @AppStorage("via2_expandedIds") private var expandedCSV = ""
    @AppStorage("via2_collapsedIds") private var collapsedCSV = ""

    private func parseIds(_ csv: String) -> Set<Double> { Set(csv.split(separator: ",").compactMap { Double($0) }) }
    private func serializeIds(_ s: Set<Double>) -> String { s.map { String($0) }.joined(separator: ",") }

    private var newestId: Double? { search.isEmpty ? filtered.first?.id : nil }

    private func isExpanded(_ t: Trip) -> Bool {
        if parseIds(collapsedCSV).contains(t.id) { return false }
        if t.id == newestId { return true }
        return parseIds(expandedCSV).contains(t.id)
    }

    private func toggle(_ t: Trip) {
        var exp = parseIds(expandedCSV), col = parseIds(collapsedCSV)
        if isExpanded(t) { exp.remove(t.id); col.insert(t.id) }
        else { col.remove(t.id); exp.insert(t.id) }
        expandedCSV = serializeIds(exp); collapsedCSV = serializeIds(col)
        if isExpanded(t) { ensureLoaded(t) }
    }

    private func ensureLoaded(_ t: Trip) {
        let id = t.tripId
        if featCache[id] != nil || loadingIds.contains(id) { return }
        loadingIds.insert(id)
        Task {
            guard let r = await TrajV2.load(t) else { loadingIds.remove(id); return }
            var d = FeatData()
            d.coords = r.coords; d.samples = r.samples
            d.gpx = TrajV2.gpx(t, r.samples)
            d.preview = await TrajV2.preview(r.samples, size: CGSize(width: 680, height: 152))
            d.card = await TrajV2.card(t, r.coords, r.samples, title: loader.displayName(t))
            featCache[id] = d
            loadingIds.remove(id)
        }
    }

    // remove ids órfãos (viagens que sumiram) dos overrides pra não crescer sem fim.
    private func pruneOverrides() {
        let valid = Set(loader.trips.map { $0.id })
        expandedCSV = serializeIds(parseIds(expandedCSV).intersection(valid))
        collapsedCSV = serializeIds(parseIds(collapsedCSV).intersection(valid))
    }

    private var fromDate: Binding<Date> { Binding(get: { fromTS > 0 ? Date(timeIntervalSince1970: fromTS) : Date() }, set: { fromTS = $0.timeIntervalSince1970 }) }
    private var toDate: Binding<Date> { Binding(get: { toTS > 0 ? Date(timeIntervalSince1970: toTS) : Date() }, set: { toTS = $0.timeIntervalSince1970 }) }

    private var filtered: [Trip] {
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { return loader.trips.filter { loader.displayName($0).localizedCaseInsensitiveContains(q) } }
        return loader.trips.filter { PeriodUtil.contains(kind: kind, monthOffset: monthOffset, from: fromDate.wrappedValue, to: toDate.wrappedValue, $0.date) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    headerRow
                    hero
                    PeriodFilterBar(kind: $kind, monthOffset: $monthOffset, earliest: loader.trips.last?.date)
                    if kind == 4 && search.isEmpty { PeriodCalendarCard(from: fromDate, to: toDate) }
                    if showSearch { searchBar }
                    if filtered.isEmpty {
                        Text("Nenhuma viagem no período.")
                            .font(.system(size: 13)).foregroundStyle(DS.muted).padding(.top, 12)
                    } else {
                        rows
                    }
                }
                .padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Viagens")
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showInsights) { InsightsV2View() }
            .refreshable { await loader.load() }
            .task {
                await loader.load()
                pruneOverrides()
                if let t = filtered.first, search.isEmpty { ensureLoaded(t) }
                #if DEBUG
                let d = UserDefaults.standard
                if d.integer(forKey: "v2_traj") == 1, let t = filtered.first {
                    try? await Task.sleep(for: .seconds(0.6)); routeTrip = t
                } else if d.integer(forKey: "v2_insights") == 1 {
                    try? await Task.sleep(for: .seconds(0.6)); showInsights = true
                } else if d.integer(forKey: "v2_compare") > 0 {
                    // Abre o comparativo de trecho da N-ésima viagem filtrada
                    // (1 = a mais recente). Atalho de teste sem depender de toque.
                    let idx = d.integer(forKey: "v2_compare") - 1
                    if filtered.indices.contains(idx) {
                        try? await Task.sleep(for: .seconds(0.8)); compareTrip = filtered[idx]
                    }
                }
                #endif
            }
            .sheet(item: $routeTrip) { t in TrajetoV2Sheet(trip: t) }
            .sheet(item: $compareTrip) { t in
                RouteCompareSheet(trips: filtered, priceKwh: car.priceKwh, priceGas: car.priceGas,
                                  kmPerLGas: car.kmPerL, focusTrip: t)
            }
            .alert("Renomear viagem", isPresented: Binding(get: { renamingTrip != nil }, set: { if !$0 { renamingTrip = nil } })) {
                TextField("Nome", text: $renameText)
                Button("Salvar") {
                    if let t = renamingTrip {
                        let name = renameText.trimmingCharacters(in: .whitespaces)
                        if !name.isEmpty { Task { await loader.rename(t.tripId, name) } }
                    }
                    renamingTrip = nil
                }
                Button("Cancelar", role: .cancel) { renamingTrip = nil }
            }
            .onChange(of: filtered.first?.tripId) { if let t = filtered.first, search.isEmpty { ensureLoaded(t) } }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            Text("Viagens").font(.system(size: 24, weight: .bold)).foregroundStyle(DS.text)
            Spacer()
            headerButton("magnifyingglass") { withAnimation(.easeInOut(duration: 0.15)) { showSearch.toggle(); if !showSearch { search = "" } } }
            headerButton("chart.bar.xaxis") { showInsights = true }
        }
    }

    private func headerButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.text)
                .frame(width: 36, height: 36)
                .background(DS.panel2, in: Circle())
        }.buttonStyle(.plain)
    }

    private var hero: some View {
        let f = filtered
        let km = f.reduce(0.0) { $0 + $1.distKm }
        let kwh = f.reduce(0.0) { $0 + max($1.netKwh, 0) }
        let cost = f.reduce(0.0) { $0 + $1.cost(car.priceKwh, car.priceGas) }
        let evKm = f.filter { $0.fuelL < 0.05 }.reduce(0.0) { $0 + $1.distKm }
        let evPct = km > 0 ? Int((evKm / km * 100).rounded()) : 0
        return HStack(alignment: .firstTextBaseline) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(Fmt.int(km))
                    .font(.system(size: 62, weight: .ultraLight)).tracking(-2)
                    .monospacedDigit().foregroundStyle(DS.text)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text("km").font(.system(size: 15)).foregroundStyle(DS.muted)
            }
            Spacer(minLength: 10)
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(f.count) viagens · \(evPct)% em EV")
                    .font(.system(size: 12.5, weight: .bold)).foregroundStyle(DS.green)
                Text("\(Fmt.dec1(kwh)) kWh · \(Fmt.brl(cost))")
                    .font(.system(size: 11.5)).foregroundStyle(DS.text2)
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
        .background(DS.panel2, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: card unificado (colapsável, um estilo pra todas)

    struct FeatData {
        var coords: [CLLocationCoordinate2D] = []
        var samples: [TripSample] = []
        var gpx: URL?
        var preview: UIImage?
        var card: URL?
    }

    private func dayLabel(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "hoje" }
        if cal.isDateInYesterday(d) { return "ontem" }
        let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = d > Date().addingTimeInterval(-6 * 86400) ? "EEE" : "d MMM"
        return f.string(from: d).replacingOccurrences(of: ".", with: "")
    }

    private static let hm: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()

    private func tripCard(_ t: Trip, expanded: Bool) -> some View {
        let d = featCache[t.tripId]
        let cost = t.cost(car.priceKwh, car.priceGas)
        let maxSpd = (d?.samples.isEmpty ?? true) ? nil : Fmt.adjSpeed(d!.samples.map { $0.spd }.max() ?? 0)
        var sub = "\(dayLabel(t.date)) · \(Self.hm.string(from: t.date)) – \(Self.hm.string(from: t.date.addingTimeInterval(t.timeSec)))"
        if let temp = t.outsideTemp { sub += " · \(Fmt.int(temp))° externa" }
        return VStack(alignment: .leading, spacing: expanded ? 12 : 0) {
            Button { toggle(t) } label: {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(loader.displayName(t))
                            .font(.system(size: 15, weight: .bold)).foregroundStyle(DS.text).lineLimit(1)
                        Text(sub).font(.system(size: 11.5)).foregroundStyle(DS.text2).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    Spacer(minLength: 8)
                    if let s = Eco.score(t) { scoreChip(s) }
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DS.muted).rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            if expanded {
                HStack(spacing: 8) {
                    featTile("DISTÂNCIA", Fmt.km(t.distKm), "km", DS.text)
                    featTile("CONSUMO", t.consumo > 0 ? Fmt.dec1(t.consumo) : "—", "", DS.teal)
                    featTile("VEL. MÁX", maxSpd.map { "\($0)" } ?? "—", "", DS.text)
                    featTile("CUSTO", cost > 0 ? Fmt.brl(cost) : "—", "", DS.text)
                }
                let custoKm = (cost > 0 && t.distKm > 0.5) ? cost / t.distKm : 0
                HStack(spacing: 8) {
                    featTile("CUSTO/KM", custoKm > 0 ? Fmt.brl(custoKm) : "—", "", DS.text)
                    // EV puro: km/L equivalente não é intuitivo (e kWh/100km já está em
                    // CONSUMO) → mostra energia gasta. Híbrida/gasolina: km/L equivalente.
                    if t.fuelL < 0.05 {
                        featTile("ENERGIA", Fmt.dec1(t.netKwh), "kWh", DS.teal)
                    } else {
                        featTile("KM/L EQUIV.", t.kmPerLEq > 0 ? Fmt.dec1(t.kmPerLEq) : "—", "km/L", DS.green)
                    }
                }
                if t.fuelL >= 0.05 {
                    HStack(spacing: 8) {
                        featTile("ENERGIA", Fmt.dec1(t.netKwh), "kWh", DS.teal)
                        featTile("GASOLINA", Fmt.dec1(t.fuelL), "L", DS.orange)
                    }
                }
                if let img = d?.preview {
                    Image(uiImage: img)
                        .resizable().scaledToFill()
                        .frame(height: 76)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                // 4 ações não cabem em texto na largura do iPhone (quebrava
                // "Comparar" em duas linhas) → compartilhar vira ícone.
                HStack(spacing: 14) {
                    Button { routeTrip = t } label: {
                        Text("Trajeto →").font(.system(size: 13, weight: .bold)).foregroundStyle(DS.green)
                    }.buttonStyle(.plain).fixedSize()
                    Button { compareTrip = t } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chart.bar.xaxis").font(.system(size: 11, weight: .bold))
                            Text("Comparar").font(.system(size: 13, weight: .bold))
                        }.foregroundStyle(DS.teal)
                    }.buttonStyle(.plain).fixedSize()
                    Spacer(minLength: 4)
                    if let c = d?.card {
                        ShareLink(item: c, preview: SharePreview("Viagem", image: Image(systemName: "map"))) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.text2)
                        }.fixedSize()
                    }
                    if let g = d?.gpx {
                        ShareLink(item: g) {
                            Text("GPX").font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.text2)
                        }.fixedSize()
                    }
                }
            }
        }
        .padding(14)
        .background(DS.panel, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(expanded ? DS.green.opacity(0.28) : DS.border, lineWidth: 1))
        .contextMenu { tripMenu(t) }
        .onAppear { loader.geocodeIfNeeded(t); if expanded { ensureLoaded(t) } }
    }

    @ViewBuilder
    private func tripMenu(_ t: Trip) -> some View {
        Button {
            renameText = loader.displayName(t)
            renamingTrip = t
        } label: { Label("Renomear", systemImage: "pencil") }
        Button(role: .destructive) {
            Task { await loader.remove(t.tripId) }
        } label: { Label("Excluir", systemImage: "trash") }
    }

    private func featTile(_ label: String, _ value: String, _ unit: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 8.5, weight: .bold)).foregroundStyle(DS.muted).tracking(0.8)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.system(size: 15, weight: .bold)).monospacedDigit().foregroundStyle(tint)
                    .lineLimit(1).minimumScaleFactor(0.7)
                if !unit.isEmpty { Text(unit).font(.system(size: 9)).foregroundStyle(DS.muted) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9).padding(.vertical, 8)
        .background(DS.panel2, in: RoundedRectangle(cornerRadius: 10))
    }

    private func scoreChip(_ s: Int) -> some View {
        Text("\(s)")
            .font(.system(size: 13, weight: .bold)).monospacedDigit()
            .foregroundStyle(s >= 80 ? DS.green : DS.yellow)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background((s >= 80 ? DS.green : DS.yellow).opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke((s >= 80 ? DS.green : DS.yellow).opacity(0.35), lineWidth: 1))
    }

    // MARK: lista (todas com o mesmo card, colapsáveis)

    private var rows: some View {
        let all = filtered
        let visible = showAll ? all : Array(all.prefix(6))
        return VStack(spacing: 8) {
            ForEach(visible) { t in
                tripCard(t, expanded: isExpanded(t))
                    .animation(.easeInOut(duration: 0.18), value: isExpanded(t))
            }
            if !showAll && all.count > visible.count {
                Button { withAnimation { showAll = true } } label: {
                    Text("Ver todas as \(all.count) viagens ›")
                        .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(DS.text2)
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                }.buttonStyle(.plain)
            }
        }
    }
}

// MARK: - 5b · sheet Ver trajeto (player)

struct TrajetoV2Sheet: View {
    let trip: Trip
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var loader = TripsLoader.shared
    @State private var coords: [CLLocationCoordinate2D] = []
    @State private var samples: [TripSample] = []
    @State private var loading = true
    @State private var idx: Double = 0
    @State private var playing = false
    @State private var speed = 1
    @State private var cam: MapCameraPosition = .automatic
    @State private var cardURL: URL?
    @State private var gpxURL: URL?
    @State private var webURL: URL?
    @State private var creatingWeb = false
    private let replaySeconds = 20.0
    private let playTimer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    private var cur: TripSample? { samples.isEmpty ? nil : samples[min(samples.count - 1, max(0, Int(idx)))] }
    private var prog: Double { samples.count > 1 ? Double(min(samples.count - 1, max(0, Int(idx)))) / Double(samples.count - 1) : 0 }
    private static let hm: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            mapView
            if samples.count > 1 {
                metricsGrid
                player
                speedGraph
                powerGraph
                if hasIce { rpmGraph }
                shareRow
            } else if loading {
                ProgressView().tint(DS.green).frame(maxWidth: .infinity).padding(.vertical, 40)
            } else {
                Text("Trajeto indisponível.").font(.system(size: 13)).foregroundStyle(DS.muted)
                    .frame(maxWidth: .infinity).padding(.vertical, 40)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 10)
        .background(DS.bg.ignoresSafeArea())
        .presentationDragIndicator(.visible)
        // Map dentro de sheet ignora .environment(\.colorScheme) — força no sheet todo.
        .preferredColorScheme(.dark)
        .task { await load() }
        .onReceive(playTimer) { _ in
            guard playing, samples.count > 1 else { return }
            let step = Double(samples.count - 1) / replaySeconds * Double(speed) * 0.05
            let next = idx + step
            if next >= Double(samples.count - 1) { idx = Double(samples.count - 1); playing = false }
            else { idx = next }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(loader.displayName(trip))
                    .font(.system(size: 17, weight: .bold)).foregroundStyle(DS.text).lineLimit(1)
                Text("\(Self.hm.string(from: trip.date)) – \(Self.hm.string(from: trip.date.addingTimeInterval(trip.timeSec))) · \(Fmt.km(trip.distKm)) km")
                    .font(.system(size: 11.5)).foregroundStyle(DS.text2)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(DS.text2)
                    .frame(width: 30, height: 30).background(DS.panel2, in: Circle())
            }.buttonStyle(.plain)
        }
    }

    @ViewBuilder private var mapView: some View {
        if coords.count > 1 {
            Map(position: $cam, interactionModes: .all) {
                ForEach(Array(TrajV2.segments(samples).enumerated()), id: \.offset) { _, seg in
                    MapPolyline(coordinates: seg.coords)
                        .stroke(TrajV2.classColors[seg.cls], lineWidth: 4)
                }
                if let c = cur?.coord {
                    Annotation("", coordinate: c) {
                        ZStack {
                            Circle().fill(DS.green.opacity(0.25)).frame(width: 32, height: 32)
                            Circle().fill(DS.green).frame(width: 14, height: 14)
                                .overlay(Circle().stroke(.black.opacity(0.6), lineWidth: 2))
                        }
                    }
                }
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .environment(\.colorScheme, .dark)
            .frame(height: 330)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(alignment: .bottomLeading) { legend.padding(8) }
        } else {
            RoundedRectangle(cornerRadius: 14).fill(DS.panel)
                .frame(height: 330)
                .overlay { if loading { ProgressView().tint(DS.green) } }
        }
    }

    private var legend: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { i in
                HStack(spacing: 4) {
                    Capsule().fill(TrajV2.classColors[i]).frame(width: 10, height: 3)
                    Text(TrajV2.classNames[i]).font(.system(size: 9, weight: .semibold)).foregroundStyle(DS.text)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
            }
        }
    }

    private var metricsGrid: some View {
        let s = cur
        let consumo: Double = {
            guard let s, s.cumKm > 0.3 else { return trip.consumo }
            return s.cumKwh / s.cumKm * 100
        }()
        return HStack(spacing: 8) {
            metricTile("VELOCIDADE", s.map { "\(Fmt.adjSpeed($0.spd))" } ?? "—", "km/h", DS.text)
            metricTile("POTÊNCIA", s.map { Fmt.dec1($0.pwr) } ?? "—", "kW", (s?.pwr ?? 0) < -0.05 ? DS.green : DS.orange)
            metricTile("CONSUMO", consumo > 0 ? Fmt.dec1(consumo) : "—", "", DS.teal)
        }
    }

    private func metricTile(_ label: String, _ value: String, _ unit: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 8.5, weight: .bold)).foregroundStyle(DS.muted).tracking(0.8)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.system(size: 18, weight: .bold)).monospacedDigit().foregroundStyle(tint)
                if !unit.isEmpty { Text(unit).font(.system(size: 9.5)).foregroundStyle(DS.muted) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(DS.panel2, in: RoundedRectangle(cornerRadius: 12))
    }

    private var player: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Button {
                    if !playing, idx >= Double(samples.count - 1) { idx = 0 }
                    playing.toggle()
                } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .bold)).foregroundStyle(.black)
                        .frame(width: 44, height: 44).background(DS.green, in: Circle())
                }.buttonStyle(.plain)
                scrubber
                Button { speed = speed == 1 ? 2 : (speed == 2 ? 4 : 1) } label: {
                    Text("\(speed)×").font(.system(size: 13, weight: .bold)).foregroundStyle(DS.green)
                        .frame(width: 36, height: 30)
                }.buttonStyle(.plain)
            }
            HStack {
                Text(Self.hm.string(from: trip.date)).font(.system(size: 10.5)).foregroundStyle(DS.muted)
                Spacer()
                Text("\(Self.hm.string(from: trip.date.addingTimeInterval(cur?.t ?? 0))) · km \(Fmt.dec1(cur?.cumKm ?? 0))")
                    .font(.system(size: 11, weight: .bold)).monospacedDigit().foregroundStyle(DS.green)
                Spacer()
                Text(Self.hm.string(from: trip.date.addingTimeInterval(samples.last?.t ?? 0)))
                    .font(.system(size: 10.5)).foregroundStyle(DS.muted)
            }
            .padding(.leading, 56).padding(.trailing, 36)
        }
    }

    private var scrubber: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10)).frame(height: 8)
                Capsule().fill(DS.green).frame(width: max(8, w * prog), height: 8)
                Circle().fill(.white).frame(width: 14, height: 14)
                    .offset(x: max(0, min(w - 14, w * prog - 7)))
                    .shadow(color: .black.opacity(0.4), radius: 2)
            }
            .frame(height: 44)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                playing = false
                let p = max(0, min(1, g.location.x / w))
                idx = p * Double(samples.count - 1)
            })
        }
        .frame(height: 44)
    }

    private var speedGraph: some View {
        let spds = samples.map { Double(Fmt.adjSpeed($0.spd)) }
        return VStack(alignment: .leading, spacing: 5) {
            Text("VELOCIDADE NO TRAJETO")
                .font(.system(size: 8.5, weight: .bold)).foregroundStyle(DS.muted).tracking(1)
            Canvas { ctx, size in
                guard spds.count > 1 else { return }
                let w = size.width, h = size.height
                let hi = max(spds.max() ?? 1, 1)
                let n = Double(spds.count - 1)
                func pt(_ i: Int) -> CGPoint { CGPoint(x: w * Double(i) / n, y: h - CGFloat(spds[i] / hi) * (h - 4) - 2) }
                var area = Path(); area.move(to: CGPoint(x: 0, y: h))
                for i in 0..<spds.count { area.addLine(to: pt(i)) }
                area.addLine(to: CGPoint(x: w, y: h)); area.closeSubpath()
                ctx.fill(area, with: .color(DS.green.opacity(0.14)))
                var line = Path(); line.move(to: pt(0))
                for i in 1..<spds.count { line.addLine(to: pt(i)) }
                ctx.stroke(line, with: .color(DS.green), lineWidth: 2)
                let mx = w * prog
                var m = Path(); m.move(to: CGPoint(x: mx, y: 0)); m.addLine(to: CGPoint(x: mx, y: h))
                ctx.stroke(m, with: .color(.white.opacity(0.85)), lineWidth: 1.5)
            }
            .frame(height: 64)
        }
    }

    // Potência do motor elétrico (evKw, com sinal): + = tração, − = regeneração.
    private var powerGraph: some View {
        let pw = samples.map { $0.pwr }
        return VStack(alignment: .leading, spacing: 5) {
            Text("POTÊNCIA DO MOTOR ELÉTRICO")
                .font(.system(size: 8.5, weight: .bold)).foregroundStyle(DS.muted).tracking(1)
            Canvas { ctx, size in
                guard pw.count > 1 else { return }
                let w = size.width, h = size.height
                let hi = max(pw.max() ?? 0, 0), lo = min(pw.min() ?? 0, 0)
                let span = max(hi - lo, 1)
                let n = Double(pw.count - 1)
                func y(_ v: Double) -> CGFloat { h - CGFloat((v - lo) / span) * (h - 4) - 2 }
                func pt(_ i: Int) -> CGPoint { CGPoint(x: w * Double(i) / n, y: y(pw[i])) }
                let zeroY = y(0)
                var zero = Path(); zero.move(to: CGPoint(x: 0, y: zeroY)); zero.addLine(to: CGPoint(x: w, y: zeroY))
                ctx.stroke(zero, with: .color(.white.opacity(0.18)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                var area = Path(); area.move(to: CGPoint(x: 0, y: zeroY))
                for i in 0..<pw.count { area.addLine(to: pt(i)) }
                area.addLine(to: CGPoint(x: w, y: zeroY)); area.closeSubpath()
                ctx.fill(area, with: .color(DS.orange.opacity(0.12)))
                var line = Path(); line.move(to: pt(0))
                for i in 1..<pw.count { line.addLine(to: pt(i)) }
                ctx.stroke(line, with: .color(DS.orange), lineWidth: 2)
                let mx = w * prog
                var m = Path(); m.move(to: CGPoint(x: mx, y: 0)); m.addLine(to: CGPoint(x: mx, y: h))
                ctx.stroke(m, with: .color(.white.opacity(0.85)), lineWidth: 1.5)
            }
            .frame(height: 64)
        }
    }

    // Rotação do motor térmico (ICE). RPM=0 = motor desligado (modo EV).
    private var hasIce: Bool { samples.contains { $0.rpm > 0 } }
    private var rpmGraph: some View {
        let rpm = samples.map { $0.rpm }
        return VStack(alignment: .leading, spacing: 5) {
            Text("ROTAÇÃO DO MOTOR TÉRMICO")
                .font(.system(size: 8.5, weight: .bold)).foregroundStyle(DS.muted).tracking(1)
            Canvas { ctx, size in
                guard rpm.count > 1 else { return }
                let w = size.width, h = size.height
                let hi = max(rpm.max() ?? 1, 1)
                let n = Double(rpm.count - 1)
                func pt(_ i: Int) -> CGPoint { CGPoint(x: w * Double(i) / n, y: h - CGFloat(rpm[i] / hi) * (h - 4) - 2) }
                var area = Path(); area.move(to: CGPoint(x: 0, y: h))
                for i in 0..<rpm.count { area.addLine(to: pt(i)) }
                area.addLine(to: CGPoint(x: w, y: h)); area.closeSubpath()
                ctx.fill(area, with: .color(DS.teal.opacity(0.14)))
                var line = Path(); line.move(to: pt(0))
                for i in 1..<rpm.count { line.addLine(to: pt(i)) }
                ctx.stroke(line, with: .color(DS.teal), lineWidth: 2)
                let mx = w * prog
                var m = Path(); m.move(to: CGPoint(x: mx, y: 0)); m.addLine(to: CGPoint(x: mx, y: h))
                ctx.stroke(m, with: .color(.white.opacity(0.85)), lineWidth: 1.5)
            }
            .frame(height: 64)
        }
    }

    private var shareRow: some View {
        HStack(spacing: 10) {
            if let c = cardURL {
                ShareLink(item: c, preview: SharePreview("Viagem", image: Image(systemName: "map"))) {
                    sharePill("Cartão", primary: true)
                }
            }
            if let g = gpxURL { ShareLink(item: g) { sharePill("GPX") } }
            if let wu = webURL {
                ShareLink(item: wu) { sharePill("Link web") }
            } else {
                Button {
                    Task { creatingWeb = true; webURL = await TrajV2.shareURL(trip); creatingWeb = false }
                } label: { sharePill(creatingWeb ? "Gerando…" : "Link web") }
                    .buttonStyle(.plain).disabled(creatingWeb)
            }
            Spacer()
        }
    }

    private func sharePill(_ text: String, primary: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(primary ? .black : DS.text)
            .padding(.horizontal, 20).padding(.vertical, 10)
            .background(primary ? AnyShapeStyle(DS.green) : AnyShapeStyle(DS.panel2), in: Capsule())
            .overlay(Capsule().stroke(primary ? .clear : DS.border, lineWidth: 1))
    }

    private func load() async {
        defer { loading = false }
        guard let r = await TrajV2.load(trip) else { return }
        coords = r.coords; samples = r.samples
        if let rect = TrajV2.rect(coords) { cam = .rect(rect) }
        gpxURL = TrajV2.gpx(trip, samples)
        Task { cardURL = await TrajV2.card(trip, coords, samples, title: loader.displayName(trip)) }
    }
}

// MARK: - 5c · Insights (push)

struct InsightsV2View: View {
    @ObservedObject private var loader = TripsLoader.shared
    @ObservedObject private var car = CarStore.shared
    @State private var showMilestones = false
    @State private var showReport = false
    @State private var showByMode = false
    @State private var showEcoScore = false
    @State private var showTemp = false
    @State private var showRoutes = false
    @AppStorage("ins2_kind") private var kind = 2          // 0 hoje · 1 7d · 2 30d · 3 mês · 4 personalizado
    @AppStorage("ins2_month") private var monthOffset = 0
    @AppStorage("ins2_from") private var fromTS: Double = 0
    @AppStorage("ins2_to") private var toTS: Double = 0

    // Baseline "se fosse gasolina": SUV gasolina classe H6 ~9 km/L (== ICE_BASELINE_KML
    // do bridge). NÃO usar car.kmPerL: é o km/L rolling *blended*, alto justamente
    // por rodar no elétrico — usá-lo colapsa a economia real.
    private var baselineKmL: Double { 9.0 }
    private var gasL: Double { car.priceGas > 0 ? car.priceGas : 6.0 }

    private var fromDate: Binding<Date> { Binding(get: { fromTS > 0 ? Date(timeIntervalSince1970: fromTS) : Date() }, set: { fromTS = $0.timeIntervalSince1970 }) }
    private var toDate: Binding<Date> { Binding(get: { toTS > 0 ? Date(timeIntervalSince1970: toTS) : Date() }, set: { toTS = $0.timeIntervalSince1970 }) }
    private var periodLabel: String { PeriodUtil.label(kind: kind, monthOffset: monthOffset) }

    private var periodTrips: [Trip] {
        loader.trips.filter { PeriodUtil.contains(kind: kind, monthOffset: monthOffset, from: fromDate.wrappedValue, to: toDate.wrappedValue, $0.date) }
    }
    // Período anterior comparável — só faz sentido no modo mês (delta do eco score).
    private var prevMonthTrips: [Trip] {
        guard kind == 3 else { return [] }
        let cal = Calendar.current
        let sel = cal.date(byAdding: .month, value: -monthOffset, to: Date()) ?? Date()
        guard let prev = cal.date(byAdding: .month, value: -1, to: sel) else { return [] }
        return loader.trips.filter { cal.isDate($0.date, equalTo: prev, toGranularity: .month) }
    }

    private var prevLabel: String { PeriodUtil.monthLabel(monthOffset + 1) }
    private var currentMonthName: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR"); f.dateFormat = "LLLL"
        return f.string(from: Date()).lowercased()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                hero
                PeriodFilterBar(kind: $kind, monthOffset: $monthOffset, earliest: loader.trips.last?.date)
                if kind == 4 { PeriodCalendarCard(from: fromDate, to: toDate) }
                HStack(spacing: 10) {
                    Button { showEcoScore = true } label: { ecoScoreCard }.buttonStyle(.plain)
                    kmMonthCard
                }
                Button { showTemp = true } label: { tempCard }.buttonStyle(.plain)
                Button { showRoutes = true } label: { routesCard }.buttonStyle(.plain)
                listRows
            }
            .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 16)
        }
        .background(DS.bg.ignoresSafeArea())
        .navigationTitle("Insights")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loader.load()
            #if DEBUG
            let d = UserDefaults.standard
            try? await Task.sleep(for: .seconds(0.4))
            switch d.integer(forKey: "v2_sheet") {
            case 1, 5: showEcoScore = true
            case 2: showTemp = true
            case 3: showRoutes = true
            default: break
            }
            #endif
        }
        .sheet(isPresented: $showMilestones) { MilestonesSheet(odometerKm: car.num("odometer_km"), trips: loader.trips) }
        .sheet(isPresented: $showReport) { MonthlyReportSheet(trips: loader.trips, priceKwh: car.priceKwh, priceGas: car.priceGas, kmPerLGas: car.kmPerL) }
        .sheet(isPresented: $showByMode) { ModeEconomySheet() }
        .sheet(isPresented: $showEcoScore) { EcoScoreSheet(trips: loader.trips) }
        .sheet(isPresented: $showTemp) { TempConsumptionSheet(trips: loader.trips) }
        .sheet(isPresented: $showRoutes) { RouteCompareSheet(trips: periodTrips, priceKwh: car.priceKwh, priceGas: car.priceGas, kmPerLGas: car.kmPerL) }
    }

    // MARK: hero — economia vs gasolina

    private var savings: (saved: Double, energy: Double, gas: Double) {
        var km = 0.0, actual = 0.0
        for t in periodTrips where t.distKm > 0.1 {
            km += t.distKm
            actual += t.netKwh * car.priceKwh + t.fuelL * gasL
        }
        let costIfGas = km / baselineKmL * gasL
        return (max(costIfGas - actual, 0), max(actual, 0), costIfGas)
    }

    private var hero: some View {
        let s = savings
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("R$ \(Fmt.int(s.saved))")
                    .font(.system(size: 58, weight: .ultraLight)).tracking(-2)
                    .monospacedDigit().foregroundStyle(DS.green)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text("economizados vs gasolina · \(periodLabel)")
                    .font(.system(size: 11.5)).foregroundStyle(DS.text2)
            }
            Spacer(minLength: 10)
            VStack(alignment: .trailing, spacing: 3) {
                Text("energia \(Fmt.brl(s.energy))").font(.system(size: 11.5)).foregroundStyle(DS.text2)
                Text("gasolina seria \(Fmt.brl(s.gas))").font(.system(size: 11.5)).foregroundStyle(DS.text2)
            }
        }
    }

    // MARK: grid 2 — eco score + km/mês

    private var ecoScoreCard: some View {
        let avg = Eco.avg(periodTrips) ?? Eco.avg(loader.trips)
        let prev = Eco.avg(prevMonthTrips)
        return VStack(spacing: 10) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.10), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: CGFloat(max(0, min(100, avg ?? 0))) / 100)
                    .stroke(DS.green, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(avg.map(String.init) ?? "—")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .monospacedDigit().foregroundStyle(DS.text)
            }
            .frame(width: 84, height: 84)
            VStack(spacing: 2) {
                Text("ECO SCORE").font(.system(size: 8.5, weight: .bold)).foregroundStyle(DS.muted).tracking(1)
                if let a = avg, let p = prev, a != p {
                    Text(a > p ? "+\(a - p) vs \(prevLabel)" : "−\(p - a) vs \(prevLabel)")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(a > p ? DS.green : DS.orange)
                } else {
                    Text("média do período").font(.system(size: 10.5)).foregroundStyle(DS.muted)
                }
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 16)
        .background(DS.panel, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(DS.border, lineWidth: 1))
    }

    private var monthBuckets: [(label: String, km: Double, current: Bool)] {
        let cal = Calendar.current; let now = Date()
        let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR"); f.dateFormat = "MMM"
        return (0..<6).reversed().map { off in
            let d = cal.date(byAdding: .month, value: -off, to: now) ?? now
            let km = loader.trips.filter { cal.isDate($0.date, equalTo: d, toGranularity: .month) }
                .reduce(0.0) { $0 + $1.distKm }
            return (f.string(from: d), km, off == 0)
        }
    }

    private var kmMonthCard: some View {
        let buckets = monthBuckets
        let maxKm = max(buckets.map { $0.km }.max() ?? 1, 1)
        let curKm = buckets.last?.km ?? 0
        let past = buckets.dropLast().filter { $0.km > 0 }
        let media = past.isEmpty ? 0 : past.reduce(0.0) { $0 + $1.km } / Double(past.count)
        return VStack(alignment: .leading, spacing: 10) {
            Text("KM POR MÊS").font(.system(size: 8.5, weight: .bold)).foregroundStyle(DS.muted).tracking(1)
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(Array(buckets.enumerated()), id: \.offset) { _, b in
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(b.current ? AnyShapeStyle(DS.greenGrad) : AnyShapeStyle(DS.panel3))
                            .frame(height: max(6, 54 * b.km / maxKm))
                    }
                }
            }
            .frame(height: 58)
            HStack(alignment: .firstTextBaseline) {
                Text(Fmt.int(curKm)).font(.system(size: 16, weight: .bold)).monospacedDigit().foregroundStyle(DS.text)
                Text("km").font(.system(size: 9.5)).foregroundStyle(DS.muted)
                Spacer()
                Text(media > 0 ? "média \(Fmt.int(media))" : "—")
                    .font(.system(size: 10.5)).foregroundStyle(DS.muted)
            }
        }
        .frame(maxWidth: .infinity).padding(14)
        .background(DS.panel, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(DS.border, lineWidth: 1))
    }

    // MARK: consumo × temperatura

    private var tempPoints: [(temp: Double, cons: Double)] {
        loader.trips
            .filter { $0.fuelL < 0.05 && $0.distKm >= 2 && $0.outsideTemp != nil && $0.netKwh > 0 }
            .map { ($0.outsideTemp!, $0.netKwh / $0.distKm * 100) }
            .filter { $0.cons > 3 && $0.cons < 40 }
    }

    private var tempAnnotation: String? {
        let pts = tempPoints
        let hot = pts.filter { $0.temp > 30 }.map { $0.cons }
        let mild = pts.filter { $0.temp >= 20 && $0.temp <= 25 }.map { $0.cons }
        guard hot.count >= 2, mild.count >= 2 else { return nil }
        let h = hot.reduce(0, +) / Double(hot.count), m = mild.reduce(0, +) / Double(mild.count)
        guard m > 0 else { return nil }
        let pct = Int(((h - m) / m * 100).rounded())
        return pct > 0 ? "AC pesa ~\(pct)% acima de 30°" : nil
    }

    @ViewBuilder private var tempCard: some View {
        let pts = tempPoints
        if pts.count >= 5 {
            let minT = pts.map { $0.temp }.min() ?? 15
            let maxT = max(pts.map { $0.temp }.max() ?? 35, minT + 1)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("CONSUMO × TEMPERATURA")
                        .font(.system(size: 8.5, weight: .bold)).foregroundStyle(DS.muted).tracking(1)
                    Spacer()
                    if let a = tempAnnotation {
                        Text(a).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(DS.orange)
                    }
                }
                Text("kWh/100").font(.system(size: 8.5)).foregroundStyle(DS.muted)
                Canvas { ctx, size in
                    let w = size.width, h = size.height
                    let minC = (pts.map { $0.cons }.min() ?? 0) * 0.9
                    let maxC = max((pts.map { $0.cons }.max() ?? 1) * 1.05, minC + 1)
                    func xy(_ p: (temp: Double, cons: Double)) -> CGPoint {
                        CGPoint(x: CGFloat((p.temp - minT) / (maxT - minT)) * (w - 12) + 6,
                                y: h - CGFloat((p.cons - minC) / (maxC - minC)) * (h - 10) - 5)
                    }
                    // Tendência: regressão linear simples.
                    let n = Double(pts.count)
                    let sx = pts.reduce(0.0) { $0 + $1.temp }, sy = pts.reduce(0.0) { $0 + $1.cons }
                    let sxx = pts.reduce(0.0) { $0 + $1.temp * $1.temp }, sxy = pts.reduce(0.0) { $0 + $1.temp * $1.cons }
                    let denom = n * sxx - sx * sx
                    if abs(denom) > 0.001 {
                        let b = (n * sxy - sx * sy) / denom, a = (sy - b * sx) / n
                        var tr = Path()
                        tr.move(to: xy((minT, a + b * minT)))
                        tr.addLine(to: xy((maxT, a + b * maxT)))
                        ctx.stroke(tr, with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                    for p in pts {
                        let c = xy(p)
                        ctx.fill(Path(ellipseIn: CGRect(x: c.x - 2.5, y: c.y - 2.5, width: 5, height: 5)),
                                 with: .color(p.temp > 30 ? DS.orange : DS.teal))
                    }
                }
                .frame(height: 90)
                HStack {
                    Text("\(Fmt.int(minT))°").font(.system(size: 9)).foregroundStyle(DS.muted)
                    Spacer()
                    Text("\(Fmt.int(maxT))°").font(.system(size: 9)).foregroundStyle(DS.muted)
                }
            }
            .padding(14)
            .background(DS.panel, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(DS.border, lineWidth: 1))
        }
    }

    // MARK: rotas comparadas — melhor viagem vs média do trajeto mais recorrente

    /// Trechos mais repetidos do HISTÓRICO (não do período) — o card é uma porta
    /// de entrada pro comparativo; recorte curto esconderia rotas conhecidas.
    /// Chave canônica geográfica em RouteKey (ver RouteCompareSheet).
    private var topRoutes: [RouteGroup] {
        Array(RouteGroup.build(from: loader.trips).prefix(3))
    }

    @ViewBuilder private var routesCard: some View {
        let rs = topRoutes
        if !rs.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("TRECHOS MAIS FREQUENTES")
                        .font(.system(size: 8.5, weight: .bold)).foregroundStyle(DS.muted).tracking(1)
                    Spacer()
                    Text("comparar →").font(.system(size: 10.5, weight: .bold)).foregroundStyle(DS.teal)
                }
                ForEach(rs) { g in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(g.name).font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(DS.text).lineLimit(1).minimumScaleFactor(0.8)
                            Text("\(g.n)× · \(Fmt.km(g.avgKm)) km · \(Fmt.int(g.avgMin)) min méd.")
                                .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(DS.muted)
                                .lineLimit(1).minimumScaleFactor(0.8)
                        }
                        Spacer(minLength: 6)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(Fmt.dec1(g.avgCons)).font(.system(size: 13, weight: .bold))
                                .monospacedDigit().foregroundStyle(DS.green)
                            // Tendência: metade recente vs antiga. ↓ = consumindo menos.
                            if abs(g.trend) >= 0.5 {
                                HStack(spacing: 2) {
                                    Image(systemName: g.trend < 0 ? "arrow.down" : "arrow.up")
                                        .font(.system(size: 7.5, weight: .bold))
                                    Text(Fmt.dec1(abs(g.trend))).font(.system(size: 9.5, weight: .semibold)).monospacedDigit()
                                }
                                .foregroundStyle(g.trend < 0 ? DS.green : DS.orange)
                            } else {
                                Text("kWh/100").font(.system(size: 8.5)).foregroundStyle(DS.muted)
                            }
                        }
                    }
                    if g.id != rs.last?.id { Rectangle().fill(DS.divider).frame(height: 1) }
                }
            }
            .padding(14)
            .background(DS.panel, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(DS.border, lineWidth: 1))
        }
    }

    private func routeLine(_ name: String, _ detail: String, _ badge: String?, _ tint: Color) -> some View {
        HStack {
            Text(name).font(.system(size: 13, weight: .bold)).foregroundStyle(tint)
            Spacer()
            Text(detail).font(.system(size: 11.5)).monospacedDigit()
                .foregroundStyle(tint == DS.green ? DS.green : DS.text2)
                .lineLimit(1).minimumScaleFactor(0.75)
            if let badge {
                Text(badge).font(.system(size: 11.5, weight: .bold)).foregroundStyle(DS.green)
            }
        }
    }

    // MARK: marcos + relatório

    private var evMilestone: String? {
        let evKm = loader.trips.filter { $0.fuelL < 0.05 }.reduce(0.0) { $0 + $1.distKm }
        guard evKm >= 1000 else { return nil }
        let mil = Int(evKm / 1000) * 1000
        return "\(Fmt.int(Double(mil))) km em EV"
    }

    private var listRows: some View {
        VStack(spacing: 0) {
            Button { showMilestones = true } label: {
                HStack {
                    Text("Marcos").font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.text)
                    Spacer()
                    if let m = evMilestone {
                        Text(m)
                            .font(.system(size: 11, weight: .bold)).foregroundStyle(DS.green)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(DS.green.opacity(0.10), in: Capsule())
                            .overlay(Capsule().stroke(DS.green.opacity(0.35), lineWidth: 1))
                    }
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.muted)
                }
                .padding(.horizontal, 14).frame(height: 52)
            }.buttonStyle(.plain)
            Rectangle().fill(DS.divider).frame(height: 1).padding(.horizontal, 14)
            Button { showByMode = true } label: {
                HStack {
                    Text("Economia por modo").font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.text)
                    Spacer()
                    Text("EV · HEV · one-pedal").font(.system(size: 11.5)).foregroundStyle(DS.text2)
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.muted)
                }
                .padding(.horizontal, 14).frame(height: 52)
            }.buttonStyle(.plain)
            Rectangle().fill(DS.divider).frame(height: 1).padding(.horizontal, 14)
            Button { showReport = true } label: {
                HStack {
                    Text("Relatório mensal").font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.text)
                    Spacer()
                    Text("\(currentMonthName) pronto").font(.system(size: 11.5)).foregroundStyle(DS.text2)
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.muted)
                }
                .padding(.horizontal, 14).frame(height: 52)
            }.buttonStyle(.plain)
        }
        .background(DS.panel, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(DS.border, lineWidth: 1))
    }
}
