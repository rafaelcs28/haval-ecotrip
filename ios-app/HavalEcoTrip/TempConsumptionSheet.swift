//  TempConsumptionSheet.swift
//  Consumo por temperatura: agrupa as viagens (elétricas) por faixa de temperatura
//  externa e mostra o consumo médio (kWh/100km) — quanto o frio/calor pesa.

import SwiftUI
import Charts

struct TempConsumptionSheet: View {
    let trips: [Trip]
    @Environment(\.dismiss) private var dismiss

    private struct Bucket: Identifiable {
        let id = UUID(); let label: String; let lo: Double; let hi: Double
        var cons: [Double] = []
        var avg: Double { cons.isEmpty ? 0 : cons.reduce(0, +) / Double(cons.count) }
        var n: Int { cons.count }
    }

    // Só viagens elétricas com temperatura e distância relevante (consumo confiável).
    private var rated: [Trip] {
        trips.filter { $0.fuelL < 0.05 && $0.distKm >= 2 && $0.outsideTemp != nil }
    }

    private var buckets: [Bucket] {
        var bs = [
            Bucket(label: "<15°", lo: -100, hi: 15),
            Bucket(label: "15–20°", lo: 15, hi: 20),
            Bucket(label: "20–25°", lo: 20, hi: 25),
            Bucket(label: "25–30°", lo: 25, hi: 30),
            Bucket(label: "≥30°", lo: 30, hi: 200),
        ]
        for t in rated {
            guard let temp = t.outsideTemp else { continue }
            if let i = bs.firstIndex(where: { temp >= $0.lo && temp < $0.hi }) {
                bs[i].cons.append(t.netKwh / t.distKm * 100)
            }
        }
        return bs.filter { $0.n > 0 }
    }

    // Faixa de referência (amena, 20–25°) pra comparar.
    private var baseline: Double? { buckets.first { $0.label == "20–25°" }?.avg }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if rated.count < 4 || buckets.count < 2 {
                        DSCard {
                            Text("Ainda sem dados suficientes. As viagens passam a registrar a temperatura agora — em alguns dias o gráfico aparece.")
                                .font(.callout).foregroundStyle(DS.muted).frame(maxWidth: .infinity).padding(.vertical, 10)
                        }
                    } else {
                        DSCard(title: "Consumo médio por faixa", icon: "thermometer.medium") {
                            Chart(buckets) { b in
                                BarMark(x: .value("Faixa", b.label), y: .value("kWh/100", b.avg))
                                    .foregroundStyle(barColor(b.avg))
                                    .annotation(position: .top) {
                                        Text(Fmt.dec1(b.avg)).font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.muted)
                                    }
                            }
                            .frame(height: 200)
                            .chartYScale(domain: .automatic(includesZero: true))
                        }
                        if let base = baseline, base > 0 {
                            DSCard {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Comparado à faixa amena (20–25°):").font(.caption).foregroundStyle(DS.muted)
                                    ForEach(buckets.filter { $0.label != "20–25°" }) { b in
                                        let diff = (b.avg - base) / base * 100
                                        HStack {
                                            Text(b.label).font(.subheadline).foregroundStyle(DS.text)
                                            Spacer()
                                            Text("\(diff >= 0 ? "+" : "")\(Int(diff.rounded()))%")
                                                .font(.subheadline.weight(.bold)).foregroundStyle(diff > 5 ? DS.orange : (diff < -5 ? DS.green : DS.muted))
                                            Text("· \(b.n) viagens").font(.caption2).foregroundStyle(DS.muted)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Text("Só viagens elétricas (sem gasolina) com temperatura registrada. Clima frio/quente costuma aumentar o consumo pela climatização e a bateria.")
                        .font(.caption2).foregroundStyle(DS.muted).frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Consumo × temperatura")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fechar") { dismiss() } } }
        }
    }

    private func barColor(_ v: Double) -> Color {
        guard let base = baseline, base > 0 else { return DS.teal }
        let d = (v - base) / base
        return d > 0.08 ? DS.orange : (d < -0.05 ? DS.green : DS.teal)
    }
}
