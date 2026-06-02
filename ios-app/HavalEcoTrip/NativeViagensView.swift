//
//  NativeViagensView.swift
//  Aba Viagens — histórico de viagens (auto-trips). GET /api/autotrips.
//  Histórico + Estatísticas, filtro por período com calendário.
//

import SwiftUI
import Charts

private func anyNum2(_ v: Any?) -> Double {
    switch v {
    case let d as Double: return d
    case let i as Int: return Double(i)
    case let n as NSNumber: return n.doubleValue
    case let s as String: return Double(s) ?? 0
    default: return 0
    }
}

struct Trip: Identifiable {
    let raw: [String: Any]
    init(_ r: [String: Any]) { raw = r }
    private func n(_ k: String) -> Double { anyNum2(raw[k]) }

    var id: Double { let s = n("startMs"); return s > 0 ? s : n("tripId") }
    var date: Date { Date(timeIntervalSince1970: id / 1000) }
    var distKm: Double { n("distKm") }
    var netKwh: Double { n("netKwh") }
    var fuelL: Double { n("fuelL") }
    var timeSec: Double { n("timeSec") }
    var cost: Double {
        if let d = raw["cost"] as? [String: Any] { return anyNum2(d["total"]) }
        return n("cost")
    }
    var consumo: Double { distKm > 0.5 ? netKwh / distKm * 100 : 0 }
    var rPerKm: Double { distKm > 0.5 ? cost / distKm : 0 }
    var valid: Bool { distKm > 0.1 || timeSec > 60 }
}

@MainActor
final class TripsLoader: ObservableObject {
    @Published var trips: [Trip] = []
    @Published var loading = false
    @Published var diag = ""

    private var base: String {
        let u = Settings.bridgeURL.isEmpty ? AuthConfig.bridgeURL : Settings.bridgeURL
        return u.hasSuffix("/") ? String(u.dropLast()) : u
    }

    func load() async {
        guard Settings.isConfigured, let url = URL(string: "\(base)/api/autotrips") else { diag = "app não configurado"; return }
        loading = true
        var req = URLRequest(url: url); req.timeoutInterval = 12
        req.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200 else { diag = "HTTP \(code) em /api/autotrips"; loading = false; return }
            let any = try? JSONSerialization.jsonObject(with: data)
            let arr = (any as? [[String: Any]]) ?? ((any as? [String: Any])?["trips"] as? [[String: Any]]) ?? []
            trips = arr.map(Trip.init).filter { $0.valid }.sorted { $0.id > $1.id }
            diag = "recebidas \(arr.count) · válidas \(trips.count)"
        } catch { diag = "erro: \(error.localizedDescription)" }
        loading = false
    }
}

struct NativeViagensView: View {
    @StateObject private var loader = TripsLoader()
    @State private var tab = 0
    @State private var period = 2
    @State private var day = Date()

