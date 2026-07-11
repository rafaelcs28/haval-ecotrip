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
    let onFuel: Bool                            // já rodando a gasolina ao chegar nesta perna
    let fuelL: Double                           // gasolina acumulada até aqui (L)
    let isFinal: Bool
}

struct ArrivalPlan {
    let destName: String
    let destLat: Double, destLng: Double
    let distanceKm: Double, durationMin: Int, etaClock: String
    let climbM: Int, descentM: Int, traffic: Bool
    let curSoc: Int, predictedSoc: Int
    let energyKwh: Double, capacityKwh: Double
    let fuelL: Double                           // gasolina total prevista (0 = chega no EV)
    let onFuel: Bool                            // chega rodando a gasolina (EV esgotou)
    let evDepleteKm: Double?                    // km onde o EV acaba (nil = chega inteiro no EV)
    let confidencePct: Int                      // banda ± de confiança (erro médio histórico)
    var legs: [ArrivalLeg] = []                 // 1 por perna; última = destino final
    var stops: [(lat: Double, lng: Double, name: String)] = []   // paradas (sem origem/destino)
}

// Rota alternativa (resumo) pra comparar/escolher. Vem de /api/route-plan?alt=1.
// idx 0 = rota primária. Escolher uma muda a previsão mostrada.
struct RouteAlt: Identifiable {
    let id = UUID()
    let idx: Int
    let distanceKm: Double, durationMin: Int
    let climbM: Int, descentM: Int, traffic: Bool
    let predictedSoc: Int, onFuel: Bool
    let fuelL: Double, evDepleteKm: Double?, energyKwh: Double
    let via: String                       // vias principais ("BR-153, Avenida 85")
    let coords: [CLLocationCoordinate2D]  // geometria pro mapa
}

// Plano de recarga reverso: quanto carregar (e onde/quanto tempo) pra chegar com a
// margem alvo. Vem do /api/charge-plan.
struct ChargePlan {
    let feasibleNow: Bool
    let target: Int, socNeeded: Int, addPct: Int
    let addKwh: Double, minutes: Int
    let stationName: String, stationPowerKw: Double
}

@MainActor
final class ArrivalStore: ObservableObject {
    @Published var loading = false
    @Published var error: String?
    @Published var plan: ArrivalPlan?
    @Published var routeAlts: [RouteAlt] = []       // rotas alternativas (vazio = só 1 rota)
    @Published var selectedRouteIdx = 0             // rota escolhida (índice em routeAlts)
    @Published var chargePlan: ChargePlan?
    @Published var chargeLoading = false
    // Origem/SOC da última rota calculada — reaproveitados pelo plano de recarga.
    private var lastFrom: (Double, Double)?
    private var lastSoc = 0

    private var base: String { BridgeRouter.shared.currentURL }

