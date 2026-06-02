//
//  NativeRecargasView.swift
//  Aba Recargas — Histórico + Estatísticas (sub-abas, como no PWA).
//  Consome GET /api/charges. Filtro por período (com calendário no Personalizar).
//

import SwiftUI
import Charts

// MARK: - Modelo
struct Charge: Decodable, Identifiable {
    struct Cost: Decodable { let total: Double?; let perKwh: Double? }
    let idValue: Double?
    let ts: Double?
    let timestamp_ms: Double?
    let type: String?
    let kwh: Double?
    let charger_kwh: Double?
    let duration_sec: Double?
    let avg_power_kw: Double?
    let soc_start: Double?
    let soc_end: Double?
    let cost: Cost?
    let override_cost: Cost?
    let location: String?

    enum CodingKeys: String, CodingKey {
        case idValue = "id", ts, timestamp_ms, type, kwh, charger_kwh, duration_sec
        case avg_power_kw, soc_start, soc_end, cost, override_cost, location
    }
    var id: Double { timestamp_ms ?? ts ?? idValue ?? 0 }
    var date: Date { Date(timeIntervalSince1970: id / 1000) }
    var costTotal: Double { override_cost?.total ?? cost?.total ?? 0 }
    var costPerKwh: Double { override_cost?.perKwh ?? cost?.perKwh ?? 0 }
    var isCharge: Bool { (type ?? "recarga") == "recarga" && (kwh ?? 0) > 0 }
}

// MARK: - Loader
@MainActor
final class ChargesLoader: ObservableObject {
    @Published var charges: [Charge] = []
    @Published var loading = false
    @Published var failed = false

    private var base: String {
        let u = Settings.bridgeURL.isEmpty ? AuthConfig.bridgeURL : Settings.bridgeURL
        return u.hasSuffix("/") ? String(u.dropLast()) : u
    }

    func load() async {
        guard Settings.isConfigured, let url = URL(string: "\(base)/api/charges") else { return }
        loading = true; failed = false
        var req = URLRequest(url: url); req.timeoutInterval = 12
        req.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { failed = true; loading = false; return }
            let all = try JSONDecoder().decode([Charge].self, from: data)
            charges = all.filter { $0.isCharge }.sorted { $0.id > $1.id }
        } catch { failed = true }
        loading = false
    }
}

// MARK: - View
struct NativeRecargasView: View {
    @StateObject private var loader = ChargesLoader()
    @State private var tab = 0          // 0=Histórico, 1=Estatísticas
    @State private var period = 2       // 0=7d, 1=30d, 2=Tudo, 3=Personalizar
    @State private var from = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    @State private var to = Date()

