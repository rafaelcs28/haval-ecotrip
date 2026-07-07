//  TempConsumptionSheet.swift
//  Consumo por temperatura: agrupa as viagens (elétricas) por faixa de temperatura
//  externa e mostra o consumo médio (kWh/100km) — quanto o frio/calor pesa.
//  Estilo v2 (hero + panels DS + barras próprias).

import SwiftUI

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
    private var maxAvg: Double { max(0.1, buckets.map(\.avg).max() ?? 0.1) }
    private var hasData: Bool { rated.count >= 4 && buckets.count >= 2 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !hasData {
                        emptyCard
                    } else {
                        hero
                        chartCard
                        if let base = baseline, base > 0 { comparisonCard(base) }
                    }
                    Text("Só viagens elétricas (sem gasolina) com temperatura registrada. Clima frio/quente costuma aumentar o consumo pela climatização e a bateria.")
                        .font(.system(size: 10.5)).foregroundStyle(DS.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Consumo × temperatura")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fechar") { dismiss() } } }
        }
        .presentationDetents([.large])
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("CONSUMO × TEMPERATURA")
            Text("Ainda sem dados suficientes. As viagens passam a registrar a temperatura agora — em alguns dias o gráfico aparece.")
                .font(.system(size: 12)).foregroundStyle(DS.muted)
        }
        .modifier(V2Panel())
    }

    private var hero: some View {
        // Extremo: faixa com maior consumo vs baseline amena.
        let worst = buckets.max { $0.avg < $1.avg }
        let base = baseline
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                if let w = worst, let b = base, b > 0 {
                    let diff = Int(((w.avg - b) / b * 100).rounded())
                    Text("\(diff >= 0 ? "+" : "")\(diff)%")
                        .font(.system(size: 62, weight: .ultraLight)).tracking(-2)
                        .monospacedDigit().foregroundStyle(diff > 5 ? DS.orange : DS.green)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text("pior faixa (\(w.label)) vs amena").font(.system(size: 11.5)).foregroundStyle(DS.text2)
                } else {
                    Text("\(Fmt.dec1(worst?.avg ?? 0))")
                        .font(.system(size: 62, weight: .ultraLight)).tracking(-2)
                        .monospacedDigit().foregroundStyle(DS.teal)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text("kWh/100 · pior faixa").font(.system(size: 11.5)).foregroundStyle(DS.text2)
                }
            }
            Spacer(minLength: 10)
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(rated.count) viagens").font(.system(size: 12, weight: .bold)).monospacedDigit().foregroundStyle(DS.text)
                Text("com temperatura").font(.system(size: 11.5)).foregroundStyle(DS.text2)
            }
        }
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("CONSUMO MÉDIO POR FAIXA")
            ForEach(buckets) { b in
                HStack(spacing: 10) {
                    Text(b.label).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(DS.text)
                        .frame(width: 52, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(DS.panel2).frame(height: 18)
                            Capsule().fill(barColor(b.avg))
                                .frame(width: max(6, geo.size.width * CGFloat(b.avg / maxAvg)), height: 18)
                        }
                    }.frame(height: 18)
                    Text(Fmt.dec1(b.avg)).font(.system(size: 13, weight: .bold)).monospacedDigit()
                        .foregroundStyle(barColor(b.avg)).frame(width: 42, alignment: .trailing)
                }
            }
        }
        .modifier(V2Panel())
    }

    private func comparisonCard(_ base: Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("VS FAIXA AMENA (20–25°)")
            ForEach(buckets.filter { $0.label != "20–25°" }) { b in
                let diff = (b.avg - base) / base * 100
                HStack {
                    Text(b.label).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.text)
                    Text("\(b.n) viagens").font(.system(size: 10.5)).foregroundStyle(DS.muted)
                    Spacer()
                    Text("\(diff >= 0 ? "+" : "")\(Int(diff.rounded()))%")
                        .font(.system(size: 14, weight: .bold)).monospacedDigit()
                        .foregroundStyle(diff > 5 ? DS.orange : (diff < -5 ? DS.green : DS.muted))
                }
            }
        }
        .modifier(V2Panel())
    }

    private func barColor(_ v: Double) -> Color {
        guard let base = baseline, base > 0 else { return DS.teal }
        let d = (v - base) / base
        return d > 0.08 ? DS.orange : (d < -0.05 ? DS.green : DS.teal)
    }
}
