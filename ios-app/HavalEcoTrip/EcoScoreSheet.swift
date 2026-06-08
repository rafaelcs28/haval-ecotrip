//  EcoScoreSheet.swift
//  Eco-score: nota de eficiência por viagem (energia-equivalente kWh/100km),
//  média da semana vs anterior, sequência de dias na meta e recordes.

import SwiftUI

enum Eco {
    static let goal = 70

    /// Nota 0–100 de CONDUÇÃO: usa o score do bridge (economia + suavidade:
    /// frenagem/aceleração brusca) quando disponível; senão cai na economia pura.
    static func score(_ t: Trip) -> Int? {
        if let ds = t.driveScore { return ds }
        guard t.distKm >= 1 else { return nil }
        let eq = (t.netKwh + t.fuelL * 8.9) / t.distKm * 100
        let s = 100.0 - (eq - 13.0) * (70.0 / 13.0)
        return Int(min(100, max(0, s)).rounded())
    }
    static func avg(_ trips: [Trip]) -> Int? {
        let s = trips.compactMap { score($0) }
        return s.isEmpty ? nil : s.reduce(0, +) / s.count
    }
    static func color(_ s: Int) -> Color { s >= 80 ? DS.green : (s >= 60 ? DS.yellow : DS.orange) }
}

struct EcoScoreSheet: View {
    let trips: [Trip]
    @Environment(\.dismiss) private var dismiss

    private var now: Date { Date() }
    private var thisWeek: [Trip] { trips.filter { $0.date > now.addingTimeInterval(-7 * 86400) } }
    private var lastWeek: [Trip] { trips.filter { $0.date <= now.addingTimeInterval(-7 * 86400) && $0.date > now.addingTimeInterval(-14 * 86400) } }
    private var rated: [Trip] { trips.filter { Eco.score($0) != nil }.sorted { $0.date > $1.date } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    headerCard
                    weekCard
                    recordsCard
                    if !rated.isEmpty { tripsCard }
                    Text("Nota de condução: combina economia (consumo) com suavidade — penaliza acelerações e frenagens bruscas. Viagens antigas (sem telemetria de condução) usam só a economia.")
                        .font(.caption2).foregroundStyle(DS.muted).frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Condução")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fechar") { dismiss() } } }
        }
    }

    private var headerCard: some View {
        let avg = Eco.avg(thisWeek) ?? Eco.avg(trips)
        let streak = streakDays()
        return DSCard {
            VStack(spacing: 10) {
                Text("Nota de condução (7 dias)").font(.caption).foregroundStyle(DS.muted)
                if let a = avg {
                    Text("\(a)").font(.system(size: 66, weight: .heavy, design: .rounded)).foregroundStyle(Eco.color(a))
                    Text("meta \(Eco.goal) · \(a >= Eco.goal ? "na meta ✓" : "abaixo da meta")")
                        .font(.subheadline).foregroundStyle(a >= Eco.goal ? DS.green : DS.muted)
                } else {
                    Text("—").font(.system(size: 66, weight: .heavy, design: .rounded)).foregroundStyle(DS.muted)
                    Text("sem viagens suficientes ainda").font(.subheadline).foregroundStyle(DS.muted)
                }
                if streak > 0 {
                    Label("\(streak) \(streak == 1 ? "dia" : "dias") seguidos na meta 🔥", systemImage: "flame.fill")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(DS.orange)
                }
            }.frame(maxWidth: .infinity).padding(.vertical, 6)
        }
    }

    private var weekCard: some View {
        let tw = Eco.avg(thisWeek), lw = Eco.avg(lastWeek)
        return DSCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Semana").font(.caption).foregroundStyle(DS.muted)
                HStack(spacing: 12) {
                    weekCell("Esta semana", tw)
                    weekCell("Anterior", lw)
                    Spacer()
                    if let a = tw, let b = lw {
                        let d = a - b
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("\(d >= 0 ? "+" : "")\(d)").font(.title3.weight(.bold)).foregroundStyle(d >= 0 ? DS.green : DS.orange)
                            Text(d >= 0 ? "melhor" : "pior").font(.caption2).foregroundStyle(DS.muted)
                        }
                    }
                }
            }
        }
    }

    private func weekCell(_ label: String, _ v: Int?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(v.map(String.init) ?? "—").font(.title2.weight(.bold)).foregroundStyle(v.map(Eco.color) ?? DS.muted)
            Text(label).font(.caption2).foregroundStyle(DS.muted)
        }
    }

    private var recordsCard: some View {
        let best = rated.compactMap { Eco.score($0) }.max()
        let bestEq = rated.map { ($0.netKwh + $0.fuelL * 8.9) / $0.distKm * 100 }.min()
        return DSCard {
            HStack(spacing: 14) {
                recordCell("Melhor nota", best.map(String.init) ?? "—", best.map(Eco.color) ?? DS.muted)
                Divider().frame(height: 34).overlay(DS.border)
                recordCell("Melhor consumo", bestEq.map { "\(Fmt.dec1($0)) kWh/100" } ?? "—", DS.teal)
            }
        }
    }

    private func recordCell(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.headline).foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(DS.muted)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tripsCard: some View {
        DSCard {
            VStack(spacing: 0) {
                ForEach(rated.prefix(20)) { t in
                    let s = Eco.score(t) ?? 0
                    HStack(spacing: 10) {
                        Text("\(s)").font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(Eco.color(s)).frame(width: 38, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(name(t)).font(.subheadline).foregroundStyle(DS.text).lineLimit(1)
                            HStack(spacing: 6) {
                                Text("\(Fmt.km(t.distKm)) km · \(Fmt.dec1(t.netKwh)) kWh").font(.caption2).foregroundStyle(DS.muted)
                                if t.driveScore != nil && (t.harshAcc + t.harshBrake) > 0 {
                                    Text("· ⚡\(t.harshAcc) 🛑\(t.harshBrake)").font(.caption2).foregroundStyle(DS.orange)
                                }
                            }
                        }
                        Spacer()
                    }.padding(.vertical, 8)
                    if t.id != rated.prefix(20).last?.id { Divider().background(DS.border) }
                }
            }
        }
    }

    private func name(_ t: Trip) -> String {
        if let n = t.rawName { return n }
        if let a = t.knownStart, let b = t.knownEnd { return "\(a) → \(b)" }
        return t.knownEnd ?? "Viagem"
    }

    // Dias-com-viagem consecutivos (do mais recente) com média >= meta.
    private func streakDays() -> Int {
        let cal = Calendar.current
        var byDay: [Date: [Int]] = [:]
        for t in trips { if let s = Eco.score(t) { byDay[cal.startOfDay(for: t.date), default: []].append(s) } }
        var n = 0
        for d in byDay.keys.sorted(by: >) {
            let arr = byDay[d]!
            if arr.reduce(0, +) / arr.count >= Eco.goal { n += 1 } else { break }
        }
        return n
    }
}
