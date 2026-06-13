//  ArrivalSheet.swift
//  SOC na chegada (paridade com o APK do carro): digita um destino → bridge
//  (/api/route-plan: rota Mapbox c/ trânsito + altimetria Open-Meteo) → previsão de
//  SOC na chegada. Consumo (kWh/km) e capacidade da bateria são estimados dos próprios
//  dados de viagem já sincronizados (viagens 100% EV), sem hardcode.

import SwiftUI
import MapKit
import UIKit

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

// Uma perna do trajeto: termina numa parada ou no destino final. SOC é cumulativo
// (desconta a energia de todas as pernas até aqui).
struct ArrivalLeg: Identifiable {
    let id = UUID()
    let name: String
    let lat: Double, lng: Double
    let distanceKm: Double, durationMin: Int, etaClock: String
    let socAtArrival: Int
    let isFinal: Bool
}

struct ArrivalPlan {
    let destName: String
    let destLat: Double, destLng: Double
    let distanceKm: Double, durationMin: Int, etaClock: String
    let climbM: Int, descentM: Int, traffic: Bool
    let curSoc: Int, predictedSoc: Int
    let energyKwh: Double, capacityKwh: Double
    var legs: [ArrivalLeg] = []                 // 1 por perna; última = destino final
    var stops: [(lat: Double, lng: Double, name: String)] = []   // paradas (sem origem/destino)
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
                 fromLat: Double? = nil, fromLng: Double? = nil,
                 stops: [(lat: Double, lng: Double, name: String)] = []) async {
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
        var urlStr: String
        if let tla = toLat, let tlo = toLng {
            urlStr = "\(base)/api/route-plan?from_lat=\(lat)&from_lng=\(lng)&to_lat=\(tla)&to_lng=\(tlo)&q=\(nm)"
        } else {
            urlStr = "\(base)/api/route-plan?from_lat=\(lat)&from_lng=\(lng)&q=\(nm)"
        }
        if !stops.isEmpty {
            urlStr += "&stops=" + stops.map { "\($0.lat),\($0.lng)" }.joined(separator: ";")
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
            // Energia de uma perna a partir da geometria (mesmo modelo, por trecho).
            func legEnergy(_ d: Double, _ dur: Int, _ cl: Int, _ ds: Int) -> Double {
                max(d * perKm + Double(cl) * 0.0064 - Double(ds) * 0.0035 + acH * (Double(dur) / 60.0), 0)
            }
            let df = DateFormatter(); df.locale = Locale(identifier: "pt_BR"); df.dateFormat = "HH:mm"

            // Pernas vindas do bridge (com paradas). Sem paradas → sintetiza 1 perna
            // com os totais, pra a UI tratar tudo igual.
            let rawLegs = (j["legs"] as? [[String: Any]]) ?? []
            var legs: [ArrivalLeg] = []
            var cumEnergy = 0.0, cumMin = 0
            if rawLegs.isEmpty {
                let e = legEnergy(distKm, durMin, climb, desc)
                let soc = min(max(curSoc - Int((e / cap * 100).rounded()), 0), 100)
                legs = [ArrivalLeg(name: name, lat: dLat, lng: dLng, distanceKm: distKm, durationMin: durMin,
                                   etaClock: df.string(from: Date().addingTimeInterval(Double(durMin) * 60)),
                                   socAtArrival: soc, isFinal: true)]
                cumEnergy = e
            } else {
                for (k, lg) in rawLegs.enumerated() {
                    let d = num(lg["distanceKm"]), dur = Int(num(lg["durationMin"]))
                    let cl = Int(num(lg["climbM"])), ds = Int(num(lg["descentM"]))
                    cumEnergy += legEnergy(d, dur, cl, ds); cumMin += dur
                    let soc = min(max(curSoc - Int((cumEnergy / cap * 100).rounded()), 0), 100)
                    let isFinal = (k == rawLegs.count - 1)
                    // stops é indexado pelo índice da leg — se o backend mandar mais legs
                    // que stops, stops[k] crashava (out of bounds). Cai pro destino final.
                    let pt: (Double, Double, String) = (!isFinal && k < stops.count)
                        ? (stops[k].lat, stops[k].lng, stops[k].name) : (dLat, dLng, name)
                    legs.append(ArrivalLeg(name: pt.2, lat: pt.0, lng: pt.1, distanceKm: d, durationMin: dur,
                                           etaClock: df.string(from: Date().addingTimeInterval(Double(cumMin) * 60)),
                                           socAtArrival: soc, isFinal: isFinal))
                }
            }
            let energy = cumEnergy
            let pred = legs.last?.socAtArrival ?? min(max(curSoc - Int((energy / cap * 100).rounded()), 0), 100)

            plan = ArrivalPlan(destName: name, destLat: dLat, destLng: dLng,
                               distanceKm: distKm, durationMin: durMin,
                               etaClock: df.string(from: Date().addingTimeInterval(Double(durMin) * 60)),
                               climbM: climb, descentM: desc, traffic: traffic,
                               curSoc: curSoc, predictedSoc: pred, energyKwh: energy, capacityKwh: cap,
                               legs: legs, stops: stops)
        } catch {
            self.error = "Falha ao calcular (\(error.localizedDescription))"
        }
    }

    @Published var sentMsg: String?
    // NavRelays Android registrados no bridge — populado por loadNavDevices(). Cada
    // APK instalado/configurado aparece com seu nome (campo "Nome do dispositivo").
    @Published var navDevices: [NavDevice] = []

    func loadNavDevices() async {
        guard !base.isEmpty, let url = URL(string: "\(base)/api/nav-devices") else { return }
        var r = URLRequest(url: url); r.timeoutInterval = 8
        r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = j["devices"] as? [[String: Any]] else { return }
        navDevices = arr.compactMap { d in
            guard let id = d["id"] as? String else { return nil }
            return NavDevice(id: id,
                             name: (d["name"] as? String) ?? id,
                             role: (d["role"] as? String) ?? "car",
                             alwaysOn: (d["alwaysOn"] as? Bool) ?? false)
        }.sorted { $0.name < $1.name }
    }

    // Manda o destino. app vazio = só painel do carro; "maps"/"waze" = abre a navegação
    // no Nav Relay. device (id) tem prioridade sobre target (legado "car"/"phone").
    func sendToCar(_ p: ArrivalPlan, app: String = "", target: String = "", device: String = "", deviceLabel: String = "") async {
        guard !base.isEmpty, let url = URL(string: "\(base)/api/nav-to") else { return }
        var r = URLRequest(url: url); r.httpMethod = "POST"; r.timeoutInterval = 10
        r.addValue("application/json", forHTTPHeaderField: "Content-Type")
        r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        var body: [String: Any] = ["lat": p.destLat, "lng": p.destLng, "name": p.destName, "app": app]
        if !device.isEmpty { body["device"] = device }
        if !target.isEmpty { body["target"] = target }
        // Paradas sempre vão pro bridge: alimentam a rota multi-parada do carro
        // (ETA por parada + persistência). Só o Google Maps abre as paradas na
        // navegação; Waze/Apple Maps ignoram e vão direto, mas a rota do carro mantém.
        if !p.stops.isEmpty {
            body["stops"] = p.stops.map { ["lat": $0.lat, "lng": $0.lng, "name": $0.name] }
        }
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        if let (_, resp) = try? await URLSession.shared.data(for: r),
           (resp as? HTTPURLResponse)?.statusCode == 200 {
            let onde = !deviceLabel.isEmpty ? deviceLabel
                     : target == "phone" ? "No celular" : "No carro"
            sentMsg = app == "waze" ? "\(onde) · abrindo Waze ✓"
                    : app == "gmaps" ? "\(onde) · abrindo Google Maps ✓"
                    : app == "maps" ? "\(onde) · abrindo Maps ✓"
                    : "Enviado pro carro ✓"
        } else {
            sentMsg = "Falha ao enviar"
        }
    }
}

