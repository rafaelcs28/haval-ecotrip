//  DriveScoreDetailSheet.swift
//  Composição da nota de condução de uma viagem: mostra como economia (55%) e
//  suavidade (45%) somam pra nota final, conta acelerações/frenagens bruscas e
//  — se a telemetria estiver em cache — também tempo parado vs movimento.
//  Estilo v2 (hero + panels DS).

import SwiftUI

struct DriveScoreDetailSheet: View {
    let trip: Trip
    @Environment(\.dismiss) private var dismiss
    @State private var samples: [(t: Double, spd: Double)] = []
    @State private var loadedTraj = false

    // Reproduz a fórmula do bridge (server.js: computeDriveScore) pra que o usuário
    // entenda como a nota é composta. eq = kWh-eq por 100km (referência 13 → 70 pts).
    private var eq: Double? {
        guard trip.distKm >= 1 else { return nil }
        return (trip.netKwh + trip.fuelL * 8.9) / trip.distKm * 100
    }
    private var econ: Double {
        guard let eq else { return 70 }
        return max(0, min(100, 100 - (eq - 13) * (70.0 / 13.0)))
    }
    private var eventsPerKm: Double {
        trip.distKm > 0.5 ? Double(trip.harshAcc + trip.harshBrake) / trip.distKm : 0
    }
    private var smooth: Double { max(0, min(100, 100 - eventsPerKm * 18)) }
    private var computed: Int { Int((0.55 * econ + 0.45 * smooth).rounded()) }
    private var displayed: Int { trip.driveScore ?? computed }
    private var isEstimated: Bool { trip.driveScore == nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    hero
                    breakdownCard
                    eventsCard
                    if loadedTraj { motionCard }
                    formulaCard
                }
                .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Composição da nota")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fechar") { dismiss() } } }
            .task { await loadSamples() }
        }
        .presentationDetents([.large])
    }

    private var hero: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(displayed)")
                    .font(.system(size: 62, weight: .ultraLight)).tracking(-2)
                    .monospacedDigit().foregroundStyle(Eco.color(displayed))
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(tripName).font(.system(size: 11.5)).foregroundStyle(DS.text2).lineLimit(1)
            }
            Spacer(minLength: 10)
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(Fmt.km(trip.distKm)) km").font(.system(size: 12, weight: .bold)).monospacedDigit().foregroundStyle(DS.text)
                Text("\(Fmt.dec1(trip.netKwh)) kWh").font(.system(size: 11.5)).foregroundStyle(DS.text2)
                if isEstimated {
                    Text("estimada").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.orange)
                }
            }
        }
    }

    private var breakdownCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("COMPOSIÇÃO")
            componentRow(label: "Economia", weight: "55%", value: Int(econ.rounded()),
                         detail: eq.map { "\(Fmt.dec1($0)) kWh-eq/100km" } ?? "sem economia (viagem curta)")
            componentRow(label: "Suavidade", weight: "45%", value: Int(smooth.rounded()),
                         detail: trip.distKm > 0.5
                            ? "\(Fmt.dec1(eventsPerKm)) eventos/km · \(trip.harshAcc + trip.harshBrake) ao todo"
                            : "sem dados (viagem curta)")
            if !isEstimated && computed != displayed {
                Text("Bridge gravou \(displayed); recomputada localmente daria \(computed).")
                    .font(.system(size: 10.5)).foregroundStyle(DS.muted)
            }
        }
        .modifier(V2Panel())
    }

    private func componentRow(label: String, weight: String, value: Int, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(DS.text)
                Text(weight).font(.system(size: 10)).foregroundStyle(DS.muted)
                Spacer()
                Text("\(value)").font(.system(size: 14, weight: .bold)).monospacedDigit().foregroundStyle(Eco.color(value))
                Text("/100").font(.system(size: 10)).foregroundStyle(DS.muted)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.panel2).frame(height: 6)
                    Capsule().fill(Eco.color(value))
                        .frame(width: max(4, geo.size.width * CGFloat(value) / 100), height: 6)
                }
            }.frame(height: 6)
            Text(detail).font(.system(size: 10.5)).foregroundStyle(DS.muted)
        }
    }

    private var eventsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("EVENTOS BRUSCOS")
            HStack(spacing: 12) {
                eventCell(icon: "bolt.fill", color: DS.orange, value: "\(trip.harshAcc)", label: "Acelerações")
                eventCell(icon: "octagon.fill", color: DS.red, value: "\(trip.harshBrake)", label: "Frenagens")
                eventCell(icon: "ruler", color: DS.muted, value: trip.distKm > 0.5 ? Fmt.dec1(eventsPerKm) : "—", label: "Por km")
            }
            Text("Acelerações > ~2,5 m/s² e frenagens < ~−3,0 m/s².")
                .font(.system(size: 10.5)).foregroundStyle(DS.muted)
        }
        .modifier(V2Panel())
    }

    private func eventCell(icon: String, color: Color, value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Image(systemName: icon).foregroundStyle(color).font(.system(size: 13))
            Text(value).font(.system(size: 18, weight: .bold)).monospacedDigit().foregroundStyle(DS.text)
            Text(label).font(.system(size: 10)).foregroundStyle(DS.muted)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var motionCard: some View {
        let (moving, stopped, avg) = motionStats()
        let total = max(1, moving + stopped)
        let stoppedPct = Int((stopped / total * 100).rounded())
        return VStack(alignment: .leading, spacing: 10) {
            sectionLabel("MOVIMENTO")
            HStack(spacing: 12) {
                eventCell(icon: "play.fill", color: DS.green, value: fmtHMS(moving), label: "Em movimento")
                eventCell(icon: "pause.fill", color: DS.orange, value: fmtHMS(stopped), label: "Parado (\(stoppedPct)%)")
                eventCell(icon: "speedometer", color: DS.text, value: avg > 0 ? "\(Fmt.adjSpeed(avg))" : "—", label: "km/h médios")
            }
            Text("Tempo parado não pesa direto na nota, mas afeta a economia (AC em marcha lenta).")
                .font(.system(size: 10.5)).foregroundStyle(DS.muted)
        }
        .modifier(V2Panel())
    }

    private var formulaCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("COMO A NOTA É CALCULADA")
            Text("nota = 0,55 · economia + 0,45 · suavidade")
                .font(.system(size: 12).monospaced()).foregroundStyle(DS.text)
            Text("Economia parte de 100 e cai conforme o consumo (kWh-eq/100km) afasta de 13. Suavidade parte de 100 e perde ~18 pontos a cada evento brusco por km.")
                .font(.system(size: 10.5)).foregroundStyle(DS.muted)
        }
        .modifier(V2Panel())
    }

    private var tripName: String {
        if let n = trip.rawName { return n }
        if let a = trip.knownStart, let b = trip.knownEnd { return "\(a) → \(b)" }
        return trip.knownEnd ?? "Viagem"
    }

    private func motionStats() -> (moving: Double, stopped: Double, avg: Double) {
        guard samples.count > 1 else { return (0, 0, 0) }
        var mv = 0.0, st = 0.0, sumSpd = 0.0, nMv = 0
        for i in 1..<samples.count {
            let dt = samples[i].t - samples[i - 1].t
            guard dt > 0 && dt < 30 else { continue }
            let s = samples[i].spd
            if s > 3 { mv += dt; sumSpd += s; nMv += 1 } else { st += dt }
        }
        return (mv, st, nMv > 0 ? sumSpd / Double(nMv) : 0)
    }

    private func fmtHMS(_ sec: Double) -> String {
        let s = max(0, Int(sec.rounded()))
        let h = s / 3600, m = (s % 3600) / 60
        if h > 0 { return "\(h)h \(m)min" }
        return "\(m) min"
    }

    private func loadSamples() async {
        guard let data = OfflineCache.loadTraj(trip.tripId),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["samples"] as? [[String: Any]] else { return }
        var out: [(Double, Double)] = []
        out.reserveCapacity(raw.count)
        for s in raw { out.append((num(s["t"]), num(s["spd"]))) }
        samples = out
        loadedTraj = out.count > 1
    }

    private func num(_ v: Any?) -> Double {
        switch v {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s) ?? 0
        default: return 0
        }
    }
}
