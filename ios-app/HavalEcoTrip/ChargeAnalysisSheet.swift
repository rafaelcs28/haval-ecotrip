//  ChargeAnalysisSheet.swift
//  Análise de recarga: perda AC, R$/kWh e perda por carregador, melhor/pior local.
//  100% das recargas já sincronizadas.

import SwiftUI

struct ChargeAnalysisSheet: View {
    let charges: [Charge]
    @Environment(\.dismiss) private var dismiss

    private var valid: [Charge] { charges.filter { $0.kwh > 1 } }

    private struct LocStat: Identifiable {
        let id = UUID()
        let name: String
        var n = 0
        var kwh = 0.0, charger = 0.0, cost = 0.0, lossSum = 0.0, lossCount = 0
        var perKwh: Double { kwh > 0 && cost > 0 ? cost / kwh : 0 }
        var lossPct: Double { lossCount > 0 ? lossSum / Double(lossCount) : 0 }
    }

    private var byLoc: [LocStat] {
        var map: [String: LocStat] = [:]
        for c in valid {
            var s = map[c.location] ?? LocStat(name: c.location)
            s.n += 1; s.kwh += c.kwh; s.charger += c.chargerKwh; s.cost += c.costTotal
            if c.chargerKwh > 0 { s.lossSum += c.lossPct; s.lossCount += 1 }
            map[c.location] = s
        }
        return map.values.sorted { $0.n > $1.n }
    }

    private var avgLoss: Double {
        let l = valid.filter { $0.chargerKwh > 0 }
        return l.isEmpty ? 0 : l.reduce(0) { $0 + $1.lossPct } / Double(l.count)
    }
    private var avgPerKwh: Double {
        let totKwh = valid.reduce(0) { $0 + $1.kwh }, totCost = valid.reduce(0) { $0 + $1.costTotal }
        return totKwh > 0 && totCost > 0 ? totCost / totKwh : 0
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if valid.count < 2 {
                        DSCard { Text("Ainda sem recargas suficientes pra analisar.").font(.callout).foregroundStyle(DS.muted).frame(maxWidth: .infinity).padding(.vertical, 10) }
                    } else {
                        HStack(spacing: 12) {
                            DSCard { metric("Perda AC média", "\(Fmt.dec1(avgLoss))%", avgLoss > 12 ? DS.orange : DS.green) }
                            DSCard { metric("R$/kWh médio", Fmt.brl(avgPerKwh), DS.yellow) }
                        }
                        if let cheap = byLoc.filter({ $0.perKwh > 0 }).min(by: { $0.perKwh < $1.perKwh }),
                           let lowLoss = byLoc.filter({ $0.lossCount > 0 }).min(by: { $0.lossPct < $1.lossPct }) {
                            HStack(spacing: 12) {
                                DSCard { highlight("💸 Mais barato", cheap.name, Fmt.brl(cheap.perKwh) + "/kWh", DS.green) }
                                DSCard { highlight("⚡ Menor perda", lowLoss.name, "\(Fmt.dec1(lowLoss.lossPct))%", DS.teal) }
                            }
                        }
                        DSCard(title: "Por carregador", icon: "bolt.fill") {
                            VStack(spacing: 0) {
                                ForEach(byLoc) { s in
                                    HStack(spacing: 8) {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(s.name).font(.subheadline).foregroundStyle(DS.text).lineLimit(1)
                                            Text("\(s.n)× · \(Fmt.dec1(s.kwh)) kWh").font(.caption2).foregroundStyle(DS.muted)
                                        }
                                        Spacer()
                                        VStack(alignment: .trailing, spacing: 1) {
                                            Text(s.perKwh > 0 ? Fmt.brl(s.perKwh) + "/kWh" : "—").font(.subheadline.weight(.semibold)).foregroundStyle(DS.yellow)
                                            if s.lossCount > 0 { Text("perda \(Fmt.dec1(s.lossPct))%").font(.caption2).foregroundStyle(s.lossPct > 12 ? DS.orange : DS.muted) }
                                        }
                                    }.padding(.vertical, 8)
                                    if s.id != byLoc.last?.id { Divider().background(DS.border) }
                                }
                            }
                        }
                    }
                    Text("Perda AC = (medidor − energia na bateria) / medidor. Preencha o medidor e o custo nas recargas pra melhorar a análise.")
                        .font(.caption2).foregroundStyle(DS.muted).frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Análise de recarga")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fechar") { dismiss() } } }
        }
    }

    @ViewBuilder private func metric(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(DS.muted)
            Text(value).font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.6)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private func highlight(_ tag: String, _ name: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(tag).font(.caption2).foregroundStyle(DS.muted)
            Text(name).font(.caption).foregroundStyle(DS.text).lineLimit(1)
            Text(value).font(.subheadline.weight(.bold)).foregroundStyle(color)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
