//
//  NativeInsightsView.swift
//  Aba Insights — análises das viagens, separada do histórico (NativeViagensView).
//  Tudo glanceable numa rolagem só: ECONOMIA (hero) · DESEMPENHO (score + temp) ·
//  ATIVIDADE (km/mês + trajetos/marcos/relatório). Substitui a grade de 8 tiles
//  que abria 8 sheets fragmentadas. Os deep-dives continuam em sheet.
//

import SwiftUI
import Charts

struct NativeInsightsView: View {
    @ObservedObject private var loader = TripsLoader.shared
    @ObservedObject private var car = CarStore.shared
    @Environment(\.dismiss) private var dismiss

    // Compartilha o período com a aba Viagens (mesmas chaves AppStorage).
    @AppStorage("via_period") private var period = 0
    @AppStorage("via_from") private var fromTS: Double = 0
    @AppStorage("via_to") private var toTS: Double = 0
    @State private var showCal = false

    @State private var showEconomia = false
    @State private var showSavings = false
    @State private var showByMode = false
    @State private var showEco = false
    @State private var showTemp = false
    @State private var showRoutes = false
    @State private var showMilestones = false
    @State private var showReport = false

    private var fromDate: Binding<Date> { Binding(get: { fromTS > 0 ? Date(timeIntervalSince1970: fromTS) : Date() }, set: { fromTS = $0.timeIntervalSince1970 }) }
    private var toDate: Binding<Date> { Binding(get: { toTS > 0 ? Date(timeIntervalSince1970: toTS) : Date() }, set: { toTS = $0.timeIntervalSince1970 }) }

    private var baselineKmL: Double { car.kmPerL > 1 ? car.kmPerL : 11 }
    private var gasL: Double { car.priceGas > 0 ? car.priceGas : 6.0 }

    private var filtered: [Trip] {
        let now = Date(); let cal = Calendar.current
        switch period {
        case 0: return loader.trips.filter { cal.isDate($0.date, inSameDayAs: now) }
        case 1: let lim = now.addingTimeInterval(-7*86400);  return loader.trips.filter { $0.date >= lim }
        case 2: let lim = now.addingTimeInterval(-30*86400); return loader.trips.filter { $0.date >= lim }
        case 4:
            let lo = cal.startOfDay(for: fromDate.wrappedValue)
            let hi = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: toDate.wrappedValue)) ?? toDate.wrappedValue
            return loader.trips.filter { $0.date >= lo && $0.date < hi }
        default: return loader.trips
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                periodChips
                if period == 4 && showCal {
                    DSCard {
                        VStack(spacing: 10) {
                            DatePicker("De", selection: fromDate, displayedComponents: .date)
                            DatePicker("Até", selection: toDate, in: fromDate.wrappedValue..., displayedComponents: .date)
                        }.font(.system(size: 14)).foregroundStyle(DS.text).tint(DS.green).environment(\.locale, Locale(identifier: "pt_BR"))
                    }
                }

