//  ChargeForecastSheet.swift
//  Previsão de recarga: estima quanto a carga atual ainda dura, pelo consumo
//  diário recente (kWh/dia das viagens) + SOC atual + capacidade estimada.

import SwiftUI

struct ChargeForecastSheet: View {
    @ObservedObject private var loader = TripsLoader.shared
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
    // Reserva: os últimos 15% ficam pro motor a combustão → energia útil até 15%.
    private var usableKwh: Double { Double(max(0, soc - 15)) / 100 * capacity }
    private var currentKwh: Double { usableKwh }
    private var daysLeft: Double? { dailyKwh > 0.05 ? currentKwh / dailyKwh : nil }
    private var daysColor: Color {
        guard let d = daysLeft else { return DS.muted }
        return d < 1 ? DS.orange : (d < 2 ? DS.yellow : DS.green)
    }

    // Vampire drain: % de SOC perdido parado por dia. Olha o intervalo entre o fim
    // de uma viagem e o início da próxima; só conta quando o SOC caiu (sem recarga).
    private var vampireDrain: Double? {
        let sorted = loader.trips.filter { $0.distKm > 0.1 }.sorted { $0.date < $1.date }
        guard sorted.count >= 3 else { return nil }
        var rates: [Double] = []
        for i in 1..<sorted.count {
            let prev = sorted[i - 1], cur = sorted[i]
            let parkedH = (cur.date.timeIntervalSince(prev.date) - prev.timeSec) / 3600
            let drop = prev.endSoc - cur.startSoc
            if parkedH >= 2 && parkedH <= 24 * 7 && drop > 0 && drop < 40 {
                rates.append(drop / (parkedH / 24))
            }
        }
        guard rates.count >= 2 else { return nil }
        return rates.sorted()[rates.count / 2]   // mediana
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if loader.trips.isEmpty {
                        DSCard {
                            VStack(spacing: 10) {
                                if loader.loading { ProgressView().tint(DS.muted) }
                                else { Image(systemName: "calendar.badge.clock").font(.system(size: 40)).foregroundStyle(DS.muted) }
                                Text(loader.loading ? "Carregando…" : "Sem viagens pra estimar.").font(.callout).foregroundStyle(DS.muted)
                            }.frame(maxWidth: .infinity).padding(.vertical, 10)
                        }
                    } else {
                        hero
                        cellsCard
                        if let vd = vampireDrain { vampireRow(vd) }
                        Text("estimativa pelo consumo de bateria dos últimos 14 dias e capacidade útil de ~\(Fmt.dec1(capacity)) kWh · perda parado vem da queda de SOC entre viagens · varia com uso e clima")
                            .font(.system(size: 10.5)).foregroundStyle(DS.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
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

    // Hero: quantos dias a carga atual dura (numeral ultraLight) + quando carregar.
    private var hero: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 0) {
                if let d = daysLeft {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(d >= 1 ? Fmt.dec1(d) : "< 1")
                            .font(.system(size: 60, weight: .ultraLight, design: .rounded))
                            .foregroundStyle(daysColor).monospacedDigit()
                        Text("dias").font(.system(size: 16)).foregroundStyle(DS.muted)
                    }
                    Text("A CARGA ATUAL DURA").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DS.muted).tracking(0.5)
                    Text("carregue \(whenText(d))").font(.system(size: 12)).foregroundStyle(DS.text2).padding(.top, 4)
                } else {
                    Text("—").font(.system(size: 60, weight: .ultraLight, design: .rounded)).foregroundStyle(DS.muted)
                    Text("A CARGA ATUAL DURA").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DS.muted).tracking(0.5)
                    Text("sem consumo recente pra estimar").font(.system(size: 12)).foregroundStyle(DS.text2).padding(.top, 4)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                splitValue("\(soc)%", "SOC agora", arrivalSocColor(soc))
                splitValue("\(Fmt.dec1(currentKwh)) kWh", "útil até 15%", DS.green)
            }
        }
    }

    private var cellsCard: some View {
        DSCard {
            HStack(spacing: 14) {
                cell("\(soc)", "%", "SOC agora", arrivalSocColor(soc))
                cell(Fmt.dec1(currentKwh), "kWh", "Útil (até 15%)", DS.green)
                cell(Fmt.dec1(dailyKwh), "kWh/dia", "Uso médio", DS.teal)
            }
        }
    }

    private func vampireRow(_ vd: Double) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "moon.zzz.fill").font(.system(size: 14)).foregroundStyle(vd > 2 ? DS.orange : DS.text2).frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Perda parado").font(.system(size: 13)).foregroundStyle(DS.text)
                    Text(vd > 2 ? "acima do normal (~1%/dia)" : "dentro do normal").font(.system(size: 9.5)).foregroundStyle(DS.muted)
                }
                Spacer()
                Text("~\(Fmt.dec1(vd))%/dia").font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(vd > 2 ? DS.orange : DS.text).monospacedDigit()
            }
            .padding(.horizontal, 12).padding(.vertical, 11)
        }
        .background(DS.panel2)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private func whenText(_ days: Double) -> String {
        if days < 1 { return "hoje" }
        let target = Date().addingTimeInterval(days * 86400)
        if days < 2 { return "amanhã" }
        let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR"); f.dateFormat = "EEEE"
        return "até " + f.string(from: target)
    }

    private func splitValue(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(value).font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(color).monospacedDigit()
            Text(label).font(.system(size: 9.5)).foregroundStyle(DS.muted)
        }
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