// Parada resolvida (nome + coordenada) na tela de SOC na chegada.
struct ArrivalWaypoint: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var lat: Double
    var lng: Double
}

struct NavDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let role: String         // "car" | "phone" — só pra UI distinguir ícone
    let alwaysOn: Bool       // sinaliza dispositivo dedicado (sempre online)
}

func arrivalSocColor(_ soc: Int) -> Color {
    if soc < 30 { return DS.orange }
    if soc < 50 { return DS.yellow }
    return DS.green
}

// Endereço salvo: recente (busca anterior) ou favorito com apelido (Casa, Trabalho…).
struct SavedPlace: Codable, Identifiable, Equatable {
    var id = UUID()
    var label: String          // apelido do favorito ("" = recente sem apelido)
    var name: String           // endereço/nome resolvido
    var lat: Double
    var lng: Double
    var favorite: Bool = false
    var ts: Double = Date().timeIntervalSince1970
    var display: String { label.isEmpty ? name : label }
}

// Persiste recentes + favoritos no App Group (compartilhável com widgets/intents).
@MainActor
final class PlacesStore: ObservableObject {
    static let shared = PlacesStore()
    @Published private(set) var places: [SavedPlace] = []
    private let key = "arrival_places"
    private var def: UserDefaults { UserDefaults(suiteName: "group.br.com.consorciolimpagyn.havalecotrip") ?? .standard }

