//  ChargeForecastSheet.swift
//  Previsão de recarga: estima quanto a carga atual ainda dura, pelo consumo
//  diário recente (kWh/dia das viagens) + SOC atual + capacidade estimada.

import SwiftUI

struct ChargeForecastSheet: View {
    @StateObject private var loader = TripsLoader()
    @ObservedObject private var car = CarStore.shared
    @Environment(\.dismiss) private var dismiss

    private var soc: Int { Int(car.socPct.rounded()) }

    private func capacityKwh(_ trips: [Trip]) -> Double {
        let caps = trips.compactMap { t -> Double? in
            let drop = t.startSoc - t.endSoc
            guard t.fuelL < 0.05, drop > 5, t.netKwh > 0.5 else { return nil }
            return t.netKwh / (drop / 100)
        }.filter { $0 > 8 && $0 < 80 }
        return caps.isEmpty ? 34 : caps.reduce(0, +) / Double(caps.count)
    }

    // kWh/dia: energia de bateria dos últimos 14 dias ÷ 14.
    private var dailyKwh: Double {
        let since = Date().addingTimeInterval(-14 * 86400)
        let kwh = loader.trips.filter { $0.date >= since }.reduce(0.0) { $0 + max(0, $1.netKwh) }
        return kwh / 14
    }
    private var capacity: Double { capacityKwh(loader.trips) }
    private var currentKwh: Double { Double(soc) / 100 * capacity }
    private var daysLeft: Double? { dailyKwh > 0.05 ? currentKwh / dailyKwh : nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if loader.trips.isEmpty {
                        DSCard { Text(loader.loading ? "Carregando…" : "Sem viagens pra estimar.").font(.callout).foregroundStyle(DS.muted).frame(maxWidth: .infinity).padding(.vertical, 10) }
                    } else {
                        DSCard {
                            VStack(spacing: 8) {
                                Text("A carga atual dura").font(.caption).foregroundStyle(DS.muted)
                                if let d = daysLeft {
                                    Text(d >= 1 ? "~\(Fmt.dec1(d)) dias" : "menos de 1 dia")
                                        .font(.system(size: 46, weight: .heavy, design: .rounded))
                                        .foregroundStyle(d < 1 ? DS.orange : (d < 2 ? DS.yellow : DS.green))
                                    Text("Carregue \(whenText(d))").font(.subheadline).foregroundStyle(DS.muted)
                                } else {
                                    Text("—").font(.system(size: 46, weight: .heavy, design: .rounded)).foregroundStyle(DS.muted)
                                    Text("Sem consumo recente pra estimar").font(.subheadline).foregroundStyle(DS.muted)
                                }
                            }.frame(maxWidth: .infinity).padding(.vertical, 4)
                        }
                        DSCard {
                            HStack(spacing: 14) {
                                cell("\(soc)", "%", "SOC agora", arrivalSocColor(soc))
                                cell(Fmt.dec1(currentKwh), "kWh", "Disponível", DS.green)
                                cell(Fmt.dec1(dailyKwh), "kWh/dia", "Uso médio", DS.teal)
                            }
                        }
                        Text("Estimativa pelo consumo de bateria dos últimos 14 dias e capacidade útil de ~\(Fmt.dec1(capacity)) kWh. Varia com seu uso e clima.")
                            .font(.caption2).foregroundStyle(DS.muted).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Previsão de recarga")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fechar") { dismiss() } } }
            .task { await loader.load() }
        }
    }

    private func whenText(_ days: Double) -> String {
        if days < 1 { return "hoje" }
        let target = Date().addingTimeInterval(days * 86400)
        if days < 2 { return "amanhã" }
        let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR"); f.dateFormat = "EEEE"
        return "até " + f.string(from: target)
    }

    private func cell(_ v: String, _ unit: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(v).font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(color)
                Text(unit).font(.caption2).foregroundStyle(DS.muted)
            }
            Text(label).font(.system(size: 10)).foregroundStyle(DS.muted)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
