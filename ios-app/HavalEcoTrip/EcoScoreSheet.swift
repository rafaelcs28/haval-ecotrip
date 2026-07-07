//  EcoScoreSheet.swift
//  Eco-score: nota de eficiência por viagem (energia-equivalente kWh/100km),
//  média da semana vs anterior, sequência de dias na meta e recordes.
//  Estilo v2 (hero + panels DS).

import SwiftUI

enum Eco {
    static let goal = 70

    /// Nota 0–100 de CONDUÇÃO: usa o score do bridge (economia + suavidade:
    /// frenagem/aceleração brusca) quando disponível. Quando não, aplica a MESMA
    /// fórmula localmente (0,55·econ + 0,45·suavidade) — assumindo suavidade=100
    /// se a viagem ainda não tem telemetria de eventos bruscos gravada. Isso
    /// evita que viagens antigas com consumo alto (AC parado) virem nota 0.
    static func score(_ t: Trip) -> Int? {
        if let ds = t.driveScore { return ds }
        guard t.distKm >= 1 else { return nil }
        let eq = (t.netKwh + t.fuelL * 8.9) / t.distKm * 100
        let econ = max(0, min(100, 100 - (eq - 13.0) * (70.0 / 13.0)))
        let events = t.harshAcc + t.harshBrake
        let perKm = t.distKm > 0.5 ? Double(events) / t.distKm : 0
        let smooth = max(0, min(100, 100 - perKm * 18))
        return Int((0.55 * econ + 0.45 * smooth).rounded())
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
    @State private var detailTrip: Trip?

    private var now: Date { Date() }
    private var thisWeek: [Trip] { trips.filter { $0.date > now.addingTimeInterval(-7 * 86400) } }
    private var lastWeek: [Trip] { trips.filter { $0.date <= now.addingTimeInterval(-7 * 86400) && $0.date > now.addingTimeInterval(-14 * 86400) } }
    private var rated: [Trip] { trips.filter { Eco.score($0) != nil }.sorted { $0.date > $1.date } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    hero
                    weekCard
                    recordsCard
                    if !rated.isEmpty { tripsCard }
                    Text("Nota de condução: combina economia (consumo) com suavidade — penaliza acelerações e frenagens bruscas. Viagens antigas (sem telemetria de condução) usam só a economia.")
                        .font(.system(size: 10.5)).foregroundStyle(DS.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Condução")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fechar") { dismiss() } } }
            .sheet(item: $detailTrip) { t in DriveScoreDetailSheet(trip: t) }
            .task {
                #if DEBUG
                if UserDefaults.standard.integer(forKey: "v2_sheet") == 5, let t = rated.first {
                    try? await Task.sleep(for: .seconds(0.5)); detailTrip = t
                }
                #endif
            }
        }
        .presentationDetents([.large])
    }

    // Hero: nota de 7 dias como número gigante + meta e streak.
    private var hero: some View {
        let avg = Eco.avg(thisWeek) ?? Eco.avg(trips)
        let streak = streakDays()
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(avg.map(String.init) ?? "—")
                    .font(.system(size: 62, weight: .ultraLight)).tracking(-2)
                    .monospacedDigit().foregroundStyle(avg.map(Eco.color) ?? DS.muted)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text("nota de condução · 7 dias").font(.system(size: 11.5)).foregroundStyle(DS.text2)
            }
            Spacer(minLength: 10)
            VStack(alignment: .trailing, spacing: 3) {
                if let a = avg {
                    Text(a >= Eco.goal ? "na meta ✓" : "abaixo da meta")
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(a >= Eco.goal ? DS.green : DS.orange)
                    Text("meta \(Eco.goal)").font(.system(size: 11.5)).foregroundStyle(DS.text2)
                }
                if streak > 0 {
                    Text("\(streak) \(streak == 1 ? "dia" : "dias") na meta")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.orange)
                }
            }
        }
    }

    private var weekCard: some View {
        let tw = Eco.avg(thisWeek), lw = Eco.avg(lastWeek)
        return VStack(alignment: .leading, spacing: 10) {
            sectionLabel("SEMANA")
            HStack(spacing: 12) {
                weekCell("Esta semana", tw)
                weekCell("Anterior", lw)
                Spacer()
                if let a = tw, let b = lw {
                    let d = a - b
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(d >= 0 ? "+" : "")\(d)")
                            .font(.system(size: 18, weight: .bold)).monospacedDigit()
                            .foregroundStyle(d >= 0 ? DS.green : DS.orange)
                        Text(d >= 0 ? "melhor" : "pior").font(.system(size: 10)).foregroundStyle(DS.muted)
                    }
                }
            }
        }
        .modifier(V2Panel())
    }

    private func weekCell(_ label: String, _ v: Int?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(v.map(String.init) ?? "—")
                .font(.system(size: 20, weight: .bold)).monospacedDigit()
                .foregroundStyle(v.map(Eco.color) ?? DS.muted)
            Text(label).font(.system(size: 10)).foregroundStyle(DS.muted)
        }
    }

    private var recordsCard: some View {
        let best = rated.compactMap { Eco.score($0) }.max()
        // Melhor consumo: só viagens 100% EV, ≥5 km e consumo positivo (evita
        // híbrida/descida com netKwh negativo virarem "recorde").
        let bestEqTrip = rated
            .filter { $0.fuelL < 0.05 && $0.distKm >= 5 && $0.netKwh > 0 }
            .min { $0.netKwh / $0.distKm < $1.netKwh / $1.distKm }
        return VStack(alignment: .leading, spacing: 10) {
            sectionLabel("RECORDES")
            HStack(spacing: 14) {
                recordCell("Melhor nota", best.map(String.init) ?? "—", best.map(Eco.color) ?? DS.muted)
                Rectangle().fill(DS.border).frame(width: 1, height: 34)
                if let t = bestEqTrip {
                    Button { TripsLoader.shared.focusTripId = t.id; dismiss() } label: {
                        HStack(spacing: 4) {
                            recordCell("Melhor consumo", "\(Fmt.dec1(t.netKwh / t.distKm * 100)) kWh/100", DS.teal)
                            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(DS.muted)
                        }
                    }.buttonStyle(.plain)
                } else {
                    recordCell("Melhor consumo", "—", DS.muted)
                }
            }
        }
        .modifier(V2Panel())
    }

    private func recordCell(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 16, weight: .bold)).monospacedDigit().foregroundStyle(color)
            Text(label).font(.system(size: 10)).foregroundStyle(DS.muted)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tripsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("POR VIAGEM").padding(.bottom, 6)
            ForEach(rated.prefix(20)) { t in
                let s = Eco.score(t) ?? 0
                Button { detailTrip = t } label: {
                    HStack(spacing: 10) {
                        Text("\(s)")
                            .font(.system(size: 17, weight: .bold)).monospacedDigit()
                            .foregroundStyle(Eco.color(s)).frame(width: 34, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(name(t)).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(DS.text).lineLimit(1)
                            HStack(spacing: 6) {
                                Text("\(Fmt.km(t.distKm)) km · \(Fmt.dec1(t.netKwh)) kWh")
                                    .font(.system(size: 11)).foregroundStyle(DS.text2)
                                if t.driveScore != nil && (t.harshAcc + t.harshBrake) > 0 {
                                    Text("· ⚡\(t.harshAcc) 🛑\(t.harshBrake)").font(.system(size: 11)).foregroundStyle(DS.orange)
                                }
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(DS.muted)
                    }.padding(.vertical, 9).contentShape(Rectangle())
                }.buttonStyle(.plain)
                if t.id != rated.prefix(20).last?.id { Rectangle().fill(DS.divider).frame(height: 1) }
            }
        }
        .modifier(V2Panel())
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

// MARK: - estilo v2 compartilhado pelos sheets de insights

func sectionLabel(_ s: String) -> some View {
    Text(s).font(.system(size: 8.5, weight: .bold)).foregroundStyle(DS.muted).tracking(1)
}

struct V2Panel: ViewModifier {
    var accent: Color? = nil
    func body(content: Content) -> some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.panel, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(accent ?? DS.border, lineWidth: 1))
    }
}
