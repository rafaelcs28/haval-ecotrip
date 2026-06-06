//  ArrivalSheet.swift
//  SOC na chegada (paridade com o APK do carro): digita um destino → bridge
//  (/api/route-plan: rota Mapbox c/ trânsito + altimetria Open-Meteo) → previsão de
//  SOC na chegada. Consumo (kWh/km) e capacidade da bateria são estimados dos próprios
//  dados de viagem já sincronizados (viagens 100% EV), sem hardcode.

import SwiftUI
import MapKit

// Autocomplete de endereço (nativo, sem chave): sugere estabelecimentos/ruas conforme
// digita, com viés na região do carro.
@MainActor
final class AddressCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()
    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }
    func update(_ q: String, near: CLLocationCoordinate2D?) {
        if let c = near, c.latitude != 0 {
            completer.region = MKCoordinateRegion(center: c, latitudinalMeters: 80_000, longitudinalMeters: 80_000)
        }
        completer.queryFragment = q
    }
    func clear() { results = []; completer.queryFragment = "" }
    nonisolated func completerDidUpdateResults(_ c: MKLocalSearchCompleter) {
        let r = c.results
        Task { @MainActor in self.results = r }
    }
    nonisolated func completer(_ c: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.results = [] }
    }
    // Resolve uma sugestão em coordenada + nome.
    func resolve(_ s: MKLocalSearchCompletion) async -> (CLLocationCoordinate2D, String)? {
        let req = MKLocalSearch.Request(completion: s)
        guard let resp = try? await MKLocalSearch(request: req).start(),
              let item = resp.mapItems.first else { return nil }
        return (item.placemark.coordinate, s.title)
    }
}

private func num(_ v: Any?) -> Double {
    if let d = v as? Double { return d }
    if let i = v as? Int { return Double(i) }
    if let n = v as? NSNumber { return n.doubleValue }
    if let s = v as? String { return Double(s) ?? 0 }
    return 0
}

struct ArrivalPlan {
    let destName: String
    let destLat: Double, destLng: Double
    let distanceKm: Double, durationMin: Int, etaClock: String
    let climbM: Int, descentM: Int, traffic: Bool
    let curSoc: Int, predictedSoc: Int
    let energyKwh: Double, capacityKwh: Double
}

@MainActor
final class ArrivalStore: ObservableObject {
    @Published var loading = false
    @Published var error: String?
    @Published var plan: ArrivalPlan?

    private var base: String {
        let u = Settings.bridgeURL.isEmpty ? AuthConfig.bridgeURL : Settings.bridgeURL
        return u.hasSuffix("/") ? String(u.dropLast()) : u
    }

    /// kWh/km recente: net/dist das viagens EV (combustível ~0). Fallback 0,16.
    private func kwhPerKm(_ trips: [Trip]) -> Double {
        let ev = trips.filter { $0.fuelL < 0.05 && $0.distKm >= 2 }.prefix(40)
        let d = ev.reduce(0) { $0 + $1.distKm }, k = ev.reduce(0) { $0 + $1.netKwh }
        guard d > 5, k > 0 else { return 0.16 }
        return min(max(k / d, 0.05), 0.5)
    }

    /// Capacidade útil (kWh) estimada das viagens EV com queda de SOC: net / (ΔSOC/100).
    private func capacityKwh(_ trips: [Trip]) -> Double {
        let caps: [Double] = trips.compactMap { t in
            let drop = t.startSoc - t.endSoc
            guard t.fuelL < 0.05, drop > 5, t.netKwh > 0.5 else { return nil }
            return t.netKwh / (drop / 100.0)
        }.filter { $0 > 8 && $0 < 80 }
        guard !caps.isEmpty else { return 34.0 }   // fallback: capacidade de fábrica (H6 PHEV)
        return caps.reduce(0, +) / Double(caps.count)
    }