                if filtered.isEmpty {
                    DSCard { Text("Sem viagens no período.").font(.subheadline).foregroundStyle(DS.muted).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8) }
                } else {
                    section("ECONOMIA")
                    economiaHero
                    navRow(icon: "slider.horizontal.3", title: "Economia por modo", color: DS.green) { showByMode = true }
                    navRow(icon: "leaf.fill", title: "Economia total · compartilhar", color: DS.green) { showSavings = true }

                    section("DESEMPENHO").padding(.top, 4)
                    ecoScoreCard
                    tempCard

                    section("ATIVIDADE").padding(.top, 4)
                    monthlyChart(filtered)
                    navRow(icon: "arrow.triangle.swap", title: "Trajetos recorrentes", color: DS.orange) { showRoutes = true }
                    navRow(icon: "trophy.fill", title: "Marcos", color: DS.yellow) { showMilestones = true }
                    navRow(icon: "doc.text.fill", title: "Relatório mensal", color: DS.blue) { showReport = true }
                }
            }
            .padding(16)
        }
        .background(DS.bg.ignoresSafeArea())
        // "Melhor consumo" no EcoScoreSheet pede pra abrir a viagem no histórico:
        // o sheet já fechou; aqui voltamos pra aba Viagens, que expande/rola até ela.
        .onChange(of: loader.focusTripId) { if loader.focusTripId != nil { dismiss() } }
        .overlay { if loader.loading && loader.trips.isEmpty { ProgressView().tint(DS.green) } }
        .refreshable { await loader.load() }
        .task { await loader.load() }
        .sheet(isPresented: $showEconomia) { InsightsSheet(trips: loader.trips, priceKwh: car.priceKwh, priceGas: car.priceGas, kmPerLGas: car.kmPerL) }
        .sheet(isPresented: $showSavings) { SavingsSheet() }
        .sheet(isPresented: $showByMode) { ModeEconomySheet() }
        .sheet(isPresented: $showEco) { EcoScoreSheet(trips: loader.trips) }
        .sheet(isPresented: $showTemp) { TempConsumptionSheet(trips: loader.trips) }
        .sheet(isPresented: $showRoutes) { RouteCompareSheet(trips: loader.trips, priceKwh: car.priceKwh, priceGas: car.priceGas, kmPerLGas: car.kmPerL) }
        .sheet(isPresented: $showMilestones) { MilestonesSheet(odometerKm: car.num("odometer_km"), trips: loader.trips) }
        .sheet(isPresented: $showReport) { MonthlyReportSheet(trips: loader.trips, priceKwh: car.priceKwh, priceGas: car.priceGas, kmPerLGas: car.kmPerL) }
    }

    // MARK: ECONOMIA — funde Economia (período), Economia total e Por modo.
    private var economiaHero: some View {
        var km = 0.0, kwh = 0.0, fuel = 0.0, actual = 0.0, evKm = 0.0
        for t in filtered where t.distKm > 0.1 {
            km += t.distKm; kwh += t.netKwh; fuel += t.fuelL
            actual += t.netKwh * car.priceKwh + t.fuelL * gasL
            if t.fuelL < 0.05 { evKm += t.distKm }
        }
        let costIfGas = km / baselineKmL * gasL
        let savings = max(costIfGas - actual, 0)
        let savedPct = costIfGas > 0.01 ? Int((savings / costIfGas * 100).rounded()) : 0
        let evShare = km > 0 ? Int((evKm / km * 100).rounded()) : 0
        return Button { showEconomia = true } label: {
            DSCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "leaf.fill").foregroundStyle(DS.green)
                        Text("ECONOMIA VS. GASOLINA").font(.caption.weight(.semibold)).foregroundStyle(DS.muted).tracking(0.5)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(DS.muted)
                    }
                    Text(Fmt.brl(savings)).font(.system(size: 40, weight: .heavy, design: .rounded)).foregroundStyle(DS.green)
                        .lineLimit(1).minimumScaleFactor(0.5)
                    HStack(spacing: 14) {
                        miniStat("\(savedPct)%", "abaixo da gasolina", DS.green)
                        miniStat("\(evShare)%", "em modo EV", DS.teal)
                        miniStat(Fmt.km(km) + " km", "rodados", DS.blue)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.buttonStyle(.plain)
    }

    // MARK: DESEMPENHO
    private var ecoScoreCard: some View {
        let week = loader.trips.filter { $0.date > Date().addingTimeInterval(-7*86400) }
        let avg = Eco.avg(week) ?? Eco.avg(loader.trips)
        return Button { showEco = true } label: {
            DSCard {
                HStack(spacing: 14) {
                    Image(systemName: "gauge.with.dots.needle.67percent").font(.title2).foregroundStyle(avg.map(Eco.color) ?? DS.muted)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Nota de condução (7 dias)").font(.caption).foregroundStyle(DS.muted)
                        Text(avg.map { $0 >= Eco.goal ? "na meta ✓" : "abaixo da meta \(Eco.goal)" } ?? "sem dados suficientes")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(avg.map { $0 >= Eco.goal ? DS.green : DS.muted } ?? DS.muted)
                    }
                    Spacer()
                    Text(avg.map(String.init) ?? "—").font(.system(size: 34, weight: .heavy, design: .rounded)).foregroundStyle(avg.map(Eco.color) ?? DS.muted)
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(DS.muted)
                }
            }
        }.buttonStyle(.plain)
    }

    private var tempCard: some View {
        // Headline: quanto o frio (<18°) pesa vs faixa amena (20–25°), só elétricas.
        let elec = loader.trips.filter { $0.fuelL < 0.05 && $0.distKm >= 2 && $0.outsideTemp != nil }
        func avgCons(_ lo: Double, _ hi: Double) -> Double? {
            let v = elec.filter { ($0.outsideTemp ?? 0) >= lo && ($0.outsideTemp ?? 0) < hi }.map { $0.netKwh / $0.distKm * 100 }
            return v.count >= 2 ? v.reduce(0, +) / Double(v.count) : nil
        }
        let cold = avgCons(-100, 18), warm = avgCons(20, 25)
        let headline: String = {
            if let c = cold, let w = warm, w > 0 {
                let d = Int(((c - w) / w * 100).rounded())
                return d > 0 ? "Frio consome +\(d)% vs clima ameno" : "Frio consome \(d)% vs clima ameno"
            }
            return "Veja como o clima pesa no consumo"
        }()
        return Button { showTemp = true } label: {
            DSCard {
                HStack(spacing: 14) {
                    Image(systemName: "thermometer.medium").font(.title2).foregroundStyle(DS.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Consumo × temperatura").font(.subheadline.weight(.semibold)).foregroundStyle(DS.text)
                        Text(headline).font(.caption).foregroundStyle(DS.muted).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(DS.muted)
                }
            }
        }.buttonStyle(.plain)
    }

    // MARK: ATIVIDADE
    private func monthlyChart(_ f: [Trip]) -> some View {
        struct Bucket: Identifiable { let id: String; let label: String; let km: Double }
        let fmt = DateFormatter(); fmt.locale = Locale(identifier: "pt_BR"); fmt.dateFormat = "MMM/yy"
        let keyFmt = DateFormatter(); keyFmt.dateFormat = "yyyy-MM"
        var map: [String: (String, Double)] = [:]
        for t in f { let k = keyFmt.string(from: t.date); map[k] = (fmt.string(from: t.date), (map[k]?.1 ?? 0) + t.distKm) }
        let buckets = map.sorted { $0.key < $1.key }.map { Bucket(id: $0.key, label: $0.value.0, km: $0.value.1) }
        return DSCard(title: "km por mês", icon: "chart.bar.fill") {
            if buckets.count < 2 { Text("Precisa de mais de um mês de dados.").font(.caption).foregroundStyle(DS.muted) }
            else {
                Chart(buckets) { b in BarMark(x: .value("Mês", b.label), y: .value("km", b.km)).foregroundStyle(DS.teal) }
                    .frame(height: 160).chartYAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(DS.border); AxisValueLabel() } }
            }
        }
    }

    // MARK: helpers
    private func section(_ s: String) -> some View {
        Text(s).font(.system(size: 11, weight: .bold)).foregroundStyle(DS.muted).kerning(0.5)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func miniStat(_ v: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(v).font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(color)
            Text(label).font(.system(size: 9)).foregroundStyle(DS.muted)
        }
    }

    private func navRow(icon: String, title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.subheadline).foregroundStyle(color).frame(width: 22)
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(DS.text)
                Spacer()
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(DS.muted)
            }
            .padding(.horizontal, 14).frame(height: 48)
            .background(DS.panel).clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(DS.border, lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private var periodChips: some View {
        let opts = ["Hoje", "7 dias", "30 dias", "Tudo", "Calendário"]
        return HStack(spacing: 6) {
            ForEach(Array(opts.enumerated()), id: \.offset) { i, label in
                let on = period == i
                Button {
                    if i == 4 { showCal = (period == 4) ? !showCal : true } else { showCal = false }
                    period = i
                } label: {
                    Text(label).font(.system(size: 11, weight: .bold)).minimumScaleFactor(0.8).lineLimit(1)
                        .frame(maxWidth: .infinity).frame(height: 36)
                        .foregroundStyle(on ? .black : DS.text).background(on ? DS.green : DS.panel2).clipShape(Capsule())
                }
            }
        }
    }
}
