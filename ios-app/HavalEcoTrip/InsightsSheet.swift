//  InsightsSheet.swift
//  Economia & insights EV: quanto você economizou rodando elétrico vs. gasolina,
//  CO₂ evitado, % do trajeto em EV e eficiência — tudo das viagens já sincronizadas.

import SwiftUI
import Charts

private let CO2_PER_L = 2.31        // kg CO₂ por litro de gasolina
private let CO2_PER_KWH = 0.0817    // kg CO₂ por kWh (rede BR, ~limpa/hidro)

struct InsightsSheet: View {
    let trips: [Trip]
    let priceKwh: Double
    let priceGas: Double
    let kmPerLGas: Double            // baseline de consumo a gasolina (km/L)
    @Environment(\.dismiss) private var dismiss
    @State private var period = 2    // 0=30d · 1=12 meses · 2=tudo

    private var baselineKmL: Double { kmPerLGas > 1 ? kmPerLGas : 11 }   // fallback ~11 km/L
    private var gasL: Double { priceGas > 0 ? priceGas : 6.0 }

    private var filtered: [Trip] {
        let now = Date()
        switch period {
        case 0: let lim = now.addingTimeInterval(-30*86400);  return trips.filter { $0.date >= lim }
        case 1: let lim = now.addingTimeInterval(-365*86400); return trips.filter { $0.date >= lim }
        default: return trips
        }
    }

    private struct Totals {
        var km = 0.0, kwh = 0.0, fuelL = 0.0, actualCost = 0.0, evKm = 0.0
        var litersIfGas = 0.0, costIfGas = 0.0
        var savings: Double { max(costIfGas - actualCost, 0) }
        var co2Avoided: Double { max((litersIfGas - fuelL) * CO2_PER_L - kwh * CO2_PER_KWH, 0) }
        var evShare: Double { km > 0 ? evKm / km * 100 : 0 }
        var effKwh100: Double { evKm > 0.5 ? kwh / evKm * 100 : 0 }
    }

    private var totals: Totals {
        var t = Totals()
        for trip in filtered where trip.distKm > 0.1 {
            t.km += trip.distKm; t.kwh += trip.netKwh; t.fuelL += trip.fuelL
            t.actualCost += trip.netKwh * priceKwh + trip.fuelL * gasL
            if trip.fuelL < 0.05 { t.evKm += trip.distKm }
        }
        t.litersIfGas = t.km / baselineKmL
        t.costIfGas = t.litersIfGas * gasL
        return t
    }

    // Economia por mês (12 últimos) pro gráfico.
    private struct MonthBar: Identifiable { let id = UUID(); let label: String; let savings: Double }
    private var monthly: [MonthBar] {
        let cal = Calendar.current
        let keyFmt = DateFormatter(); keyFmt.dateFormat = "yyyy-MM"
        let lblFmt = DateFormatter(); lblFmt.locale = Locale(identifier: "pt_BR"); lblFmt.dateFormat = "MMM"
        var map: [String: (Date, Double)] = [:]
        for trip in filtered where trip.distKm > 0.1 {
            let k = keyFmt.string(from: trip.date)
            let saved = (trip.distKm / baselineKmL) * gasL - (trip.netKwh * priceKwh + trip.fuelL * gasL)
            let cur = map[k]?.1 ?? 0
            map[k] = (cal.date(from: cal.dateComponents([.year, .month], from: trip.date)) ?? trip.date, cur + max(saved, 0))
        }
        return map.values.sorted { $0.0 < $1.0 }.suffix(12).map { MonthBar(label: lblFmt.string(from: $0.0), savings: $0.1) }
    }

    var body: some View {
        let t = totals
        return NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Picker("", selection: $period) {
                        Text("30 dias").tag(0); Text("12 meses").tag(1); Text("Tudo").tag(2)
                    }.pickerStyle(.segmented)

                    DSCard {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("ECONOMIA VS. GASOLINA").font(.caption.weight(.semibold)).foregroundStyle(DS.muted).tracking(0.5)
                            Text(Fmt.brl(t.savings)).font(.system(size: 40, weight: .heavy, design: .rounded)).foregroundStyle(DS.green)
                            Text("Você gastou \(Fmt.brl(t.actualCost)) — a gasolina (~\(Fmt.dec1(baselineKmL)) km/L) custaria \(Fmt.brl(t.costIfGas)).")
                                .font(.caption).foregroundStyle(DS.muted)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }

                    HStack(spacing: 12) {
                        DSCard { metric("🌱 CO₂ evitado", "\(Fmt.int(t.co2Avoided)) kg", DS.green) }
                        DSCard { metric("🔋 Em modo EV", "\(Fmt.int(t.evShare))%", DS.teal) }
                    }
                    HStack(spacing: 12) {
                        DSCard { metric("🛣 Rodados", "\(Fmt.int(t.km)) km", DS.blue) }
                        DSCard { metric("⚡ Eficiência", "\(Fmt.dec1(t.effKwh100)) kWh/100", DS.green) }
                    }

                    if monthly.count >= 2 {
                        DSCard(title: "Economia por mês", icon: "chart.bar.fill") {
                            Chart(monthly) { m in
                                BarMark(x: .value("Mês", m.label), y: .value("Economia", m.savings))
                                    .foregroundStyle(DS.green.gradient)
                            }
                            .frame(height: 150)
                            .chartYAxis { AxisMarks(format: Decimal.FormatStyle.Currency(code: "BRL").precision(.fractionLength(0))) }
                        }
                    }

                    Text("Estimativa: baseline de gasolina \(Fmt.dec1(baselineKmL)) km/L; CO₂ 2,31 kg/L e \(Fmt.dec2(CO2_PER_KWH)) kg/kWh (rede BR).")
                        .font(.caption2).foregroundStyle(DS.muted).frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Economia EV")
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
