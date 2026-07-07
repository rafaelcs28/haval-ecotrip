//  DestinationsCostSheet.swift
//  Custo médio por destino recorrente: agrupa viagens por local de chegada,
//  mostra custo real (energia+combustível) por ida e quanto economiza vs gasolina.

import SwiftUI

struct DestinationsCostData: Decodable {
    struct Dest: Decodable {
        let name: String
        let lat, lng: Double
        let trips: Int
        let avgKm, avgCost, avgGasCost: Double
        let savedPct: Int
    }
    let lookbackDays: Int
    let gasPricePerL, kwhPrice: Double
    let destinations: [Dest]
}

@MainActor
final class DestinationsCostStore: ObservableObject {
    @Published var data: DestinationsCostData?
    @Published var loading = false
    @Published var error: String?

    private var base: String {
        let u = BridgeRouter.shared.currentURL
        return u.hasSuffix("/") ? String(u.dropLast()) : u
    }

    func load() async {
        guard !base.isEmpty, let u = URL(string: "\(base)/api/routine/destinations-cost") else { error = "Bridge não configurado."; return }
        loading = true; error = nil; defer { loading = false }
        var r = URLRequest(url: u); r.timeoutInterval = 12
        r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        do {
            let (d, resp) = try await URLSession.shared.data(for: r)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { error = "Falha ao carregar."; return }
            data = try JSONDecoder().decode(DestinationsCostData.self, from: d)
        } catch { self.error = "Erro de rede: \(error.localizedDescription)" }
    }
}

struct DestinationsCostSheet: View {
    @StateObject private var store = DestinationsCostStore()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if let d = store.data {
                        if d.destinations.isEmpty {
                            DSCard { Text("Ainda sem destinos recorrentes suficientes (mínimo 3 idas no período).").font(.callout).foregroundStyle(DS.muted).frame(maxWidth: .infinity, alignment: .leading) }
                        } else {
                            let totalReal = d.destinations.reduce(0.0) { $0 + $1.avgCost * Double($1.trips) }
                            let totalGas = d.destinations.reduce(0.0) { $0 + $1.avgGasCost * Double($1.trips) }
                            let maxSpend = d.destinations.map { $0.avgCost * Double($0.trips) }.max() ?? 1

                            // Hero: gasto real total no período.
                            VStack(alignment: .leading, spacing: 0) {
                                HStack(alignment: .firstTextBaseline, spacing: 4) {
                                    Text(Fmt.brl(totalReal))
                                        .font(.system(size: 52, weight: .ultraLight, design: .rounded))
                                        .foregroundStyle(DS.text).monospacedDigit()
                                        .lineLimit(1).minimumScaleFactor(0.6)
                                }
                                Text("NOS ÚLTIMOS \(d.lookbackDays) DIAS")
                                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.muted).tracking(0.5)
                            }.frame(maxWidth: .infinity, alignment: .leading)

                            VStack(spacing: 0) {
                                let ordered = d.destinations.sorted { $0.avgCost * Double($0.trips) > $1.avgCost * Double($1.trips) }
                                ForEach(Array(ordered.enumerated()), id: \.element.name) { idx, dst in
                                    row(dst, color: barColor(idx), maxSpend: maxSpend)
                                    if dst.name != ordered.last?.name { Divider().background(DS.divider) }
                                }
                            }
                            .background(DS.panel2)
                            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))

                            let saved = max(0, totalGas - totalReal)
                            Text("Se fosse gasolina \(Fmt.brl(totalGas)) · economizou \(Fmt.brl(saved))")
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.green)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Text("Comparação vs SUV gasolina. Eletricidade \(Fmt.brl(d.kwhPrice))/kWh · gasolina \(Fmt.brl(d.gasPricePerL))/L.")
                                .font(.caption2).foregroundStyle(DS.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else if store.loading {
                        ProgressView().tint(DS.green).frame(maxWidth: .infinity).padding(.vertical, 40)
                    } else if let e = store.error {
                        DSCard { Text(e).font(.callout).foregroundStyle(DS.orange).frame(maxWidth: .infinity, alignment: .leading) }
                    }
                }
                .padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Custo por destino")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fechar") { dismiss() } } }
            .task { await store.load() }
        }
    }

    // Verde → teal → laranja → cinza, por ranking de gasto.
    private func barColor(_ idx: Int) -> Color {
        switch idx {
        case 0: return DS.green
        case 1: return DS.teal
        case 2: return DS.orange
        default: return DS.muted
        }
    }

    private func row(_ d: DestinationsCostData.Dest, color: Color, maxSpend: Double) -> some View {
        let spend = d.avgCost * Double(d.trips)
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(d.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.text).lineLimit(1)
                Spacer()
                Text(Fmt.brl(spend)).font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(color).monospacedDigit()
            }
            GeometryReader { g in
                let frac = maxSpend > 0 ? spend / maxSpend : 0
                Capsule().fill(color)
                    .frame(width: max(4, g.size.width * CGFloat(frac)))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 5)
            Text("\(d.trips)× · \(Fmt.brl(spend)) · méd \(Fmt.brl(d.avgCost))")
                .font(.system(size: 9.5)).foregroundStyle(DS.muted)
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
    }
}