    // toLat/toLng != nil → destino já resolvido. fromLat/fromLng != nil → saída custom
    // (simular outro ponto de partida); senão usa o local atual do carro.
    func compute(query: String, trips: [Trip], toLat: Double? = nil, toLng: Double? = nil,
                 fromLat: Double? = nil, fromLng: Double? = nil,
                 stops: [(lat: Double, lng: Double, name: String)] = [],
                 targetSoc: Int = 12) async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!q.isEmpty || (toLat != nil && toLng != nil)), !loading else { return }
        loading = true; error = nil; plan = nil; chargePlan = nil
        routeAlts = []; selectedRouteIdx = 0
        defer { loading = false }

        let car = CarStore.shared
        let lat = fromLat ?? car.lat, lng = fromLng ?? car.lng
        if lat == 0 && lng == 0 { error = "Defina a saída ou aguarde o GPS do carro."; return }
        let curSoc = Int(car.socPct.rounded())
        lastFrom = (lat, lng); lastSoc = curSoc

        let nm = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        var urlStr: String
        if let tla = toLat, let tlo = toLng {
            urlStr = "\(base)/api/route-plan?from_lat=\(lat)&from_lng=\(lng)&to_lat=\(tla)&to_lng=\(tlo)&q=\(nm)"
        } else {
            urlStr = "\(base)/api/route-plan?from_lat=\(lat)&from_lng=\(lng)&q=\(nm)"
        }
        urlStr += "&soc=\(curSoc)&alt=1"   // SOC da UI + pede rotas alternativas pra comparar
        if targetSoc > 12 { urlStr += "&target_soc=\(targetSoc)" }   // preservar bateria: chegar com X%
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

            // Modelo de energia (PHEV) já vem pronto do bridge: SOC de chegada, handoff
            // EV→gasolina, banda de confiança e capacidade — sem recálculo no cliente.
            let cap = num(j["capacityKwh"])
            let energy = num(j["energyKwh"])
            let predTop = Int(num(j["predictedSoc"]))
            let fuelL = num(j["fuelL"])
            let onFuel = (j["onFuel"] as? Bool) ?? false
            let evDep = j["evDepleteKm"]
            let evDepleteKm: Double? = (evDep == nil || evDep is NSNull) ? nil : num(evDep)
            let conf = Int(num(j["confidencePct"]))
            let df = DateFormatter(); df.locale = Locale(identifier: "pt_BR"); df.dateFormat = "HH:mm"

            // Pernas: distância/duração/ETA da geometria (j["legs"]); SOC/handoff/gasolina
            // do modelo de energia (j["energyLegs"], paralelo). Sem paradas → 1 perna.
            let rawLegs = (j["legs"] as? [[String: Any]]) ?? []
            let energyLegs = (j["energyLegs"] as? [[String: Any]]) ?? []
            var legs: [ArrivalLeg] = []
            var cumMin = 0
            if rawLegs.isEmpty {
                legs = [ArrivalLeg(name: name, lat: dLat, lng: dLng, distanceKm: distKm, durationMin: durMin,
                                   etaClock: df.string(from: Date().addingTimeInterval(Double(durMin) * 60)),
                                   socAtArrival: predTop, onFuel: onFuel, fuelL: fuelL, isFinal: true)]
            } else {
                for (k, lg) in rawLegs.enumerated() {
                    let d = num(lg["distanceKm"]), dur = Int(num(lg["durationMin"]))
                    cumMin += dur
                    let el = k < energyLegs.count ? energyLegs[k] : [:]
                    let soc = Int(num(el["socArrival"]))
                    let legFuel = num(el["fuelL"])
                    let legOnFuel = (el["onFuel"] as? Bool) ?? false
                    let isFinal = (k == rawLegs.count - 1)
                    // stops é indexado pelo índice da leg — se o backend mandar mais legs
                    // que stops, stops[k] crashava (out of bounds). Cai pro destino final.
                    let pt: (Double, Double, String) = (!isFinal && k < stops.count)
                        ? (stops[k].lat, stops[k].lng, stops[k].name) : (dLat, dLng, name)
                    legs.append(ArrivalLeg(name: pt.2, lat: pt.0, lng: pt.1, distanceKm: d, durationMin: dur,
                                           etaClock: df.string(from: Date().addingTimeInterval(Double(cumMin) * 60)),
                                           socAtArrival: soc, onFuel: legOnFuel, fuelL: legFuel, isFinal: isFinal))
                }
            }
            let pred = legs.last?.socAtArrival ?? predTop

            plan = ArrivalPlan(destName: name, destLat: dLat, destLng: dLng,
                               distanceKm: distKm, durationMin: durMin,
                               etaClock: df.string(from: Date().addingTimeInterval(Double(durMin) * 60)),
                               climbM: climb, descentM: desc, traffic: traffic,
                               curSoc: curSoc, predictedSoc: pred, energyKwh: energy, capacityKwh: cap,
                               fuelL: fuelL, onFuel: onFuel, evDepleteKm: evDepleteKm, confidencePct: conf,
                               legs: legs, stops: stops)

            // Rotas alternativas (idx 0 = a já mostrada). Só expõe o seletor se vier >1.
            if let arr = j["routes"] as? [[String: Any]], arr.count > 1 {
                routeAlts = arr.map { a in
                    let ev = a["evDepleteKm"]
                    let coords = (a["geometry"] as? [[Any]] ?? []).compactMap { c -> CLLocationCoordinate2D? in
                        guard c.count >= 2 else { return nil }
                        return CLLocationCoordinate2D(latitude: num(c[1]), longitude: num(c[0]))
                    }
                    return RouteAlt(idx: Int(num(a["idx"])), distanceKm: num(a["distanceKm"]),
                                    durationMin: Int(num(a["durationMin"])), climbM: Int(num(a["climbM"])),
                                    descentM: Int(num(a["descentM"])), traffic: (a["traffic"] as? Bool) ?? false,
                                    predictedSoc: Int(num(a["predictedSoc"])), onFuel: (a["onFuel"] as? Bool) ?? false,
                                    fuelL: num(a["fuelL"]),
                                    evDepleteKm: (ev == nil || ev is NSNull) ? nil : num(ev),
                                    energyKwh: num(a["energyKwh"]),
                                    via: (a["via"] as? String) ?? "",
                                    coords: coords)
                }
            }
        } catch {
            self.error = "Falha ao calcular (\(error.localizedDescription))"
        }
    }

    // Troca a rota mostrada por uma alternativa: reescreve as métricas de topo
    // (dist/tempo/SOC/gasolina/energia) com o resumo da rota escolhida. Multi-parada
    // não expõe alternativas (o roteador só dá alternativas em A→B direto), então a
    // perna única é reconstruída; com paradas, mantém as pernas originais.
    func selectRoute(_ a: RouteAlt) {
        guard let p = plan else { return }
        selectedRouteIdx = a.idx
        let df = DateFormatter(); df.locale = Locale(identifier: "pt_BR"); df.dateFormat = "HH:mm"
        let eta = df.string(from: Date().addingTimeInterval(Double(a.durationMin) * 60))
        var legs = p.legs
        if legs.count == 1 {
            legs = [ArrivalLeg(name: p.destName, lat: p.destLat, lng: p.destLng,
                               distanceKm: a.distanceKm, durationMin: a.durationMin, etaClock: eta,
                               socAtArrival: a.predictedSoc, onFuel: a.onFuel, fuelL: a.fuelL, isFinal: true)]
        }
        plan = ArrivalPlan(destName: p.destName, destLat: p.destLat, destLng: p.destLng,
                           distanceKm: a.distanceKm, durationMin: a.durationMin, etaClock: eta,
                           climbM: a.climbM, descentM: a.descentM, traffic: a.traffic,
                           curSoc: p.curSoc, predictedSoc: a.predictedSoc, energyKwh: a.energyKwh,
                           capacityKwh: p.capacityKwh, fuelL: a.fuelL, onFuel: a.onFuel,
                           evDepleteKm: a.evDepleteKm, confidencePct: p.confidencePct, legs: legs, stops: p.stops)
        chargePlan = nil   // rota mudou → recalcula plano de recarga sob demanda
    }

    // Plano de recarga reverso pro destino atual: usa a origem/SOC da última rota +
    // a margem alvo (target). Reaproveita o destino+paradas do plano calculado.
    func loadChargePlan(target: Int) async {
        guard let p = plan, let from = lastFrom, !base.isEmpty else { return }
        chargeLoading = true; defer { chargeLoading = false }
        var s = "\(base)/api/charge-plan?from_lat=\(from.0)&from_lng=\(from.1)&to_lat=\(p.destLat)&to_lng=\(p.destLng)&soc=\(lastSoc)&target=\(target)"
        if !p.stops.isEmpty { s += "&stops=" + p.stops.map { "\($0.lat),\($0.lng)" }.joined(separator: ";") }
        guard let url = URL(string: s) else { return }
        var r = URLRequest(url: url); r.timeoutInterval = 15
        r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let st = j["station"] as? [String: Any]
        chargePlan = ChargePlan(
            feasibleNow: (j["feasibleNow"] as? Bool) ?? false,
            target: Int(num(j["target"])), socNeeded: Int(num(j["socNeeded"])),
            addPct: Int(num(j["addPct"])), addKwh: num(j["addKwh"]), minutes: Int(num(j["minutes"])),
            stationName: (st?["name"] as? String) ?? "", stationPowerKw: num(st?["avgPowerKw"]))
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

    // Retira o destino ativo do carro (limpa rota/chegada no bridge).
    func clearFromCar() async {
        guard !base.isEmpty, let url = URL(string: "\(base)/api/nav-clear") else { return }
        var r = URLRequest(url: url); r.httpMethod = "POST"; r.timeoutInterval = 10
        r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        if let (_, resp) = try? await URLSession.shared.data(for: r),
           (resp as? HTTPURLResponse)?.statusCode == 200 {
            sentMsg = "Destino retirado do carro ✓"
        } else {
            sentMsg = "Falha ao retirar"
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
    @State private var sharingDest: String?               // destino a compartilhar → abre QuickShareSheet
    @State private var pickingSaved = false               // texto setado por favorito/recente (não zerar coord)
    @State private var showMapPicker = false
    @State private var mapInitial: CLLocationCoordinate2D? = nil   // ponto inicial do mapa (vindo da busca)
    @State private var destWaypointId = UUID()                     // identidade estável do destino na lista reordenável
    @State private var targetSoc = 12                              // SOC de chegada desejado (12 = auto/só reserva PHEV)
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(DS.muted)
                    }
                }
            }
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
            .sheet(isPresented: Binding(get: { sharingDest != nil }, set: { if !$0 { sharingDest = nil } })) {
                QuickShareSheet(destName: sharingDest ?? "")
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
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
        Task { await store.compute(query: name, trips: trips, toLat: c.latitude, toLng: c.longitude, stops: stopsCoords, targetSoc: targetSoc) }
    }

    private func use(_ p: SavedPlace) {
        // Marca que o texto foi setado por um lugar salvo, pra o onChange do campo
        // NÃO zerar a coordenada (senão o cálculo cai no texto "Trabalho" em vez do
        // endereço salvo). Calcula direto com as coordenadas do favorito/recente.
        pickingSaved = true
        dest = p.display
        destCoord = (p.lat, p.lng)
        completer.clear(); focusedField = nil
        Task { await store.compute(query: p.name, trips: trips, toLat: p.lat, toLng: p.lng, stops: stopsCoords, targetSoc: targetSoc) }
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
                                fromLat: fromC?.0, fromLng: fromC?.1, stops: stopsCoords,
                                targetSoc: targetSoc)
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

    // Cartão do plano de recarga reverso: quanto carregar (e onde/quanto tempo) pra
    // chegar com a margem alvo, OU confirmação de que já dá pra ir.
    @ViewBuilder private func chargePlanCard(_ cp: ChargePlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if cp.feasibleNow {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(DS.green)
                    Text("Já dá pra ir — chega com ~\(cp.target)% sem recarregar.")
                        .font(.system(size: 13)).foregroundStyle(DS.text)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Carregue até").font(.system(size: 13)).foregroundStyle(DS.muted)
                    Text("\(cp.socNeeded)%").font(.system(size: 24, weight: .semibold, design: .rounded)).foregroundStyle(DS.teal).monospacedDigit()
                    Text("(+\(cp.addPct)% · \(Fmt.dec1(cp.addKwh)) kWh)").font(.system(size: 11)).foregroundStyle(DS.muted)
                }
                Text("para chegar com ~\(cp.target)% de margem.").font(.system(size: 9.5)).foregroundStyle(DS.muted)
                if !cp.stationName.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.fill").font(.system(size: 11)).foregroundStyle(DS.orange)
                        Text("≈\(cp.minutes) min em \(cp.stationName) (\(Fmt.dec1(cp.stationPowerKw)) kW)")
                            .font(.system(size: 11)).foregroundStyle(DS.text)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 11)
        .background(DS.panel2)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    // Cor por rota — amarra a linha no mapa à linha do seletor (mesma cor = mesma rota).
    private func altColor(_ idx: Int) -> Color {
        switch idx {
        case 0:  return DS.teal
        case 1:  return DS.orange
        default: return Color(red: 0.64, green: 0.45, blue: 0.92)
        }
    }

    // Mapa das alternativas: cada rota com sua cor, a selecionada por cima e mais grossa.
    // .automatic enquadra todas as geometrias. Interativo (pan/zoom) pra inspecionar.
    @ViewBuilder private var routeAltsMap: some View {
        let ordered = store.routeAlts.sorted { ($0.idx == store.selectedRouteIdx ? 1 : 0) < ($1.idx == store.selectedRouteIdx ? 1 : 0) }
        Map(initialPosition: .automatic) {
            ForEach(ordered) { a in
                let sel = a.idx == store.selectedRouteIdx
                MapPolyline(coordinates: a.coords)
                    .stroke(altColor(a.idx).opacity(sel ? 1 : 0.5),
                            style: StrokeStyle(lineWidth: sel ? 6 : 3, lineCap: .round, lineJoin: .round))
            }
            if let p = store.plan {
                Marker("Destino", systemImage: "flag.checkered",
                       coordinate: CLLocationCoordinate2D(latitude: p.destLat, longitude: p.destLng))
                    .tint(DS.teal)
                ForEach(Array(p.stops.enumerated()), id: \.offset) { _, s in
                    Marker(s.name, systemImage: "mappin",
                           coordinate: CLLocationCoordinate2D(latitude: s.lat, longitude: s.lng))
                        .tint(DS.orange)
                }
            }
        }
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // Seletor de rotas alternativas: uma linha por rota com via principal, tempo/dist e
    // o desfecho de energia (SOC na chegada ou gasolina). A selecionada fica destacada.
    // Seletor de SOC de chegada desejado. Auto (12) = usa a bateria até a reserva PHEV.
    // 20/30/40/50 = preserva bateria; o bridge recalcula quanto de gasolina isso custa.
    @ViewBuilder private var targetSocPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Chegar com").font(.caption).foregroundStyle(DS.muted)
            HStack(spacing: 6) {
                ForEach([12, 20, 30, 40, 50], id: \.self) { v in
                    let sel = targetSoc == v
                    Button {
                        guard targetSoc != v else { return }
                        targetSoc = v; calc()
                    } label: {
                        Text(v == 12 ? "Auto" : "\(v)%")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(sel ? DS.bg : DS.text)
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                            .background(sel ? DS.teal : DS.panel2)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder private var routeAltsPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Rotas").font(.caption).foregroundStyle(DS.muted)
            if store.routeAlts.contains(where: { !$0.coords.isEmpty }) { routeAltsMap }
            ForEach(store.routeAlts) { a in
                let sel = a.idx == store.selectedRouteIdx
                Button { store.selectRoute(a) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: sel ? "largecircle.fill.circle" : "circle")
                            .font(.subheadline).foregroundStyle(altColor(a.idx).opacity(sel ? 1 : 0.6))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.via.isEmpty ? (a.idx == 0 ? "Rota recomendada" : "Alternativa \(a.idx)")
                                                : "via \(a.via)")
                                .font(.subheadline.weight(.semibold)).foregroundStyle(DS.text).lineLimit(1)
                            HStack(spacing: 4) {
                                Text("\(a.durationMin) min · \(Fmt.km(a.distanceKm)) km").font(.caption2).foregroundStyle(DS.muted)
                                if a.traffic { Image(systemName: "car.2.fill").font(.system(size: 9)).foregroundStyle(DS.muted) }
                            }
                        }
                        Spacer(minLength: 0)
                        if a.onFuel {
                            HStack(spacing: 3) {
                                Image(systemName: "fuelpump.fill").font(.caption2)
                                Text("\(Fmt.dec1(a.fuelL)) L").font(.system(size: 16, weight: .bold, design: .rounded))
                            }.foregroundStyle(DS.orange)
                        } else {
                            Text("\(a.predictedSoc)%").font(.system(size: 18, weight: .bold, design: .rounded))
                                .foregroundStyle(arrivalSocColor(a.predictedSoc))
                        }
                    }
                    .padding(10)
                    .background(sel ? altColor(a.idx).opacity(0.12) : DS.panel2)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(sel ? altColor(a.idx).opacity(0.5) : .clear, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private func resultCard(_ p: ArrivalPlan) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header: destino + chip de ETA à direita.
            HStack(alignment: .top) {
                Text(p.destName).font(.system(size: 15, weight: .bold)).foregroundStyle(DS.text).lineLimit(2)
                Spacer(minLength: 8)
                DSChip(text: "\(p.etaClock) · \(p.durationMin) min", color: p.traffic ? DS.orange : DS.teal)
            }

            // Hero: SOC previsto na chegada (numeral ultraLight monospaced).
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(p.predictedSoc)")
                            .font(.system(size: 72, weight: .ultraLight, design: .rounded))
                            .foregroundStyle(arrivalSocColor(p.predictedSoc)).monospacedDigit()
                        Text("%").font(.system(size: 18)).foregroundStyle(DS.muted)
                    }
                    Text("SOC NA CHEGADA · ± \(p.confidencePct)").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DS.muted).tracking(0.5)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(p.curSoc)%").font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(DS.text).monospacedDigit()
                    Text("agora").font(.system(size: 9.5)).foregroundStyle(DS.muted)
                }
            }

            // Alvo de chegada: preservar bateria (chegar com X%). Auto = só a reserva
            // PHEV de 12%. Trocar recalcula a rota (mais bateria guardada = mais gasolina).
            targetSocPicker

            // Escolha de rota: compara alternativas (tempo/dist/SOC/gasolina) e
            // escolhe — a previsão mostrada passa a refletir a rota selecionada.
            if store.routeAlts.count > 1 { routeAltsPicker }

            // Handoff PHEV: o EV não chega — o motor a combustão assume no caminho.
            if p.onFuel || p.fuelL > 0 || p.evDepleteKm != nil {
                HStack(spacing: 10) {
                    Image(systemName: "fuelpump.fill").font(.system(size: 20)).foregroundStyle(DS.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        if let dep = p.evDepleteKm {
                            Text(targetSoc > 12 ? "Elétrico até ~\(Fmt.km(dep)) km" : "Bateria acaba em ~\(Fmt.km(dep)) km")
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.text)
                        } else {
                            Text("Trecho rodando a gasolina").font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.text)
                        }
                        Text(targetSoc > 12
                             ? "Motor assume · ~\(Fmt.dec1(p.fuelL)) L p/ chegar com \(targetSoc)%"
                             : "Motor assume · ~\(Fmt.dec1(p.fuelL)) L de gasolina até o destino")
                            .font(.system(size: 9.5)).foregroundStyle(DS.muted)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 11)
                .background(DS.panel2).clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            }

            // Plano de recarga reverso: "carrega até X% pra chegar com margem".
            // Aparece quando o EV não chega (vai usar gasolina). Toca → consulta o bridge.
            if p.onFuel || p.fuelL > 0 {
                if let cp = store.chargePlan {
                    chargePlanCard(cp)
                } else {
                    DSActionButton(icon: "bolt.fill", title: "Plano de recarga",
                                   color: DS.teal, busy: store.chargeLoading) {
                        Task { await store.loadChargePlan(target: 20) }
                    }
                }
            }

            // Métricas do trajeto.
            HStack(spacing: 10) {
                DSMetric(value: Fmt.km(p.distanceKm), unit: "km", label: "Distância", color: DS.blue, compact: true)
                DSMetric(value: "↑ \(Fmt.int(Double(p.climbM)))", unit: "m", label: "Subida", color: DS.green, compact: true)
                DSMetric(value: "↓ \(Fmt.int(Double(p.descentM)))", unit: "m", label: "Descida", color: DS.blue, compact: true)
                DSMetric(value: Fmt.dec1(p.energyKwh), unit: "kWh", label: "Energia", color: DS.orange, compact: true)
            }
            .padding(.horizontal, 12).padding(.vertical, 12)
            .background(DS.panel2).clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))

            // SOC em cada parada (cumulativo) quando há paradas.
            if p.legs.count > 1 {
                VStack(spacing: 0) {
                    ForEach(Array(p.legs.enumerated()), id: \.element.id) { i, lg in
                        HStack(spacing: 10) {
                            Image(systemName: lg.isFinal ? "flag.checkered.circle.fill" : "\(min(i + 1, 50)).circle.fill")
                                .font(.system(size: 18)).foregroundStyle(lg.isFinal ? DS.teal : DS.orange).frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(lg.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.text).lineLimit(1)
                                Text("\(lg.etaClock) · \(Fmt.km(lg.distanceKm)) km").font(.system(size: 9.5)).foregroundStyle(DS.muted)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            if lg.onFuel {
                                HStack(spacing: 3) {
                                    Image(systemName: "fuelpump.fill").font(.system(size: 12))
                                    Text("\(Fmt.dec1(lg.fuelL)) L").font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                                }.foregroundStyle(DS.orange)
                            } else {
                                Text("\(lg.socAtArrival)%").font(.system(size: 17, weight: .semibold, design: .rounded))
                                    .foregroundStyle(arrivalSocColor(lg.socAtArrival)).monospacedDigit()
                            }
                        }
                        .padding(.vertical, 11)
                        if lg.id != p.legs.last?.id { Rectangle().fill(DS.divider).frame(height: 1) }
                    }
                }
                .padding(.horizontal, 12)
                .background(DS.panel2).clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            }

            // CTA primária dividida: esquerda envia pro carro, direita compartilha.
            HStack(spacing: 8) {
                Button { Task { await store.sendToCar(p) } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "car.fill").font(.system(size: 14, weight: .bold))
                        Text("Enviar pro carro").font(.system(size: 14, weight: .bold)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity).frame(height: 42)
                    .foregroundStyle(.black).background(DS.green)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)

                Button { sharingDest = p.destName } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 14, weight: .bold))
                        Text("Compartilhar").font(.system(size: 14, weight: .bold)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity).frame(height: 42)
                    .foregroundStyle(DS.teal).background(DS.teal.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            // Um botão por app: ao tocar, pergunta onde abrir (iPhone, Android ou carro).
            HStack(spacing: 8) {
                DSActionButton(icon: "location.north.fill", title: "Waze", color: DS.teal, compact: true) { navApp = "waze" }
                DSActionButton(icon: "map.fill", title: "Maps", color: DS.blue, compact: true) { navApp = "maps" }
                DSActionButton(icon: "mappin.and.ellipse", title: "Google", color: DS.orange, compact: true) { navApp = "gmaps" }
            }

            // Retira o destino que foi mandado pro painel do carro.
            Button { Task { await store.clearFromCar() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle").font(.system(size: 13, weight: .semibold))
                    Text("Retirar destino do carro").font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity).frame(height: 38)
                .foregroundStyle(DS.red).background(DS.red.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(.plain)

            if !p.stops.isEmpty {
                Text("Paradas só no Google Maps. Waze e Maps abrem direto no destino final.")
                    .font(.system(size: 10.5)).foregroundStyle(DS.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let m = store.sentMsg {
                Text(m).font(.system(size: 12)).foregroundStyle(m.contains("✓") ? DS.green : DS.orange)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            Text("Estimativa pelas suas viagens EV: ~\(Fmt.dec1(p.capacityKwh)) kWh úteis · altimetria por mapa · trânsito ao vivo.")
                .font(.system(size: 10.5)).foregroundStyle(DS.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
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