    private func f0(_ v: Double) -> String { String(format: "%.0f", v) }
    private func f1(_ v: Double) -> String { String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",") }
    private func brl(_ v: Double) -> String { "R$ " + String(format: "%.2f", v).replacingOccurrences(of: ".", with: ",") }
    private func dur(_ s: Double) -> String { let t = Int(s), h = t/3600, m = (t%3600)/60; return h > 0 ? "\(h)h \(m)min" : "\(m) min" }
    private static let df: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR"); f.dateFormat = "d MMM · HH:mm"; return f }()

    private var filtered: [Trip] {
        let now = Date()
        switch period {
        case 0: let lim = now.addingTimeInterval(-7*86400);  return loader.trips.filter { $0.date >= lim }
        case 1: let lim = now.addingTimeInterval(-30*86400); return loader.trips.filter { $0.date >= lim }
        case 3: let cal = Calendar.current; return loader.trips.filter { cal.isDate($0.date, inSameDayAs: day) }
        default: return loader.trips
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Picker("", selection: $tab) { Text("Histórico").tag(0); Text("Estatísticas").tag(1) }.pickerStyle(.segmented)
                periodChips
                if period == 3 {
                    DSCard {
                        DatePicker("", selection: $day, displayedComponents: .date)
                            .datePickerStyle(.graphical).tint(DS.green).environment(\.locale, Locale(identifier: "pt_BR"))
                    }
                }
                if tab == 0 { historico } else { estatisticas }
            }
            .padding(16)
        }
        .background(DS.bg.ignoresSafeArea())
        .overlay { if loader.loading && loader.trips.isEmpty { ProgressView().tint(DS.green) } }
        .refreshable { await loader.load() }
        .task { if loader.trips.isEmpty { await loader.load() } }
    }

    private var periodChips: some View {
        let opts = ["7 dias", "30 dias", "Tudo", "Calendário"]
        return HStack(spacing: 8) {
            ForEach(Array(opts.enumerated()), id: \.offset) { i, label in
                let on = period == i
                Button { period = i } label: {
                    Text(label).font(.system(size: 12, weight: .bold)).frame(maxWidth: .infinity).frame(height: 36)
                        .foregroundStyle(on ? .black : DS.text).background(on ? DS.green : DS.panel2).clipShape(Capsule())
                }
            }
        }
    }

    private var historico: some View {
        VStack(spacing: 14) {
            if filtered.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nenhuma viagem no período.").font(.subheadline).foregroundStyle(DS.muted)
                    if !loader.diag.isEmpty { Text(loader.diag).font(.caption2).foregroundStyle(DS.muted.opacity(0.7)) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 20)
            }
            ForEach(filtered) { t in tripCard(t) }
        }
    }

    private func tripCard(_ t: Trip) -> some View {
        DSCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "car.fill").font(.caption).foregroundStyle(DS.teal)
                    Text(Self.df.string(from: t.date)).font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.text)
                    Spacer()
                    Text(dur(t.timeSec)).font(.caption).foregroundStyle(DS.muted)
                }
                HStack {
                    DSMetric(value: f1(t.distKm), unit: "km", label: "Distância", color: DS.teal)
                    DSMetric(value: f1(t.netKwh), unit: "kWh", label: "Energia", color: DS.green)
                    DSMetric(value: t.cost > 0 ? brl(t.cost) : "—", label: "Custo")
                }
                HStack(spacing: 14) {
                    miniLabel("Consumo", t.consumo > 0 ? "\(f1(t.consumo)) kWh/100" : "—")
                    miniLabel("R$/km", t.rPerKm > 0 ? brl(t.rPerKm) : "—")
                    if t.fuelL > 0.05 { miniLabel("Gasolina", "\(f1(t.fuelL)) L") }
                }
            }
        }
    }

    private var estatisticas: some View {
        let f = filtered
        let km = f.reduce(0) { $0 + $1.distKm }
        let kwh = f.reduce(0) { $0 + $1.netKwh }
        let fuel = f.reduce(0) { $0 + $1.fuelL }
        let cost = f.reduce(0) { $0 + $1.cost }
        return VStack(spacing: 14) {
            if f.isEmpty {
                Text("Sem dados no período.").font(.subheadline).foregroundStyle(DS.muted)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 20)
            } else {
                DSCard {
                    HStack {
                        DSMetric(value: "\(f.count)", label: "Viagens", color: DS.teal)
                        DSMetric(value: f0(km), unit: "km", label: "Distância", color: DS.green)
                        DSMetric(value: brl(cost), label: "Custo total")
                    }
                }
                DSCard {
                    HStack {
                        DSMetric(value: km > 1 ? "\(f1(kwh/km*100))" : "—", unit: "kWh/100", label: "Consumo médio")
                        DSMetric(value: km > 1 ? brl(cost/km) : "—", label: "R$/km", color: DS.green)
                        DSMetric(value: f1(fuel), unit: "L", label: "Gasolina", color: DS.orange)
                    }
                }
                DSCard {
                    HStack {
                        DSMetric(value: f1(km / Double(f.count)), unit: "km", label: "Média/viagem")
                        DSMetric(value: f0(kwh), unit: "kWh", label: "Energia total", color: DS.green)
                    }
                }
                monthlyChart(f)
            }
        }
    }

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
                    .frame(height: 160)
                    .chartYAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(DS.border); AxisValueLabel() } }
            }
        }
    }

    private func miniLabel(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(DS.muted)
            Text(v).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.text)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
