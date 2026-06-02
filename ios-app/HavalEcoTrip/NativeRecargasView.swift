//
//  NativeRecargasView.swift
//  Aba Recargas NATIVA — histórico de sessões de recarga do Haval.
//  Consome GET /api/charges (array). kWh efetivo na bateria, R$/kWh, custo,
//  duração, SOC inicial→final por sessão + resumo no topo.
//

import SwiftUI

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

    private func f0(_ v: Double) -> String { String(format: "%.0f", v) }
    private func f1(_ v: Double) -> String { String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",") }
    private func brl(_ v: Double) -> String { "R$ " + String(format: "%.2f", v).replacingOccurrences(of: ".", with: ",") }
    private func perKwh(_ v: Double) -> String { String(format: "%.2f", v).replacingOccurrences(of: ".", with: ",") }
    private func dur(_ s: Double) -> String { let t = Int(s), h = t/3600, m = (t%3600)/60; return h > 0 ? "\(h)h \(m)min" : "\(m) min" }

    private static let df: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR"); f.dateFormat = "d MMM · HH:mm"; return f
    }()

    private var totalKwh: Double { loader.charges.reduce(0) { $0 + ($1.kwh ?? 0) } }
    private var totalCost: Double { loader.charges.reduce(0) { $0 + $1.costTotal } }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                summaryCard
                if loader.charges.isEmpty && !loader.loading {
                    Text(loader.failed ? "Não foi possível carregar as recargas." : "Nenhuma recarga registrada ainda.")
                        .font(.subheadline).foregroundStyle(DS.muted)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 30)
                }
                ForEach(loader.charges) { c in chargeCard(c) }
            }
            .padding(16)
        }
        .background(DS.bg.ignoresSafeArea())
        .overlay { if loader.loading && loader.charges.isEmpty { ProgressView().tint(DS.green) } }
        .refreshable { await loader.load() }
        .task { if loader.charges.isEmpty { await loader.load() } }
    }

    private var summaryCard: some View {
        DSCard {
            HStack {
                DSMetric(value: "\(loader.charges.count)", label: "Recargas", color: DS.green)
                DSMetric(value: f0(totalKwh), unit: "kWh", label: "Total na bateria", color: DS.teal)
                DSMetric(value: brl(totalCost), label: "Custo total", color: DS.text)
            }
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
                    label("SOC", "\(f0(c.soc_start ?? 0))% → \(f0(c.soc_end ?? 0))%")
                    label("Duração", dur(c.duration_sec ?? 0))
                    if let p = c.avg_power_kw, p > 0 { label("Potência média", "\(f1(p)) kW") }
                }
                if let cg = c.charger_kwh, cg > 0 {
                    Text("Carregador: \(f1(cg)) kWh (perdas \(f0(max(0, cg - (c.kwh ?? 0)))) kWh)")
                        .font(.caption2).foregroundStyle(DS.muted)
                }
            }
        }
    }

    private func label(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(DS.muted)
            Text(v).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.text)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