    init() { if let d = def.data(forKey: key), let p = try? JSONDecoder().decode([SavedPlace].self, from: d) { places = p } }
    private func persist() { if let d = try? JSONEncoder().encode(places) { def.set(d, forKey: key) } }

    var favorites: [SavedPlace] { places.filter { $0.favorite }.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending } }
    var recents: [SavedPlace]   { places.filter { !$0.favorite }.sorted { $0.ts > $1.ts } }

    private func near(_ p: SavedPlace, _ lat: Double, _ lng: Double) -> Bool {
        abs(p.lat - lat) < 0.0005 && abs(p.lng - lng) < 0.0005
    }

    // Toda busca calculada vira recente (a menos que já exista como favorito/recente perto).
    func addRecent(name: String, lat: Double, lng: Double) {
        guard lat != 0 || lng != 0 else { return }
        if let i = places.firstIndex(where: { near($0, lat, lng) }) {
            places[i].ts = Date().timeIntervalSince1970
            if places[i].name.isEmpty { places[i].name = name }
        } else {
            places.append(SavedPlace(label: "", name: name, lat: lat, lng: lng, favorite: false))
        }
        for old in recents.dropFirst(12) { places.removeAll { $0.id == old.id } }   // mantém 12 recentes
        persist()
    }

    // Move pra favoritos (ou renomeia um favorito existente) com apelido.
    func favorite(_ p: SavedPlace, label: String) {
        if let i = places.firstIndex(where: { $0.id == p.id }) {
            places[i].favorite = true; places[i].label = label
        } else {
            places.append(SavedPlace(label: label, name: p.name, lat: p.lat, lng: p.lng, favorite: true))
        }
        persist()
    }

    func remove(_ p: SavedPlace) { places.removeAll { $0.id == p.id }; persist() }
}

struct ArrivalSheet: View {
    let trips: [Trip]
    @StateObject private var store = ArrivalStore()
    @StateObject private var completer = AddressCompleter()
    @ObservedObject private var places = PlacesStore.shared
    @State private var dest = ""
    @State private var origin = ""                        // vazio = local atual do carro
    @State private var destCoord: (Double, Double)? = nil
    @State private var originCoord: (Double, Double)? = nil
    @State private var stops: [ArrivalWaypoint] = []      // paradas (origem → paradas → destino)
    @State private var stopText = ""                      // campo transitório de busca de parada
    @State private var addingStop = false
    @State private var activeField: Field = .dest
    @State private var favTarget: SavedPlace?             // alvo do alerta "salvar favorito"
    @State private var favName = ""
    @State private var navApp: String?                    // "waze"/"maps" → abre o diálogo "abrir em…"
    @State private var pickingSaved = false               // texto setado por favorito/recente (não zerar coord)
    @State private var showMapPicker = false
    @State private var mapInitial: CLLocationCoordinate2D? = nil   // ponto inicial do mapa (vindo da busca)
    @State private var destWaypointId = UUID()                     // identidade estável do destino na lista reordenável
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?

