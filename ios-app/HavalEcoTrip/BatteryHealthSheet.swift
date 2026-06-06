//  BatteryHealthSheet.swift
//  Tendência de saúde da bateria: estima a capacidade útil (kWh) de cada recarga
//  (energia / ganho de SOC) e mostra a evolução no tempo + degradação aproximada.
//  100% client-side, das recargas já sincronizadas.

import SwiftUI
import Charts

struct BatteryHealthSheet: View {
    let charges: [Charge]
    @Environment(\.dismiss) private var dismiss

    private struct Point: Identifiable { let id = UUID(); let date: Date; let cap: Double }

    // Capacidade por sessão = energia / (ΔSOC/100). Só sessões com ganho relevante.
    private var points: [Point] {
        charges.compactMap { c -> Point? in
            let gain = c.socEnd - c.socStart
            guard gain >= 15, c.kwh > 1 else { return nil }
            let cap = c.kwh / (gain / 100.0)
            guard cap > 8, cap < 60 else { return nil }
            return Point(date: c.date, cap: cap)
        }.sorted { $0.date < $1.date }
    }

    private var baseline: Double {
        let head = points.prefix(5); guard !head.isEmpty else { return 0 }
        return head.reduce(0) { $0 + $1.cap } / Double(head.count)
    }
    private var current: Double {
        let tail = points.suffix(5); guard !tail.isEmpty else { return 0 }
        return tail.reduce(0) { $0 + $1.cap } / Double(tail.count)
    }
    private var degradationPct: Double {
        guard baseline > 0, current > 0 else { return 0 }
        return max((baseline - current) / baseline * 100, 0)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if points.count < 3 {
                        DSCard {
                            Text("Ainda sem recargas suficientes pra estimar (precisa de algumas recargas com ganho de SOC ≥ 15%).")
                                .font(.callout).foregroundStyle(DS.muted)
                        }
                    } else {
                        HStack(spacing: 12) {
                            DSCard { metric("Capacidade atual", "\(Fmt.dec1(current)) kWh", DS.green) }
                            DSCard { metric("Degradação", "\(Fmt.dec1(degradationPct))%",
                                            degradationPct > 10 ? DS.orange : DS.muted) }
                        }
                        DSCard(title: "Capacidade útil por recarga", icon: "chart.xyaxis.line") {
                            Chart(points) { p in
                                LineMark(x: .value("Data", p.date), y: .value("kWh", p.cap))
                                    .foregroundStyle(DS.green)
                                PointMark(x: .value("Data", p.date), y: .value("kWh", p.cap))
                                    .foregroundStyle(DS.green.opacity(0.5))
                            }
                            .frame(height: 180)
                            .chartYScale(domain: .automatic(includesZero: false))
                        }
                        DSCard {
                            metric("Estimativa inicial", "\(Fmt.dec1(baseline)) kWh", DS.muted)
                        }
                    }
                    Text("Estimativa: capacidade = energia da recarga ÷ ganho de SOC. Valores variam com temperatura e taxa de carga — leia a TENDÊNCIA, não um ponto isolado.")
                        .font(.caption2).foregroundStyle(DS.muted).frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Saúde da bateria")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fechar") { dismiss() } } }
        }
    }

    @ViewBuilder private func metric(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(DS.muted)
            Text(value).font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.6)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
