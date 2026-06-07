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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(items) { card($0) }
                    Text("Quilometragem vem do odômetro do carro; km elétrico e viagens das suas viagens sincronizadas.")
                        .font(.caption2).foregroundStyle(DS.muted).frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Marcos do carro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fechar") { dismiss() } } }
        }
    }

    @ViewBuilder private func card(_ a: Achievement) -> some View {
        DSCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: a.icon).foregroundStyle(a.color)
                    Text(a.title).font(.subheadline.weight(.semibold)).foregroundStyle(DS.text)
                    Spacer()
                    Text(a.unit == "km" ? "\(Fmt.int(a.current)) km" : "\(Int(a.current))")
                        .font(.headline).foregroundStyle(a.color)
                }
                if let nx = a.next {
                    ProgressView(value: max(0, min(1, a.progress))).tint(a.color)
                    Text("faltam \(Fmt.int(nx - a.current)) \(a.unit.isEmpty ? "" : a.unit) pro próximo: \(Fmt.int(nx))\(a.unit.isEmpty ? "" : " " + a.unit)")
                        .font(.caption2).foregroundStyle(DS.muted)
                } else {
                    Text("todos os marcos atingidos 🎉").font(.caption).foregroundStyle(DS.green)
                }
                if !a.achieved.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(a.achieved, id: \.self) { t in
                                Text("✓ \(Fmt.int(t))\(a.unit.isEmpty ? "" : " " + a.unit)")
                                    .font(.caption2.weight(.semibold)).foregroundStyle(a.color)
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