    private enum Field { case origin, dest, stop }

    private var stopsCoords: [(lat: Double, lng: Double, name: String)] {
        stops.map { (lat: $0.lat, lng: $0.lng, name: $0.name) }
    }

    // O destino entra na lista reordenável só quando há ≥1 parada (senão a linha
    // "Destino" só duplicaria o campo de cima). Última linha = destino.
    private var destInList: Bool { destCoord != nil && !stops.isEmpty }

    private var routePoints: [ArrivalWaypoint] {
        var arr = stops
        if let dc = destCoord, !stops.isEmpty {
            var d = ArrivalWaypoint(name: dest, lat: dc.0, lng: dc.1)
            d.id = destWaypointId   // id estável: o drag perde a linha se mudar a cada render
            arr.append(d)
        }
        return arr
    }

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
                            if !completer.results.isEmpty && store.plan == nil && activeField != .stop { suggestionsList }
                            stopsSection
                            Button {
                                // Usa a busca atual como ponto de partida (pino já posicionado),
                                // pra você só ajustar fino no mapa.
                                Task {
                                    if let dc = destCoord {
                                        mapInitial = CLLocationCoordinate2D(latitude: dc.0, longitude: dc.1)
                                    } else {
                                        let q = dest.trimmingCharacters(in: .whitespaces)
                                        mapInitial = q.isEmpty ? nil : await resolveQuery(q)
                                    }
                                    showMapPicker = true
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "map.fill").font(.caption)
                                    Text(dest.trimmingCharacters(in: .whitespaces).isEmpty ? "Escolher no mapa" : "Ajustar no mapa").font(.caption.weight(.semibold))
                                }.foregroundStyle(DS.teal).frame(maxWidth: .infinity).padding(.vertical, 8)
                                    .background(DS.panel2).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            DSActionButton(icon: "location.fill.viewfinder", title: "Calcular",
                                           color: DS.teal, busy: store.loading) { calc() }
                        }
                    }

                    if let e = store.error {
                        Text(e).font(.callout).foregroundStyle(DS.orange)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
                    }

                    if store.plan == nil && completer.results.isEmpty && !addingStop { placesSection }

                    if let p = store.plan { resultCard(p) }
                }
                .padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("SOC na chegada")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fechar") { dismiss() } } }
            .onAppear { focusedField = .dest }
            .sheet(isPresented: $showMapPicker) {
                MapPickerSheet(start: mapInitial ?? destCoord.map { .init(latitude: $0.0, longitude: $0.1) } ?? CarStore.shared.coordinate,
                               initial: mapInitial) { c, nm in
                    usePicked(c, name: nm)
                }
            }
            .alert("Salvar favorito", isPresented: Binding(
                get: { favTarget != nil }, set: { if !$0 { favTarget = nil } }), presenting: favTarget) { place in
                TextField("Nome (Casa, Trabalho…)", text: $favName)
                Button("Salvar") {
                    let nm = favName.trimmingCharacters(in: .whitespaces)
                    places.favorite(place, label: nm.isEmpty ? place.name : nm)
                    favTarget = nil; favName = ""
                }
                Button("Cancelar", role: .cancel) { favTarget = nil; favName = "" }
            } message: { place in Text(place.name) }
        }
    }

    // Paradas (waypoints): lista reordenável (paradas + destino) + um campo de busca
    // pra incluir mais. Só o Google Maps recebe as paradas; Waze/Apple Maps usam só o destino.
    @ViewBuilder private var stopsSection: some View {
        routeList
        if addingStop {
            VStack(spacing: 6) {
                addrField("Parada (endereço ou local)", text: $stopText, field: .stop, icon: "mappin.and.ellipse")
                // Sugestões da busca de parada — independente de já existir um plano
                // calculado (o destino já resolvido não deve esconder a busca da parada).
                if activeField == .stop && !completer.results.isEmpty {
                    suggestionsList
                } else {
                    // Sem busca ativa: oferece favoritos/recentes como parada (mesma
                    // paridade do destino — dá pra escolher salvos OU pesquisar).
                    stopPlacesPicker
                }
            }
        }
        if stops.count < 8 {
            Button {
                addingStop = true; activeField = .stop; focusedField = .stop
                stopText = ""; completer.clear()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle").font(.caption)
                    Text("Adicionar parada").font(.caption.weight(.semibold))
                }.foregroundStyle(DS.orange).frame(maxWidth: .infinity).padding(.vertical, 8)
                    .background(DS.panel2).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    // Lista reordenável do trajeto: paradas (numeradas) + destino (última linha, quando
    // há ≥1 parada). Arrasta pra reordenar; soltar uma parada depois do destino a promove
    // a destino e rebaixa o antigo destino a parada.
    @ViewBuilder private var routeList: some View {
        let pts = routePoints
        if !pts.isEmpty {
            List {
                ForEach(Array(pts.enumerated()), id: \.element.id) { i, p in
                    let isDest = destInList && i == pts.count - 1
                    HStack(spacing: 10) {
                        Image(systemName: isDest ? "mappin.circle.fill" : "\(min(i + 1, 50)).circle.fill")
                            .font(.subheadline).foregroundStyle(isDest ? DS.teal : DS.orange)
                        VStack(alignment: .leading, spacing: 1) {
                            if isDest { Text("Destino").font(.caption2).foregroundStyle(DS.muted) }
                            Text(p.name).font(.subheadline).foregroundStyle(DS.text).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .listRowBackground(DS.panel2)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 8))
                    .deleteDisabled(isDest)
                }
                .onMove { applyReorder($0, $1) }
                .onDelete { deleteRoutePoints($0) }
            }
            .listStyle(.plain)
            .scrollDisabled(true)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(.active))
            .frame(height: CGFloat(pts.count) * 52)
        }
    }

    // Reordenou: última linha vira destino; o resto vira parada (na ordem mostrada).
    private func applyReorder(_ from: IndexSet, _ to: Int) {
        var pts = routePoints
        pts.move(fromOffsets: from, toOffset: to)
        if destInList, let last = pts.last {
            destWaypointId = UUID()           // destino ganha identidade nova (evita colidir com o antigo)
            stops = Array(pts.dropLast())     // demais viram paradas, mantendo seus ids
            pickingSaved = true               // não deixa o onChange do campo zerar a coord
            dest = last.name
            destCoord = (last.lat, last.lng)
            calc()
        } else {
            stops = pts
            if destCoord != nil { calc() }
        }
    }

    private func deleteRoutePoints(_ offsets: IndexSet) {
        // Destino tem deleteDisabled → só sobram índices de parada (0..<stops.count).
        stops.remove(atOffsets: IndexSet(offsets.filter { $0 < stops.count }))
        if destCoord != nil { calc() }
    }

    // Favoritos/recentes pra usar como PARADA (aparece no campo de parada sem busca ativa).
    @ViewBuilder private var stopPlacesPicker: some View {
        if !places.favorites.isEmpty || !places.recents.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if !places.favorites.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(places.favorites) { f in
                                Button { useStop(f) } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: placeIcon(f.label)).font(.caption)
                                        Text(f.display).font(.subheadline).lineLimit(1)
                                    }
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(DS.panel2).clipShape(Capsule()).foregroundStyle(DS.text)
                                }
                            }
                        }
                    }
                }
                ForEach(places.recents.prefix(4)) { r in
                    Button { useStop(r) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "clock.arrow.circlepath").font(.subheadline).foregroundStyle(DS.muted)
                            Text(r.name).font(.subheadline).foregroundStyle(DS.text).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    // Favoritos (chips) + Recentes (lista), mostrados quando não há busca/resultado ativo.
    @ViewBuilder private var placesSection: some View {
        if !places.favorites.isEmpty || !places.recents.isEmpty {
            DSCard {
                VStack(alignment: .leading, spacing: 12) {
                    if !places.favorites.isEmpty {
                        Text("Favoritos").font(.caption).foregroundStyle(DS.muted)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) { ForEach(places.favorites) { favChip($0) } }
                        }
                    }
                    if !places.recents.isEmpty {
                        Text("Recentes").font(.caption).foregroundStyle(DS.muted)
                        VStack(spacing: 0) {
                            ForEach(places.recents) { r in
                                recentRow(r)
                                if r.id != places.recents.last?.id { Divider().background(DS.border) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func favChip(_ f: SavedPlace) -> some View {
        Button { use(f) } label: {
            HStack(spacing: 6) {
                Image(systemName: placeIcon(f.label)).font(.caption)
                Text(f.display).font(.subheadline).lineLimit(1)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(DS.panel2).clipShape(Capsule()).foregroundStyle(DS.text)
        }
        .contextMenu {
            Button { favName = f.label; favTarget = f } label: { Label("Renomear", systemImage: "pencil") }
            Button(role: .destructive) { places.remove(f) } label: { Label("Remover", systemImage: "trash") }
        }
    }

    private func recentRow(_ r: SavedPlace) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath").font(.subheadline).foregroundStyle(DS.muted)
            Button { use(r) } label: {
                Text(r.name).font(.subheadline).foregroundStyle(DS.text).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button { favName = ""; favTarget = r } label: {
                Image(systemName: "star").font(.subheadline).foregroundStyle(DS.yellow)
            }.buttonStyle(.plain)
            Button { places.remove(r) } label: {
                Image(systemName: "xmark.circle.fill").font(.subheadline).foregroundStyle(DS.muted)
            }.buttonStyle(.plain)
        }
        .padding(.vertical, 9)
    }

    private func placeIcon(_ label: String) -> String {
        let l = label.lowercased()
        if l.contains("casa") { return "house.fill" }
        if l.contains("trabalho") || l.contains("escritório") || l.contains("work") { return "briefcase.fill" }
        return "star.fill"
    }

    // Abre a navegação neste iPhone. app: "waze" | "apple" (Apple Maps) | "gmaps" (Google
    // Maps, único que aceita paradas). Cai pro web se faltar o app.
    private func openLocal(_ p: ArrivalPlan, app: String) {
        let lat = p.destLat, lng = p.destLng
        let appURL: URL?, webURL: URL?
        switch app {
        case "waze":
            appURL = URL(string: "waze://?ll=\(lat),\(lng)&navigate=yes")
            webURL = URL(string: "https://waze.com/ul?ll=\(lat),\(lng)&navigate=yes")
        case "gmaps":
            // Paradas: comgooglemaps:// não aceita waypoints, mas a URL universal sim.
            let way = p.stops.map { "\($0.lat),\($0.lng)" }.joined(separator: "|")
            let wp = way.isEmpty ? "" : "&waypoints=\(way)"
            appURL = URL(string: "comgooglemaps://?daddr=\(lat),\(lng)&directionsmode=driving")
            webURL = URL(string: "https://www.google.com/maps/dir/?api=1&destination=\(lat),\(lng)\(wp)&travelmode=driving")
        default:   // Apple Maps
            appURL = URL(string: "maps://?daddr=\(lat),\(lng)&dirflg=d")
            webURL = URL(string: "http://maps.apple.com/?daddr=\(lat),\(lng)&dirflg=d")
        }
        // Google Maps com paradas: sempre usa a URL universal (o esquema do app não tem
        // waypoints) — o app intercepta o link universal e abre com as paradas.
        if app == "gmaps", !p.stops.isEmpty, let w = webURL {
            UIApplication.shared.open(w)
        } else if let u = appURL, UIApplication.shared.canOpenURL(u) {
            UIApplication.shared.open(u)
        } else if let w = webURL { UIApplication.shared.open(w) }
        let label = app == "waze" ? "Waze" : app == "gmaps" ? "Google Maps" : "Maps"
        store.sentMsg = "Abrindo \(label) neste iPhone ✓"
    }

    // Usa um lugar salvo: preenche o destino + coordenada e calcula.
    // Destino escolhido tocando no mapa: usa a coordenada direto.
    private func usePicked(_ c: CLLocationCoordinate2D, name: String) {
        pickingSaved = true
        dest = name
        destCoord = (c.latitude, c.longitude)
        completer.clear(); focusedField = nil
        Task { await store.compute(query: name, trips: trips, toLat: c.latitude, toLng: c.longitude, stops: stopsCoords) }
    }

    private func use(_ p: SavedPlace) {
        // Marca que o texto foi setado por um lugar salvo, pra o onChange do campo
        // NÃO zerar a coordenada (senão o cálculo cai no texto "Trabalho" em vez do
        // endereço salvo). Calcula direto com as coordenadas do favorito/recente.
        pickingSaved = true
        dest = p.display
        destCoord = (p.lat, p.lng)
        completer.clear(); focusedField = nil
        Task { await store.compute(query: p.name, trips: trips, toLat: p.lat, toLng: p.lng, stops: stopsCoords) }
    }

    // Adiciona um favorito/recente como PARADA (não destino) e recalcula se já há destino.
    private func useStop(_ p: SavedPlace) {
        stops.append(ArrivalWaypoint(name: p.display, lat: p.lat, lng: p.lng))
        stopText = ""; addingStop = false; focusedField = nil; completer.clear()
        if destCoord != nil { calc() }
    }

    @ViewBuilder private func addrField(_ placeholder: String, text: Binding<String>, field: Field, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.subheadline)
                .foregroundStyle(field == .origin ? DS.green : field == .stop ? DS.orange : DS.teal)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain).autocorrectionDisabled()
                .focused($focusedField, equals: field)
                .submitLabel(.search)
                .onChange(of: text.wrappedValue) { _, q in
                    activeField = field
                    // Texto setado por um favorito/recente → não zera a coordenada salva.
                    if pickingSaved { pickingSaved = false; completer.clear(); return }
                    if field == .dest { destCoord = nil } else if field == .origin { originCoord = nil }
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
                                fromLat: fromC?.0, fromLng: fromC?.1, stops: stopsCoords)
            if let p = store.plan, p.destLat != 0 || p.destLng != 0 {
                places.addRecent(name: p.destName, lat: p.destLat, lng: p.destLng)
            }
        }
    }

    // Escolheu uma sugestão → preenche o campo ativo + coordenada; se for destino, calcula.
    // Parada: resolve, anexa à lista e recalcula (se já há destino).
    private func pick(_ s: MKLocalSearchCompletion) {
        let field = activeField
        completer.clear()
        switch field {
        case .origin: origin = s.title
        case .stop:   break
        case .dest:   dest = s.title
        }
        Task {
            let resolved = await completer.resolve(s)
            switch field {
            case .origin:
                originCoord = resolved.map { ($0.0.latitude, $0.0.longitude) }
            case .stop:
                if let r = resolved {
                    stops.append(ArrivalWaypoint(name: s.title, lat: r.0.latitude, lng: r.0.longitude))
                }
                stopText = ""; addingStop = false; focusedField = nil
                if destCoord != nil { calc() }
            case .dest:
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

                // SOC em cada parada (cumulativo) quando há paradas.
                if p.legs.count > 1 {
                    Divider().background(DS.border)
                    VStack(spacing: 8) {
                        ForEach(Array(p.legs.enumerated()), id: \.element.id) { i, lg in
                            HStack(spacing: 8) {
                                Image(systemName: lg.isFinal ? "flag.checkered.circle.fill" : "\(min(i + 1, 50)).circle.fill")
                                    .font(.title3).foregroundStyle(lg.isFinal ? DS.teal : DS.orange)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(lg.name).font(.subheadline.weight(.semibold)).foregroundStyle(DS.text).lineLimit(1)
                                    Text("\(lg.etaClock) · \(Fmt.km(lg.distanceKm)) km").font(.caption2).foregroundStyle(DS.muted)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Text("\(lg.socAtArrival)%").font(.system(size: 19, weight: .bold, design: .rounded))
                                    .foregroundStyle(arrivalSocColor(lg.socAtArrival))
                            }
                        }
                    }
                }

                Text("Estimativa a partir das suas viagens EV: ~\(Fmt.dec1(p.capacityKwh)) kWh úteis · altimetria por mapa · trânsito ao vivo.")
                    .font(.caption2).foregroundStyle(DS.muted)

                // Só pro painel do carro (mesmo desligado — ele puxa ao ligar).
                DSActionButton(icon: "car.fill", title: "Enviar pro carro", color: DS.green) {
                    Task { await store.sendToCar(p) }
                }
                // Um botão por app: ao tocar, pergunta onde abrir (iPhone, Android ou carro).
                HStack(spacing: 8) {
                    DSActionButton(icon: "location.north.fill", title: "Waze", color: DS.teal) { navApp = "waze" }
                    DSActionButton(icon: "map.fill", title: "Maps", color: DS.blue) { navApp = "maps" }
                    DSActionButton(icon: "mappin.and.ellipse", title: "Google", color: DS.orange) { navApp = "gmaps" }
                }
                if !p.stops.isEmpty {
                    Text("Paradas só no Google Maps. Waze e Maps abrem direto no destino final.")
                        .font(.caption2).foregroundStyle(DS.muted)
                }
                if let m = store.sentMsg {
                    Text(m).font(.caption).foregroundStyle(m.contains("✓") ? DS.green : DS.orange)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .confirmationDialog(
            navApp == "waze" ? "Abrir Waze em…" : navApp == "gmaps" ? "Abrir Google Maps em…" : "Abrir Maps em…",
            isPresented: Binding(get: { navApp != nil }, set: { if !$0 { navApp = nil } }),
            titleVisibility: .visible
        ) {
            Button("Neste iPhone") {
                let a = navApp; navApp = nil
                openLocal(p, app: a == "waze" ? "waze" : a == "gmaps" ? "gmaps" : "apple")
            }
            // Lista dinâmica de NavRelays registrados (cada APK aparece pelo nome).
            ForEach(store.navDevices) { d in
                Button("\(d.role == "phone" ? "📱" : "🚗") \(d.name)") {
                    let a = navApp; navApp = nil
                    Task { await store.sendToCar(p, app: a ?? "maps",
                                                 device: d.id, deviceLabel: d.name) }
                }
            }
            // Fallback legado (caso nenhum NavRelay registrado ainda): manda pra todos
            // do tipo. Some quando o bridge novo já tem pelo menos um device listado.
            if store.navDevices.isEmpty {
                Button("Celular Android") {
                    let a = navApp; navApp = nil
                    Task { await store.sendToCar(p, app: a ?? "maps", target: "phone") }
                }
                Button("No carro") {
                    let a = navApp; navApp = nil
                    Task { await store.sendToCar(p, app: a ?? "maps", target: "car") }
                }
            }
            Button("Cancelar", role: .cancel) { navApp = nil }
        }
        // Recarrega periodicamente: se o NavRelay (Android) só registrar depois da tela
        // abrir (estava offline/reconectando), a lista se atualiza sozinha em vez de
        // ficar travada no fallback "Android/iPhone".
        .task {
            while !Task.isCancelled {
                await store.loadNavDevices()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }
}
