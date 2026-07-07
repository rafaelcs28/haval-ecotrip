//  RouteCompareSheet.swift
//  Trajetos recorrentes: agrupa viagens pelo par origem→destino e mostra
//  frequência, médias (km, tempo, consumo) e tendência (recente vs antigo).
//  Estilo v2 (hero + panels DS).

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

    private var totalRepeats: Int { groups.reduce(0) { $0 + $1.n } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if groups.isEmpty {
                        emptyCard
                    } else {
                        hero
                        ForEach(groups) { g in groupCard(g) }
                    }
                }
                .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Trajetos recorrentes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fechar") { dismiss() } } }
        }
        .presentationDetents([.large])
    }

    private var hero: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(groups.count)")
                    .font(.system(size: 62, weight: .ultraLight)).tracking(-2)
                    .monospacedDigit().foregroundStyle(DS.teal)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text("trajetos repetidos").font(.system(size: 11.5)).foregroundStyle(DS.text2)
            }
            Spacer(minLength: 10)
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(totalRepeats) viagens").font(.system(size: 12, weight: .bold)).monospacedDigit().foregroundStyle(DS.text)
                Text("no total").font(.system(size: 11.5)).foregroundStyle(DS.text2)
            }
        }
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("TRAJETOS RECORRENTES")
            Text("Ainda não há trajetos repetidos suficientes (precisa de 2+ viagens no mesmo origem→destino).")
                .font(.system(size: 12)).foregroundStyle(DS.muted)
        }
        .modifier(V2Panel())
    }

    @ViewBuilder private func groupCard(_ g: RouteGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(g.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(DS.text).lineLimit(2)
                Spacer(minLength: 8)
                Text("\(g.n)×").font(.system(size: 15, weight: .bold)).monospacedDigit().foregroundStyle(DS.teal)
            }
            HStack(spacing: 12) {
                metric(Fmt.km(g.avgKm), "km méd.", DS.blue)
                metric("\(Int(g.avgMin.rounded())) min", "tempo méd.", DS.text)
                metric(Fmt.dec1(g.avgCons), "kWh/100", DS.green)
                if abs(g.trend) >= 0.5 {
                    let better = g.trend < 0
                    trendCell(better: better, value: Fmt.dec1(abs(g.trend)))
                }
            }
            costRow(g)
        }
        .modifier(V2Panel())
    }

    // Custo médio real (kWh + combustível) vs se o mesmo trajeto rodasse 100%
    // gasolina (km / baseline km·L × R$/L). savedPct = quanto o híbrido economiza.
    @ViewBuilder private func costRow(_ g: RouteGroup) -> some View {
        let real = g.trips.reduce(0.0) { $0 + $1.netKwh * priceKwh + $1.fuelL * gasL } / Double(g.n)
        let gas  = g.trips.reduce(0.0) { $0 + ($1.distKm / baselineKmL) * gasL } / Double(g.n)
        let savedPct = gas > 0.01 ? Int(((gas - real) / gas * 100).rounded()) : 0
        Rectangle().fill(DS.divider).frame(height: 1)
        HStack(spacing: 12) {
            metric(Fmt.brl(real), "custo méd.", DS.text)
            metric(Fmt.brl(gas), "se gasolina", DS.orange)
            if savedPct != 0 {
                let saving = savedPct > 0
                VStack(alignment: .leading, spacing: 3) {
                    Image(systemName: saving ? "leaf.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(saving ? DS.green : DS.orange).font(.system(size: 13))
                    Text("\(saving ? "−" : "+")\(abs(savedPct))%")
                        .font(.system(size: 18, weight: .bold)).monospacedDigit()
                        .foregroundStyle(saving ? DS.green : DS.orange)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func metric(_ v: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(v).font(.system(size: 18, weight: .bold)).monospacedDigit().foregroundStyle(color)
            Text(label).font(.system(size: 10)).foregroundStyle(DS.muted)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func trendCell(better: Bool, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Image(systemName: better ? "arrow.down.right" : "arrow.up.right")
                .foregroundStyle(better ? DS.green : DS.orange).font(.system(size: 13))
            Text(value).font(.system(size: 18, weight: .bold)).monospacedDigit()
                .foregroundStyle(better ? DS.green : DS.orange)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
