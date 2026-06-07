//  MonthlyReportSheet.swift
//  Relatório mensal: km, kWh, gasolina, R$, %EV, economia vs gasolina e CO₂
//  evitado, por mês — com exportação CSV das viagens do mês.

import SwiftUI

struct MonthlyReportSheet: View {
    let trips: [Trip]
    let priceKwh: Double
    let priceGas: Double
    let kmPerLGas: Double
    @Environment(\.dismiss) private var dismiss
    @State private var month: Date = Date()
    @State private var csvURL: URL?

    private let CO2_PER_L = 2.31, CO2_PER_KWH = 0.0817
    private var baselineKmL: Double { kmPerLGas > 1 ? kmPerLGas : 11 }
    private var gasL: Double { priceGas > 0 ? priceGas : 6.0 }
    private let cal = Calendar.current

    // Meses (1º dia) que têm viagem, mais recente primeiro.
    private var months: [Date] {
        let set = Set(trips.compactMap { cal.date(from: cal.dateComponents([.year, .month], from: $0.date)) })
        return set.sorted(by: >)
    }
    private var monthTrips: [Trip] {
        trips.filter { cal.isDate($0.date, equalTo: month, toGranularity: .month) && $0.distKm > 0.1 }
    }

    private struct Tot { var km = 0.0, kwh = 0.0, fuelL = 0.0, cost = 0.0, evKm = 0.0; var n = 0 }
    private var tot: Tot {
        var t = Tot()
        for v in monthTrips {
            t.km += v.distKm; t.kwh += v.netKwh; t.fuelL += v.fuelL
            t.cost += v.netKwh * priceKwh + v.fuelL * gasL
            if v.fuelL < 0.05 { t.evKm += v.distKm }
            t.n += 1
        }
        return t
    }
    private var savings: Double { max(tot.km / baselineKmL * gasL - tot.cost, 0) }
    private var co2: Double { max((tot.km / baselineKmL - tot.fuelL) * CO2_PER_L - tot.kwh * CO2_PER_KWH, 0) }
    private var evShare: Double { tot.km > 0 ? tot.evKm / tot.km * 100 : 0 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if months.isEmpty {
                        DSCard { Text("Sem viagens pra relatar ainda.").font(.callout).foregroundStyle(DS.muted).frame(maxWidth: .infinity).padding(.vertical, 10) }
                    } else {
                        monthPicker
                        gridCard
                        DSActionButton(icon: "square.and.arrow.up", title: "Exportar CSV do mês", color: DS.teal) { exportCSV() }
                        if let u = csvURL { ShareLink(item: u) { Label("Compartilhar arquivo", systemImage: "doc") .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 10).background(DS.panel2).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)).foregroundStyle(DS.text) } }
                        Text("Economia e CO₂ estimados vs. baseline de \(Fmt.dec1(baselineKmL)) km/L (gasolina \(Fmt.brl(gasL))/L).")
                            .font(.caption2).foregroundStyle(DS.muted)
                    }
                }
                .padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Relatório mensal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fechar") { dismiss() } } }
            .onAppear { if let m = months.first { month = m } }
        }
    }

    private var monthPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(months, id: \.self) { m in
                    Button { month = m; csvURL = nil } label: {
                        Text(monthLabel(m)).font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(cal.isDate(m, equalTo: month, toGranularity: .month) ? DS.teal.opacity(0.22) : DS.panel2)
                            .foregroundStyle(cal.isDate(m, equalTo: month, toGranularity: .month) ? DS.teal : DS.text)
                            .clipShape(Capsule())
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private var gridCard: some View {
        DSCard {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    cell(Fmt.km(tot.km), "km", "Distância", DS.blue)
                    cell(Fmt.dec1(tot.kwh), "kWh", "Energia", DS.green)
                    cell(Fmt.dec1(tot.fuelL), "L", "Gasolina", DS.orange)
                }
                HStack(spacing: 10) {
                    cell(Fmt.brl(tot.cost), "", "Custo", DS.text)
                    cell("\(Int(evShare.rounded()))", "%", "Elétrico", DS.green)
                    cell("\(tot.n)", "", "Viagens", DS.muted)
                }
                Divider().overlay(DS.border)
                HStack(spacing: 10) {
                    cell(Fmt.brl(savings), "", "Economia vs gasolina", DS.green)
                    cell(Fmt.int(co2), "kg", "CO₂ evitado", DS.teal)
                }
            }
        }
    }

    private func cell(_ v: String, _ unit: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(v).font(.system(size: 19, weight: .bold, design: .rounded)).foregroundStyle(color)
                if !unit.isEmpty { Text(unit).font(.caption2).foregroundStyle(DS.muted) }
            }
            Text(label).font(.system(size: 10)).foregroundStyle(DS.muted)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func monthLabel(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR"); f.dateFormat = "MMM/yyyy"
        return f.string(from: d).capitalized
    }

    private func exportCSV() {
        let df = DateFormatter(); df.locale = Locale(identifier: "pt_BR"); df.dateFormat = "dd/MM/yyyy HH:mm"
        let nf: (Double) -> String = { String(format: "%.2f", $0).replacingOccurrences(of: ".", with: ",") }
        func nm(_ t: Trip) -> String {
            let s = t.rawName ?? [t.knownStart, t.knownEnd].compactMap { $0 }.joined(separator: " > ")
            return s.replacingOccurrences(of: ";", with: " ")
        }
        var csv = "Data;Trajeto;Distancia_km;Energia_kWh;Gasolina_L;Custo_R$\n"
        for t in monthTrips.sorted(by: { $0.date < $1.date }) {
            let cost = t.netKwh * priceKwh + t.fuelL * gasL
            csv += "\(df.string(from: t.date));\(nm(t));\(nf(t.distKm));\(nf(t.netKwh));\(nf(t.fuelL));\(nf(cost))\n"
        }
        csv += "TOTAL;;\(nf(tot.km));\(nf(tot.kwh));\(nf(tot.fuelL));\(nf(tot.cost))\n"
        let mf = DateFormatter(); mf.dateFormat = "yyyy-MM"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("haval-\(mf.string(from: month)).csv")
        try? csv.data(using: .utf8)?.write(to: url)
        csvURL = url
    }
}
