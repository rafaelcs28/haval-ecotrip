//  ChargeAnalysisSheet.swift
//  Análise de recarga: potência por faixa de SOC, eficiência AC, R$/kWh útil,
//  melhor horário e sessões interrompidas. 100% das recargas já sincronizadas.

import SwiftUI
import Charts

struct ChargeAnalysisSheet: View {
    let charges: [Charge]
    @Environment(\.dismiss) private var dismiss

    private var valid: [Charge] { charges.filter { $0.kwh > 1 } }

    // --- Potência média por faixa de SOC (mostra o taper da fase CV). ---
    private struct Band: Identifiable { let id = UUID(); let label: String; let lo: Double; let hi: Double; var powers: [Double] = []
        var avg: Double { powers.isEmpty ? 0 : powers.reduce(0, +) / Double(powers.count) } }

    private var bands: [Band] {
        var b = [Band(label: "0–20", lo: 0, hi: 20), Band(label: "20–40", lo: 20, hi: 40),
                 Band(label: "40–60", lo: 40, hi: 60), Band(label: "60–80", lo: 60, hi: 80),
                 Band(label: "80+", lo: 80, hi: 101)]
        // Cada sessão contribui pra todas as faixas que o intervalo [socStart, socEnd] cruza.
        for c in valid where c.avgPowerKw > 0 {
            for i in b.indices where c.socEnd > b[i].lo && c.socStart < b[i].hi {
                b[i].powers.append(c.avgPowerKw)
            }
        }
        return b.filter { !$0.powers.isEmpty }
    }

    private var avgLoss: Double {
        let l = valid.filter { $0.chargerKwh > 0 }
        return l.isEmpty ? 0 : l.reduce(0) { $0 + $1.lossPct } / Double(l.count)
    }
    // Eficiência AC = energia na bateria / energia no medidor.
    private var efficiency: Double { max(0, 100 - avgLoss) }
    private var hasLossData: Bool { valid.contains { $0.chargerKwh > 0 } }

    // R$/kWh útil = custo total ÷ energia que chegou na bateria (não no medidor).
    private var costPerUseful: Double {
        let totKwh = valid.reduce(0) { $0 + $1.kwh }, totCost = valid.reduce(0) { $0 + $1.costTotal }
        return totKwh > 0 && totCost > 0 ? totCost / totKwh : 0
    }

    // Melhor horário: hora do dia com menor R$/kWh (ou, sem custo, a mais frequente).
    private var bestTime: String? {
        let withCost = valid.filter { $0.costTotal > 0 && $0.kwh > 0 }
        let cal = Calendar.current
        if !withCost.isEmpty {
            var sumCost: [Int: Double] = [:], sumKwh: [Int: Double] = [:]
            for c in withCost {
                let h = cal.component(.hour, from: c.date)
                sumCost[h, default: 0] += c.costTotal; sumKwh[h, default: 0] += c.kwh
            }
            if let best = sumKwh.keys.filter({ (sumKwh[$0] ?? 0) > 0 })
                .min(by: { (sumCost[$0]! / sumKwh[$0]!) < (sumCost[$1]! / sumKwh[$1]!) }) {
                return hourLabel(best)
            }
        }
        var freq: [Int: Int] = [:]
        for c in valid { freq[cal.component(.hour, from: c.date), default: 0] += 1 }
        return freq.max(by: { $0.value < $1.value }).map { hourLabel($0.key) }
    }
    private func hourLabel(_ h: Int) -> String {
        if h >= 21 || h < 5 { return "depois das 21h" }
        if h < 12 { return "de manhã (\(h)h)" }
        if h < 18 { return "à tarde (\(h)h)" }
        return "à noite (\(h)h)"
    }