    // toLat/toLng != nil → destino já resolvido. fromLat/fromLng != nil → saída custom
    // (simular outro ponto de partida); senão usa o local atual do carro.
    func compute(query: String, trips: [Trip], toLat: Double? = nil, toLng: Double? = nil,
                 fromLat: Double? = nil, fromLng: Double? = nil) async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!q.isEmpty || (toLat != nil && toLng != nil)), !loading else { return }
        loading = true; error = nil; plan = nil
        defer { loading = false }

        let car = CarStore.shared
        let lat = fromLat ?? car.lat, lng = fromLng ?? car.lng
        if lat == 0 && lng == 0 { error = "Defina a saída ou aguarde o GPS do carro."; return }
        let curSoc = Int(car.socPct.rounded())
        let acOn = car.acEnable
        let tempOut = car.outsideTemp != 0 ? car.outsideTemp : 28

        let nm = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlStr: String
        if let tla = toLat, let tlo = toLng {
            urlStr = "\(base)/api/route-plan?from_lat=\(lat)&from_lng=\(lng)&to_lat=\(tla)&to_lng=\(tlo)&q=\(nm)"
        } else {
            urlStr = "\(base)/api/route-plan?from_lat=\(lat)&from_lng=\(lng)&q=\(nm)"
        }
        guard !base.isEmpty, let url = URL(string: urlStr) else {
            error = "Bridge não configurado."; return
        }
        var r = URLRequest(url: url); r.timeoutInterval = 15
        r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: r)
            guard let code = (resp as? HTTPURLResponse)?.statusCode, code == 200,
                  let j = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                error = "Rota indisponível."; return
            }
            let distKm = num(j["distanceKm"]) , climb = Int(num(j["climbM"]))
            let desc = Int(num(j["descentM"])), durMin = Int(num(j["durationMin"]))
            let traffic = (j["traffic"] as? Bool) ?? false
            let name = (j["destName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? q
            let dLat = num(j["destLat"]), dLng = num(j["destLng"])

            let cap = capacityKwh(trips)
            let perKm = kwhPerKm(trips)
            let acH = acOn ? min(max(0.5 + 0.07 * abs(tempOut - 22), 0.5), 1.5) : 0.12
            let eClimate = acH * (Double(durMin) / 60.0)
            let eDrive = distKm * perKm
            let eElev = Double(climb) * 0.0064 - Double(desc) * 0.0035
            let energy = max(eDrive + eElev + eClimate, 0)
            let pred = min(max(curSoc - Int((energy / cap * 100).rounded()), 0), 100)

            let arr = Date().addingTimeInterval(Double(durMin) * 60)
            let df = DateFormatter(); df.locale = Locale(identifier: "pt_BR"); df.dateFormat = "HH:mm"

            plan = ArrivalPlan(destName: name, destLat: dLat, destLng: dLng,
                               distanceKm: distKm, durationMin: durMin, etaClock: df.string(from: arr),
                               climbM: climb, descentM: desc, traffic: traffic,
                               curSoc: curSoc, predictedSoc: pred, energyKwh: energy, capacityKwh: cap)
        } catch {
            self.error = "Falha ao calcular (\(error.localizedDescription))"
        }
    }

    @Published var sentMsg: String?
    // Manda o destino pro carro. app vazio = só painel; "maps"/"waze" = abre a navegação
    // no Android (Nav Relay) que fica no carro, além do painel.
    func sendToCar(_ p: ArrivalPlan, app: String = "") async {
        guard !base.isEmpty, let url = URL(string: "\(base)/api/nav-to") else { return }
        var r = URLRequest(url: url); r.httpMethod = "POST"; r.timeoutInterval = 10
        r.addValue("application/json", forHTTPHeaderField: "Content-Type")
        r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["lat": p.destLat, "lng": p.destLng, "name": p.destName, "app": app])
        if let (_, resp) = try? await URLSession.shared.data(for: r),
           (resp as? HTTPURLResponse)?.statusCode == 200 {
            sentMsg = app == "waze" ? "No carro · abrindo Waze ✓"
                    : app == "maps" ? "No carro · abrindo Maps ✓"
                    : "Enviado pro carro ✓"
        } else {
            sentMsg = "Falha ao enviar pro carro"
        }
    }
}

