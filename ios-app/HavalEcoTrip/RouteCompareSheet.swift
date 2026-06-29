//  RouteCompareSheet.swift
//  Trajetos recorrentes: agrupa viagens pelo par origem→destino e mostra
//  frequência, médias (km, tempo, consumo) e tendência (recente vs antigo).

import SwiftUI
import CoreLocation

struct RouteCompareSheet: View {
    let trips: [Trip]
    var priceKwh: Double = 0
    var priceGas: Double = 0
    var kmPerLGas: Double = 0
    @Environment(\.dismiss) private var dismiss

    // Mesmas premissas do resto do app (economiaValue, InsightsSheet): SUV
    // gasolina a kmPerL real (fallback 11 km/L) e gasolina a R$/L real (fallback 6).
    private var gasL: Double { priceGas > 0 ? priceGas : 6.0 }
    private var baselineKmL: Double { kmPerLGas > 1 ? kmPerLGas : 11 }

    private struct RouteGroup: Identifiable {
        let id = UUID()
        let name: String
        let trips: [Trip]
        var n: Int { trips.count }
        var avgKm: Double { trips.reduce(0) { $0 + $1.distKm } / Double(n) }
        var avgMin: Double { trips.reduce(0) { $0 + $1.timeSec } / Double(n) / 60 }
        var avgCons: Double {
            let v = trips.filter { $0.distKm > 0.5 }.map { $0.netKwh / $0.distKm * 100 }
            return v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count)
        }
        // Tendência de consumo: média da metade recente vs metade antiga (kWh/100).
        var trend: Double {
            let sorted = trips.filter { $0.distKm > 0.5 }.sorted { $0.date < $1.date }
            guard sorted.count >= 4 else { return 0 }
            let half = sorted.count / 2
            let old = sorted.prefix(half), new = sorted.suffix(half)
            let co = old.reduce(0.0) { $0 + $1.netKwh / $1.distKm * 100 } / Double(old.count)
            let cn = new.reduce(0.0) { $0 + $1.netKwh / $1.distKm * 100 } / Double(new.count)
            return cn - co   // negativo = melhorando (consome menos)
        }
    }

    private func key(_ t: Trip) -> String {
        func place(_ known: String?, _ c: CLLocationCoordinate2D?) -> String {
            if let k = known, !k.isEmpty { return k }
            if let c = c { return String(format: "%.3f,%.3f", c.latitude, c.longitude) }
            return "?"
        }
        return place(t.knownStart, t.startCoord) + " → " + place(t.knownEnd, t.endCoord)
    }

    private var groups: [RouteGroup] {
        var map: [String: [Trip]] = [:]
        for t in trips where t.distKm > 0.3 { map[key(t), default: []].append(t) }
        return map.filter { $0.value.count >= 2 }
            .map { RouteGroup(name: $0.key, trips: $0.value) }
            .sorted { $0.n > $1.n }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if groups.isEmpty {
                        DSCard { Text("Ainda não há trajetos repetidos suficientes (precisa de 2+ viagens no mesmo origem→destino).").font(.callout).foregroundStyle(DS.muted).frame(maxWidth: .infinity).padding(.vertical, 10) }
                    } else {
                        ForEach(groups) { g in groupCard(g) }
                    }
                }
                .padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Trajetos recorrentes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fechar") { dismiss() } } }
        }
    }

    @ViewBuilder private func groupCard(_ g: RouteGroup) -> some View {
        DSCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(g.name).font(.subheadline.weight(.semibold)).foregroundStyle(DS.text).lineLimit(2)
                    Spacer()
                    Text("\(g.n)×").font(.subheadline.weight(.bold)).foregroundStyle(DS.teal)
                }
                HStack(spacing: 14) {
                    miniMetric(Fmt.km(g.avgKm), "km méd.", DS.blue)
                    miniMetric("\(Int(g.avgMin.rounded())) min", "tempo méd.", DS.text)
                    miniMetric("\(Fmt.dec1(g.avgCons))", "kWh/100", DS.green)
                    Spacer()
                    if abs(g.trend) >= 0.5 {
                        let better = g.trend < 0
                        HStack(spacing: 3) {
                            Image(systemName: better ? "arrow.down.right" : "arrow.up.right").font(.caption2)
                            Text("\(Fmt.dec1(abs(g.trend)))").font(.caption.weight(.semibold))
                        }.foregroundStyle(better ? DS.green : DS.orange)
                    }
                }
                costRow(g)
            }
        }
    }

    // Custo médio real (kWh + combustível) vs se o mesmo trajeto rodasse 100%
    // gasolina (km / baseline km·L × R$/L). savedPct = quanto o híbrido economiza.
    @ViewBuilder private func costRow(_ g: RouteGroup) -> some View {
        let real = g.trips.reduce(0.0) { $0 + $1.netKwh * priceKwh + $1.fuelL * gasL } / Double(g.n)
        let gas  = g.trips.reduce(0.0) { $0 + ($1.distKm / baselineKmL) * gasL } / Double(g.n)
        let savedPct = gas > 0.01 ? Int(((gas - real) / gas * 100).rounded()) : 0
        Divider().overlay(DS.muted.opacity(0.25))
        HStack(spacing: 14) {
            miniMetric(Fmt.brl(real), "custo méd.", DS.text)
            miniMetric(Fmt.brl(gas), "se gasolina", DS.orange)
            Spacer()
            if savedPct != 0 {
                let saving = savedPct > 0
                HStack(spacing: 3) {
                    Image(systemName: saving ? "leaf.fill" : "exclamationmark.triangle.fill").font(.caption2)
                    Text("\(saving ? "−" : "+")\(abs(savedPct))%").font(.caption.weight(.bold))
                }.foregroundStyle(saving ? DS.green : DS.orange)
            }
        }
    }

    private func miniMetric(_ v: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(v).font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(color)
            Text(label).font(.system(size: 9)).foregroundStyle(DS.muted)
        }
    }
}