    // Sessões interrompidas: terminaram bem abaixo do topo típico (< 60% de SOC final).
    private var interrupted: (Int, Int) {
        let ended = valid.filter { $0.socEnd > 0 }
        let inter = ended.filter { $0.socEnd < 60 }.count
        return (inter, ended.count)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if valid.count < 2 {
                        DSCard {
                            VStack(spacing: 10) {
                                Image(systemName: "bolt.badge.clock").font(.system(size: 40)).foregroundStyle(DS.muted)
                                Text("Ainda sem recargas suficientes pra analisar.").font(.callout).foregroundStyle(DS.muted).multilineTextAlignment(.center)
                            }.frame(maxWidth: .infinity).padding(.vertical, 10)
                        }
                    } else {
                        if !bands.isEmpty { powerCard }
                        gridCards
                        listCard
                    }
                    Text("perda AC = (medidor − energia na bateria) / medidor · R$/kWh útil considera só a energia que chegou na bateria · preencha medidor e custo pra afinar")
                        .font(.system(size: 10.5)).foregroundStyle(DS.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Análise de recarga")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fechar") { dismiss() } } }
        }
    }

    // Barras teal: potência média por faixa de SOC (decrescente → taper CV visível).
    private var powerCard: some View {
        DSCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("POTÊNCIA POR FAIXA DE SOC").font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.muted).tracking(0.5)
                Chart {
                    ForEach(bands) { b in
                        BarMark(x: .value("Faixa", b.label), y: .value("kW", b.avg))
                            .foregroundStyle(DS.teal.gradient)
                            .cornerRadius(4)
                            .annotation(position: .top) {
                                Text(Fmt.dec1(b.avg)).font(.system(size: 9)).foregroundStyle(DS.muted)
                            }
                    }
                }
                .frame(height: 150)
                .chartYAxis { AxisMarks { v in
                    AxisValueLabel { if let d = v.as(Double.self) { Text("\(Fmt.int(d))").font(.system(size: 9)).foregroundStyle(DS.muted) } }
                } }
                .chartXAxis { AxisMarks { v in
                    AxisValueLabel { if let s = v.as(String.self) { Text(s).font(.system(size: 9)).foregroundStyle(DS.muted) } }
                } }
                Text("a potência cai perto do topo (fase CV) — parar antes dos 80% carrega no ritmo mais eficiente")
                    .font(.system(size: 9.5)).foregroundStyle(DS.muted)
            }
        }
    }

    // Grid 2: eficiência AC · custo real por kWh útil.
    private var gridCards: some View {
        HStack(spacing: 12) {
            statCard("EFICIÊNCIA AC", hasLossData ? "\(Fmt.int(efficiency))%" : "—",
                     hasLossData && efficiency < 88 ? DS.orange : DS.green,
                     hasLossData ? "\(Fmt.dec1(avgLoss))% de perda" : "lance o medidor")
            statCard("CUSTO REAL", costPerUseful > 0 ? Fmt.brl(costPerUseful) : "—", DS.yellow,
                     costPerUseful > 0 ? "por kWh útil" : "lance o custo")
        }
    }

    private func statCard(_ label: String, _ value: String, _ color: Color, _ sub: String) -> some View {
        DSCard {
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.muted).tracking(0.5)
                Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).foregroundStyle(color)
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                Text(sub).font(.system(size: 9.5)).foregroundStyle(DS.muted)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // Lista: melhor horário + sessões interrompidas (fundo painel2, hairlines).
    private var listCard: some View {
        VStack(spacing: 0) {
            infoRow(icon: "clock.fill", title: "Melhor horário", sub: "menor custo por kWh",
                    value: bestTime ?? "—", color: DS.green)
            Divider().background(DS.divider)
            infoRow(icon: "bolt.slash.fill", title: "Sessões interrompidas", sub: "terminaram abaixo de 60%",
                    value: "\(interrupted.0) de \(interrupted.1)", color: interrupted.0 > 0 ? DS.orange : DS.muted)
        }
        .background(DS.panel2)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private func infoRow(icon: String, title: String, sub: String, value: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(DS.text2).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13)).foregroundStyle(DS.text)
                Text(sub).font(.system(size: 9.5)).foregroundStyle(DS.muted)
            }
            Spacer()
            Text(value).font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(color).monospacedDigit()
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
    }
}
