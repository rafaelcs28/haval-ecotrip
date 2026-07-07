//  MilestonesSheet.swift
//  Marcos do carro: odômetro, km elétricos acumulados e nº de viagens, com
//  conquistas atingidas e o próximo alvo (barra de progresso).

import SwiftUI

struct MilestonesSheet: View {
    let odometerKm: Double
    let trips: [Trip]
    @Environment(\.dismiss) private var dismiss

    private var evKm: Double { trips.filter { $0.fuelL < 0.05 }.reduce(0) { $0 + $1.distKm } }
    private var tripCount: Int { trips.filter { $0.distKm > 0.3 }.count }

    private struct Achievement: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let value: Double          // valor atual
        let tiers: [Double]
        let unit: String
        let color: Color
        var current: Double { value }
        var achieved: [Double] { tiers.filter { value >= $0 } }
        var next: Double? { tiers.first { value < $0 } }
        var progress: Double {
            guard let nx = next else { return 1 }
            let prev = achieved.last ?? 0
            return (value - prev) / (nx - prev)
        }
        var lastAchieved: Double? { achieved.last }
    }

    private var items: [Achievement] {
        [
            Achievement(icon: "road.lanes", title: "Quilometragem", value: odometerKm,
                        tiers: [1000, 5000, 10000, 25000, 50000, 100000], unit: "km", color: DS.blue),
            Achievement(icon: "bolt.car", title: "Km no elétrico", value: evKm,
                        tiers: [500, 1000, 5000, 10000, 25000], unit: "km", color: DS.green),
            Achievement(icon: "car.2", title: "Viagens", value: Double(tripCount),
                        tiers: [10, 50, 100, 250, 500, 1000], unit: "", color: DS.teal),
        ]
    }

    // Marco mais alto já atingido em qualquer categoria — o "novo" em destaque.
    private var latest: (a: Achievement, tier: Double)? {
        items.compactMap { a in a.lastAchieved.map { (a, $0) } }.max { ($0.1) < ($1.1) }
    }

    private func fmtTier(_ v: Double, _ unit: String) -> String {
        unit.isEmpty ? Fmt.int(v) : "\(Fmt.int(v)) \(unit)"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if let l = latest {
                        hero(l.a, l.tier)
                        ShareLink(item: "Marco no meu Haval: \(fmtTier(l.tier, l.a.unit)) · \(l.a.title.lowercased())") {
                            Label("Compartilhar cartão do marco", systemImage: "square.and.arrow.up")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(maxWidth: .infinity).frame(height: 42)
                                .foregroundStyle(DS.green)
                                .background(DS.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(DS.green.opacity(0.28), lineWidth: 1))
                        }
                    }
                    ForEach(items) { card($0) }
                    Text("Quilometragem vem do odômetro do carro; km elétrico e viagens das suas viagens sincronizadas.")
                        .font(.system(size: 10.5)).foregroundStyle(DS.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Marcos do carro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fechar") { dismiss() } } }
        }
        .presentationDetents([.large])
    }

    // Cartão celebratório do marco mais alto atingido (gradiente verde + glifo).
    @ViewBuilder private func hero(_ a: Achievement, _ tier: Double) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill").font(.system(size: 15, weight: .bold)).foregroundStyle(.black)
                Text("Marco alcançado").font(.system(size: 13, weight: .bold)).foregroundStyle(.black)
                Spacer()
                Text("novo")
                    .font(.system(size: 11, weight: .heavy)).foregroundStyle(.black)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Color.black.opacity(0.18)).clipShape(Capsule())
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Fmt.int(tier)).font(.system(size: 46, weight: .ultraLight, design: .rounded))
                    .monospacedDigit().foregroundStyle(.black)
                if !a.unit.isEmpty {
                    Text(a.unit).font(.system(size: 18, weight: .semibold)).foregroundStyle(.black.opacity(0.7))
                }
            }
            Text("\(a.title.lowercased()) · alcançado")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.black.opacity(0.75))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.greenGrad)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder private func card(_ a: Achievement) -> some View {
        DSCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: a.icon).foregroundStyle(a.color)
                    Text(a.title).font(.subheadline.weight(.semibold)).foregroundStyle(DS.text)
                    Spacer()
                    Text(a.unit == "km" ? "\(Fmt.int(a.current)) km" : "\(Int(a.current))")
                        .font(.headline).foregroundStyle(a.color).monospacedDigit()
                }
                if let nx = a.next {
                    ProgressView(value: max(0, min(1, a.progress))).tint(a.color)
                    HStack {
                        Text(fmtTier(nx, a.unit)).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.text2)
                        Spacer()
                        Text("faltam \(fmtTier(nx - a.current, a.unit))")
                            .font(.system(size: 11)).foregroundStyle(DS.muted)
                    }
                } else {
                    Text("todos os marcos atingidos").font(.caption).foregroundStyle(DS.green)
                }
                if !a.achieved.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(a.achieved, id: \.self) { t in
                                HStack(spacing: 4) {
                                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                                    Text(fmtTier(t, a.unit)).font(.caption2.weight(.semibold))
                                }
                                .foregroundStyle(a.color)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(a.color.opacity(0.14)).clipShape(Capsule())
                            }
                        }
                    }
                }
            }
        }
    }
}