    private func f0(_ v: Double) -> String { String(format: "%.0f", v) }
    private func f1(_ v: Double) -> String { String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",") }
    private func brl(_ v: Double) -> String { "R$ " + String(format: "%.2f", v).replacingOccurrences(of: ".", with: ",") }
    private func perKwh(_ v: Double) -> String { String(format: "%.2f", v).replacingOccurrences(of: ".", with: ",") }
    private func dur(_ s: Double) -> String { let t = Int(s), h = t/3600, m = (t%3600)/60; return h > 0 ? "\(h)h \(m)min" : "\(m) min" }
    private static let df: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR"); f.dateFormat = "d MMM · HH:mm"; return f }()

    private var filtered: [Charge] {
        let now = Date()
        switch period {
        case 0: let lim = now.addingTimeInterval(-7*86400);  return loader.charges.filter { $0.date >= lim }
        case 1: let lim = now.addingTimeInterval(-30*86400); return loader.charges.filter { $0.date >= lim }
        case 3:
            let lo = Calendar.current.startOfDay(for: from)
            let hi = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: to)) ?? to
            return loader.charges.filter { $0.date >= lo && $0.date < hi }
        default: return loader.charges
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Picker("", selection: $tab) {
                    Text("Histórico").tag(0); Text("Estatísticas").tag(1)
                }.pickerStyle(.segmented)

                periodChips
                if period == 3 {
                    DSCard {
                        VStack(spacing: 10) {
                            DatePicker("De", selection: $from, displayedComponents: .date).tint(DS.green)
                            DatePicker("Até", selection: $to, displayedComponents: .date).tint(DS.green)
                        }.font(.system(size: 14)).foregroundStyle(DS.text)
                    }
                }

                if tab == 0 { historico } else { estatisticas }
            }
            .padding(16)
        }
        .background(DS.bg.ignoresSafeArea())
        .overlay { if loader.loading && loader.charges.isEmpty { ProgressView().tint(DS.green) } }
        .refreshable { await loader.load() }
        .task { if loader.charges.isEmpty { await loader.load() } }
    }

    private var periodChips: some View {
        let opts = ["7 dias", "30 dias", "Tudo", "Personalizar"]
        return HStack(spacing: 8) {
            ForEach(Array(opts.enumerated()), id: \.offset) { i, label in
                let on = period == i
                Button { period = i } label: {
                    Text(label).font(.system(size: 12, weight: .bold))
                        .frame(maxWidth: .infinity).frame(height: 36)
                        .foregroundStyle(on ? .black : DS.text).background(on ? DS.green : DS.panel2)
                        .clipShape(Capsule())
                }
            }
        }
    }

    // MARK: Histórico
    private var historico: some View {
        VStack(spacing: 14) {
            if filtered.isEmpty {
                Text(loader.failed ? "Não foi possível carregar." : "Nenhuma recarga no período.")
                    .font(.subheadline).foregroundStyle(DS.muted).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 20)
            }
            ForEach(filtered) { c in chargeCard(c) }
        }
    }

    private func chargeCard(_ c: Charge) -> some View {
        DSCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "bolt.fill").font(.caption).foregroundStyle(DS.green)
                    Text(c.location?.isEmpty == false ? c.location! : "Local desconhecido")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.text).lineLimit(1)
                    Spacer()
                    Text(Self.df.string(from: c.date)).font(.caption).foregroundStyle(DS.muted)
                }
                HStack {
                    DSMetric(value: f1(c.kwh ?? 0), unit: "kWh", label: "Na bateria", color: DS.green)
                    DSMetric(value: c.costTotal > 0 ? brl(c.costTotal) : "Grátis", label: "Custo", color: DS.text)
                    DSMetric(value: c.costPerKwh > 0 ? perKwh(c.costPerKwh) : "—", unit: "R$/kWh", label: "Preço")
                }
                HStack(spacing: 14) {
                    miniLabel("SOC", "\(f0(c.soc_start ?? 0))% → \(f0(c.soc_end ?? 0))%")
                    miniLabel("Duração", dur(c.duration_sec ?? 0))
                    if let p = c.avg_power_kw, p > 0 { miniLabel("Potência média", "\(f1(p)) kW") }
                }
                if let cg = c.charger_kwh, cg > 0 {
                    Text("Carregador: \(f1(cg)) kWh (perdas \(f0(max(0, cg - (c.kwh ?? 0)))) kWh)")
                        .font(.caption2).foregroundStyle(DS.muted)
                }
            }
        }
    }

    // MARK: Estatísticas
    private var estatisticas: some View {
        let f = filtered
        let kwh = f.reduce(0) { $0 + ($1.kwh ?? 0) }
        let chg = f.reduce(0) { $0 + ($1.charger_kwh ?? 0) }
        let cost = f.reduce(0) { $0 + $1.costTotal }
        let losses = max(0, chg - kwh)
        let eff = chg > 0 ? kwh / chg * 100 : 0
        return VStack(spacing: 14) {
            if f.isEmpty {
                Text("Sem dados no período.").font(.subheadline).foregroundStyle(DS.muted)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 20)
            } else {
                DSCard {
                    HStack {
                        DSMetric(value: "\(f.count)", label: "Recargas", color: DS.green)
                        DSMetric(value: f0(kwh), unit: "kWh", label: "Na bateria", color: DS.teal)
                        DSMetric(value: brl(cost), label: "Custo total")
                    }
                }
                DSCard {
                    HStack {
                        DSMetric(value: cost > 0 && kwh > 0 ? perKwh(cost/kwh) : "—", unit: "R$/kWh", label: "Preço médio")
                        DSMetric(value: f0(eff), unit: "%", label: "Eficiência", color: DS.green)
                        DSMetric(value: f1(losses), unit: "kWh", label: "Perdas", color: DS.orange)
                    }
                }
                DSCard {
                    HStack {
                        DSMetric(value: f1(kwh / Double(f.count)), unit: "kWh", label: "Média/recarga")
                        DSMetric(value: brl(cost / Double(f.count)), label: "Custo médio")
                        DSMetric(value: f0(chg), unit: "kWh", label: "No carregador", color: DS.muted)
                    }
                }
                monthlyChart(f)
                locationsCard(f)
            }
        }
    }

    private func monthlyChart(_ f: [Charge]) -> some View {
        struct Bucket: Identifiable { let id: String; let label: String; let kwh: Double }
        let fmt = DateFormatter(); fmt.locale = Locale(identifier: "pt_BR"); fmt.dateFormat = "MMM/yy"
        let keyFmt = DateFormatter(); keyFmt.dateFormat = "yyyy-MM"
        var map: [String: (String, Double)] = [:]
        for c in f {
            let key = keyFmt.string(from: c.date)
            let prev = map[key]?.1 ?? 0
            map[key] = (fmt.string(from: c.date), prev + (c.kwh ?? 0))
        }
        let buckets = map.sorted { $0.key < $1.key }.map { Bucket(id: $0.key, label: $0.value.0, kwh: $0.value.1) }
        return DSCard(title: "kWh por mês", icon: "chart.bar.fill") {
            if buckets.count < 2 {
                Text("Precisa de mais de um mês de dados.").font(.caption).foregroundStyle(DS.muted)
            } else {
                Chart(buckets) { b in
                    BarMark(x: .value("Mês", b.label), y: .value("kWh", b.kwh))
                        .foregroundStyle(DS.green)
                }
                .frame(height: 160)
                .chartYAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(DS.border); AxisValueLabel() } }
            }
        }
    }

    private func locationsCard(_ f: [Charge]) -> some View {
        var map: [String: (Double, Double, Int)] = [:]   // kwh, cost, count
        for c in f {
            let loc = (c.location?.isEmpty == false ? c.location! : "Desconhecido")
            let p = map[loc] ?? (0, 0, 0)
            map[loc] = (p.0 + (c.kwh ?? 0), p.1 + c.costTotal, p.2 + 1)
        }
        let rows = map.sorted { $0.value.0 > $1.value.0 }.prefix(6)
        return DSCard(title: "Por local", icon: "mappin.and.ellipse") {
            VStack(spacing: 10) {
                ForEach(Array(rows), id: \.key) { loc, v in
                    HStack {
                        Text(loc).font(.system(size: 14, weight: .medium)).foregroundStyle(DS.text).lineLimit(1)
                        Spacer()
                        Text("\(v.2)× · \(f0(v.0)) kWh").font(.caption).foregroundStyle(DS.muted)
                        Text(brl(v.1)).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.text).frame(minWidth: 72, alignment: .trailing)
                    }
                }
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
