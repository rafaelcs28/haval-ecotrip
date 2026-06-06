//  ArrivalSheet.swift
//  SOC na chegada (paridade com o APK do carro): digita um destino → bridge
//  (/api/route-plan: rota Mapbox c/ trânsito + altimetria Open-Meteo) → previsão de
//  SOC na chegada. Consumo (kWh/km) e capacidade da bateria são estimados dos próprios
//  dados de viagem já sincronizados (viagens 100% EV), sem hardcode.

import SwiftUI

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
        guard !caps.isEmpty else { return 20.0 }   // fallback ~H6 PHEV
        return caps.reduce(0, +) / Double(caps.count)
    }

    func compute(query: String, trips: [Trip]) async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !loading else { return }
        loading = true; error = nil; plan = nil
        defer { loading = false }

        let car = CarStore.shared
        guard car.hasGps else { error = "Sem sinal de GPS do carro ainda."; return }
        let lat = car.lat, lng = car.lng
        let curSoc = Int(car.socPct.rounded())
        let acOn = car.acEnable
        let tempOut = car.outsideTemp != 0 ? car.outsideTemp : 28

        guard let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(base)/api/route-plan?from_lat=\(lat)&from_lng=\(lng)&q=\(enc)") else {
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
}

func arrivalSocColor(_ soc: Int) -> Color {
    if soc < 30 { return DS.orange }
    if soc < 50 { return DS.yellow }
    return DS.green
}

struct ArrivalSheet: View {
    let trips: [Trip]
    @StateObject private var store = ArrivalStore()
    @State private var dest = ""
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    DSCard {
                        VStack(spacing: 12) {
                            TextField("Destino (endereço ou local)", text: $dest)
                                .focused($focused)
                                .textFieldStyle(.plain)
                                .padding(12)
                                .background(DS.panel2)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .submitLabel(.search)
                                .onSubmit { calc() }
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
            .onAppear { focused = true }
        }
    }

    private func calc() { focused = false; Task { await store.compute(query: dest, trips: trips) } }

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
            }
        }
    }
}
