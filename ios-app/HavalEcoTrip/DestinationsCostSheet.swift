//  DestinationsCostSheet.swift
//  Custo por TRAJETO recorrente (origem→destino): custo total no período +
//  custo total/médio dos trajetos mais recorrentes, com comparação vs gasolina.

import SwiftUI

struct TripsCostData: Decodable {
    struct Route: Decodable {
        let name: String
        let trips: Int
        let avgKm, totalCost, avgCost, avgGasCost: Double
        let savedPct: Int
    }
    let lookbackDays: Int
    let gasPricePerL, kwhPrice, totalCost, totalGasCost: Double
    let totalTrips: Int
    let trips: [Route]
}

@MainActor
final class TripsCostStore: ObservableObject {
    @Published var data: TripsCostData?
    @Published var loading = false
    @Published var error: String?

    private var base: String {
        let u = BridgeRouter.shared.currentURL
        return u.hasSuffix("/") ? String(u.dropLast()) : u
    }

    func load() async {
        guard !base.isEmpty, let u = URL(string: "\(base)/api/routine/trips-cost") else { error = "Bridge não configurado."; return }
        loading = true; error = nil; defer { loading = false }
        var r = URLRequest(url: u); r.timeoutInterval = 12
        r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        do {
            let (d, resp) = try await URLSession.shared.data(for: r)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { error = "Falha ao carregar."; return }
            data = try JSONDecoder().decode(TripsCostData.self, from: d)
        } catch { self.error = "Erro de rede: \(error.localizedDescription)" }
    }
}

struct DestinationsCostSheet: View {
    @StateObject private var store = TripsCostStore()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if let d = store.data {
                        // Hero: gasto real total no período (todas as viagens).
                        VStack(alignment: .leading, spacing: 0) {
                            Text(Fmt.brl(d.totalCost))
                                .font(.system(size: 52, weight: .ultraLight, design: .rounded))
                                .foregroundStyle(DS.text).monospacedDigit()
                                .lineLimit(1).minimumScaleFactor(0.6)
                            Text("\(d.totalTrips) VIAGENS · ÚLTIMOS \(d.lookbackDays) DIAS")
                                .font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.muted).tracking(0.5)
                        }.frame(maxWidth: .infinity, alignment: .leading)

                        let saved = max(0, d.totalGasCost - d.totalCost)
                        Text("Se fosse gasolina \(Fmt.brl(d.totalGasCost)) · economizou \(Fmt.brl(saved))")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.green)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if d.trips.isEmpty {
                            DSCard { Text("Ainda sem trajetos recorrentes suficientes (mínimo 2 idas no período).").font(.callout).foregroundStyle(DS.muted).frame(maxWidth: .infinity, alignment: .leading) }
                        } else {
                            Text("TRAJETOS MAIS RECORRENTES")
                                .font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.muted).tracking(0.5)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)

                            let maxSpend = d.trips.map { $0.totalCost }.max() ?? 1
                            VStack(spacing: 0) {
                                ForEach(Array(d.trips.enumerated()), id: \.element.name) { idx, rt in
                                    row(rt, color: barColor(idx), maxSpend: maxSpend)
                                    if rt.name != d.trips.last?.name { Divider().background(DS.divider) }
                                }
                            }
                            .background(DS.panel2)
                            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                        }

                        Text("Comparação vs SUV gasolina. Eletricidade \(Fmt.brl(d.kwhPrice))/kWh · gasolina \(Fmt.brl(d.gasPricePerL))/L.")
                            .font(.caption2).foregroundStyle(DS.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if store.loading {
                        ProgressView().tint(DS.green).frame(maxWidth: .infinity).padding(.vertical, 40)
                    } else if let e = store.error {
                        DSCard { Text(e).font(.callout).foregroundStyle(DS.orange).frame(maxWidth: .infinity, alignment: .leading) }
                    }
                }
                .padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Custo por trajeto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fechar") { dismiss() } } }
            .task { await store.load() }
        }
    }

    // Verde → teal → laranja → cinza, por recorrência.
    private func barColor(_ idx: Int) -> Color {
        switch idx {
        case 0: return DS.green
        case 1: return DS.teal
        case 2: return DS.orange
        default: return DS.muted
        }
    }

    private func row(_ r: TripsCostData.Route, color: Color, maxSpend: Double) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(r.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.text).lineLimit(1)
                Spacer()
                Text(Fmt.brl(r.totalCost)).font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(color).monospacedDigit()
            }
            GeometryReader { g in
                let frac = maxSpend > 0 ? r.totalCost / maxSpend : 0
                Capsule().fill(color)
                    .frame(width: max(4, g.size.width * CGFloat(frac)))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 5)
            Text("\(r.trips)× · méd \(Fmt.brl(r.avgCost))/ida · \(Fmt.dec1(r.avgKm)) km")
                .font(.system(size: 9.5)).foregroundStyle(DS.muted)
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
    }
}