func arrivalSocColor(_ soc: Int) -> Color {
    if soc < 30 { return DS.orange }
    if soc < 50 { return DS.yellow }
    return DS.green
}

struct ArrivalSheet: View {
    let trips: [Trip]
    @StateObject private var store = ArrivalStore()
    @StateObject private var completer = AddressCompleter()
    @State private var dest = ""
    @State private var origin = ""                        // vazio = local atual do carro
    @State private var destCoord: (Double, Double)? = nil
    @State private var originCoord: (Double, Double)? = nil
    @State private var activeField: Field = .dest
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?

    private enum Field { case origin, dest }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    DSCard {
                        VStack(spacing: 8) {
                            addrField("Saída — local do carro", text: $origin, field: .origin, icon: "location.circle")
                            Button { swapEnds() } label: {
                                Image(systemName: "arrow.up.arrow.down").font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(DS.teal).frame(width: 30, height: 24)
                                    .background(DS.panel2).clipShape(RoundedRectangle(cornerRadius: 8))
                            }.frame(maxWidth: .infinity, alignment: .center)
                            addrField("Destino (endereço ou local)", text: $dest, field: .dest, icon: "mappin.circle")
                            if !completer.results.isEmpty && store.plan == nil { suggestionsList }
                            DSActionButton(icon: "location.fill.viewfinder", title: "Calcular",
                                           color: DS.teal, busy: store.loading) { calc() }
                        }
                    }

                    if let e = store.error {
                        Text(e).font(.callout).foregroundStyle(DS.orange)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
                    }

                    if let p = store.plan { resultCard(p) }
                }
                .padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("SOC na chegada")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fechar") { dismiss() } } }
            .onAppear { focusedField = .dest }
        }
    }

    @ViewBuilder private func addrField(_ placeholder: String, text: Binding<String>, field: Field, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.subheadline).foregroundStyle(field == .origin ? DS.green : DS.teal)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain).autocorrectionDisabled()
                .focused($focusedField, equals: field)
                .submitLabel(.search)
                .onChange(of: text.wrappedValue) { _, q in
                    activeField = field
                    if field == .dest { destCoord = nil } else { originCoord = nil }
                    if q.count >= 3 { completer.update(q, near: CarStore.shared.coordinate) } else { completer.clear() }
                }
                .onSubmit { calc() }
        }
        .padding(12).background(DS.panel2).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var suggestionsList: some View {
        VStack(spacing: 0) {
            ForEach(completer.results.prefix(5), id: \.self) { s in
                Button { pick(s) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.title).font(.subheadline).foregroundStyle(DS.text)
                        if !s.subtitle.isEmpty {
                            Text(s.subtitle).font(.caption2).foregroundStyle(DS.muted).lineLimit(1)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8).padding(.horizontal, 10)
                }
                Divider().background(DS.border)
            }
        }
        .background(DS.panel2).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func calc() {
        focusedField = nil; completer.clear()
        Task {
            var fromC = originCoord
            if fromC == nil, !origin.trimmingCharacters(in: .whitespaces).isEmpty {
                if let c = await resolveQuery(origin) { fromC = (c.latitude, c.longitude) }
            }
            await store.compute(query: dest, trips: trips,
                                toLat: destCoord?.0, toLng: destCoord?.1,
                                fromLat: fromC?.0, fromLng: fromC?.1)
        }
    }

    // Escolheu uma sugestão → preenche o campo ativo + coordenada; se for destino, calcula.
    private func pick(_ s: MKLocalSearchCompletion) {
        let field = activeField
        completer.clear()
        if field == .origin { origin = s.title } else { dest = s.title }
        Task {
            let resolved = await completer.resolve(s)
            if field == .origin {
                originCoord = resolved.map { ($0.0.latitude, $0.0.longitude) }
            } else {
                destCoord = resolved.map { ($0.0.latitude, $0.0.longitude) }
                calc()
            }
        }
    }

    private func swapEnds() {
        swap(&origin, &dest)
        swap(&originCoord, &destCoord)
        completer.clear()
    }

    // Geocoda um texto (origem digitada sem escolher sugestão), com viés na região do carro.
    private func resolveQuery(_ q: String) async -> CLLocationCoordinate2D? {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = q
        req.region = MKCoordinateRegion(center: CarStore.shared.coordinate, latitudinalMeters: 80_000, longitudinalMeters: 80_000)
        guard let resp = try? await MKLocalSearch(request: req).start() else { return nil }
        return resp.mapItems.first?.placemark.coordinate
    }

    @ViewBuilder private func resultCard(_ p: ArrivalPlan) -> some View {
        DSCard {
            VStack(alignment: .leading, spacing: 14) {
                Text(p.destName).font(.headline).foregroundStyle(DS.text).lineLimit(2)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Chegada").font(.subheadline).foregroundStyle(DS.muted)
                    Text(p.etaClock).font(.system(size: 26, weight: .bold, design: .rounded)).foregroundStyle(DS.teal)
                    Text("· \(p.durationMin) min").font(.subheadline).foregroundStyle(DS.muted)
                    if p.traffic { Image(systemName: "car.2.fill").font(.caption).foregroundStyle(DS.muted) }
                }

                HStack(alignment: .bottom, spacing: 10) {
                    Text("SOC na chegada").font(.subheadline).foregroundStyle(DS.muted).padding(.bottom, 10)
                    Text("\(p.predictedSoc)").font(.system(size: 64, weight: .heavy, design: .rounded))
                        .foregroundStyle(arrivalSocColor(p.predictedSoc))
                    Text("%").font(.title3).foregroundStyle(DS.muted).padding(.bottom, 8)
                    Spacer()
                    Text("agora \(p.curSoc)%").font(.subheadline).foregroundStyle(DS.muted).padding(.bottom, 10)
                }

                HStack(spacing: 10) {
                    DSMetric(value: Fmt.km(p.distanceKm), unit: "km", label: "Distância", color: DS.blue, compact: true)
                    DSMetric(value: "↑ \(Fmt.int(Double(p.climbM)))", unit: "m", label: "Subida", color: DS.green, compact: true)
                    DSMetric(value: "↓ \(Fmt.int(Double(p.descentM)))", unit: "m", label: "Descida", color: DS.blue, compact: true)
                    DSMetric(value: Fmt.dec1(p.energyKwh), unit: "kWh", label: "Energia", color: DS.orange, compact: true)
                }

                Text("Estimativa a partir das suas viagens EV: ~\(Fmt.dec1(p.capacityKwh)) kWh úteis · altimetria por mapa · trânsito ao vivo.")
                    .font(.caption2).foregroundStyle(DS.muted)

                // Só pro painel do carro (mesmo desligado — ele puxa ao ligar).
                DSActionButton(icon: "car.fill", title: "Enviar pro carro", color: DS.green) {
                    Task { await store.sendToCar(p) }
                }
                // Abre a navegação no Android (Nav Relay) que fica no carro — sem sacar o aparelho.
                HStack(spacing: 10) {
                    DSActionButton(icon: "location.north.fill", title: "Waze", color: DS.teal) {
                        Task { await store.sendToCar(p, app: "waze") }
                    }
                    DSActionButton(icon: "map.fill", title: "Maps", color: DS.blue) {
                        Task { await store.sendToCar(p, app: "maps") }
                    }
                }
                if let m = store.sentMsg {
                    Text(m).font(.caption).foregroundStyle(m.contains("✓") ? DS.green : DS.orange)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
    }
}
