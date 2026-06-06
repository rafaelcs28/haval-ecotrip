//
//  NativeRecargasView.swift
//  Aba Recargas — Histórico + Estatísticas (sub-abas, como no PWA).
//  Consome GET /api/charges. Parsing tolerante (tipos mistos), filtro por
//  período com calendário clicável.
//

import SwiftUI
import Charts
import Combine

// Conversão tolerante (o bridge mistura Int/Double/String/NSNumber).
private func anyNum(_ v: Any?) -> Double {
    switch v {
    case let d as Double: return d
    case let i as Int: return Double(i)
    case let n as NSNumber: return n.doubleValue
    case let s as String: return Double(s) ?? 0
    default: return 0
    }
}

// MARK: - Modelo (montado de [String: Any] pra tolerar variações do servidor)
struct Charge: Identifiable {
    let raw: [String: Any]
    init(_ r: [String: Any]) { raw = r }

    private func n(_ k: String) -> Double { anyNum(raw[k]) }

    var id: Double { let v = n("timestamp_ms"); if v > 0 { return v }; let t = n("ts"); return t > 0 ? t : n("id") }
    var date: Date { Date(timeIntervalSince1970: id / 1000) }
    // Campos REAIS do /api/charges: energy_kwh (na bateria) + location_name.
    var kwh: Double { let e = n("energy_kwh"); return e > 0 ? e : n("kwh") }
    var chargerKwh: Double { n("charger_kwh") }
    var durationSec: Double { n("duration_sec") }
    var avgPowerKw: Double { n("avg_power_kw") }
    var socStart: Double { n("soc_start") }
    var socEnd: Double { n("soc_end") }
    var location: String { (raw["location_name"] as? String ?? raw["location"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Local desconhecido" }

    /// cost_override / cost: objeto {total, perKwh} (ou número solto).
    private func cost(_ key: String) -> (Double, Double)? {
        if let d = raw[key] as? [String: Any] { return (anyNum(d["total"]), anyNum(d["perKwh"])) }
        if raw[key] != nil { let v = anyNum(raw[key]); if v > 0 { return (v, 0) } }
        return nil
    }
    var costTotal: Double { (cost("cost_override") ?? cost("cost"))?.0 ?? 0 }
    var costPerKwh: Double { (cost("cost_override") ?? cost("cost"))?.1 ?? 0 }
    var isCharge: Bool { kwh > 0 }
    /// Perda: (medidor − energia na bateria) / medidor. Só com medidor lançado.
    var lossKwh: Double { max(0, chargerKwh - kwh) }
    var lossPct: Double { chargerKwh > 0 ? lossKwh / chargerKwh * 100 : 0 }
}

// MARK: - Loader (offline-first via SyncedList)
@MainActor
final class ChargesLoader: ObservableObject {
    let sync = SyncedList(name: "charges", path: "/api/charges", idKeys: ["timestamp_ms", "ts", "id"], incremental: true, tombstoneKey: "charges")
    @Published var loading = false
    @Published var failed = false
    @Published var diag = ""
    private var bag: AnyCancellable?

    init() { bag = sync.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() } }

    var charges: [Charge] { sync.items.map(Charge.init).filter { $0.isCharge }.sorted { $0.id > $1.id } }

    func load() async {
        loading = sync.items.isEmpty
        await sync.sync()
        diag = "itens \(sync.items.count) · válidas \(charges.count)\(sync.pendingCount > 0 ? " · \(sync.pendingCount) pend." : "")"
        loading = false
    }

    /// Edita medidor/custo/local — otimista local + fila offline (reenvia online).
    func edit(_ ts: Double, charger: Double?, total: Double?, location: String?, batteryKwh: Double) async {
        let id = Int(ts); let lid = "\(Int(ts))"
        if let charger, charger >= 0 {
            await sync.mutate(localId: lid, apply: { var d = $0; d["charger_kwh"] = charger; return d },
                              method: "PATCH", opPath: "/api/charges/\(id)/charger_kwh", body: ["charger_kwh": charger])
        }
        if let total, total >= 0 {
            let perKwh = batteryKwh > 0 ? total / batteryKwh : 0
            await sync.mutate(localId: lid, apply: { var d = $0; d["cost_override"] = ["total": total, "perKwh": perKwh]; return d },
                              method: "PATCH", opPath: "/api/charges/\(id)/cost", body: ["total": total, "per_kwh": perKwh])
        }
        if let location, !location.isEmpty {
            await sync.mutate(localId: lid, apply: { var d = $0; d["location_name"] = location; return d },
                              method: "PATCH", opPath: "/api/charges/\(id)/location", body: ["name": location, "save_known": true])
        }
    }
}

// MARK: - Abastecimento
struct Refuel: Identifiable {
    let raw: [String: Any]
    init(_ r: [String: Any]) { raw = r }
    private func n(_ k: String) -> Double { anyNum(raw[k]) }
    var id: Double { n("timestamp_ms") }
    var date: Date { Date(timeIntervalSince1970: id / 1000) }
    var liters: Double { n("liters_added") }
    var pricePerL: Double { n("price_per_liter") }
    var total: Double { n("total_cost") }
    var odometer: Double { n("odometer_km") }
    var location: String { (raw["location_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Posto" }
    var valid: Bool { liters > 0 }
}

@MainActor
final class RefuelsLoader: ObservableObject {
    // Abastecimentos não têm ?since= no bridge → full refresh, mas cacheado (offline).
    let sync = SyncedList(name: "refuels", path: "/api/refuels", idKeys: ["timestamp_ms", "id"], incremental: false, arrayKey: "refuels")
    @Published var diag = ""
    private var bag: AnyCancellable?
    init() { bag = sync.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() } }
    var refuels: [Refuel] { sync.items.map(Refuel.init).filter { $0.valid }.sorted { $0.id > $1.id } }
    func load() async { await sync.sync() }
}

// MARK: - View
struct NativeRecargasView: View {
    @StateObject private var loader = ChargesLoader()
    @StateObject private var refLoader = RefuelsLoader()
    @State private var source = 0       // 0=Recargas, 1=Abastecimento
    @State private var tab = 0          // 0=Histórico, 1=Estatísticas
    // 0=Hoje, 1=7d, 2=30d, 3=Tudo, 4=Calendário (intervalo). Persistido.
    @AppStorage("rec_period") private var period = 0
    @AppStorage("rec_from") private var fromTS: Double = 0
    @AppStorage("rec_to") private var toTS: Double = 0
    @State private var showCal = false
    @State private var expandedCharge: Double?
    @State private var toast: String?
    @State private var showHealth = false

    private var fromDate: Binding<Date> {
        Binding(get: { fromTS > 0 ? Date(timeIntervalSince1970: fromTS) : Date() }, set: { fromTS = $0.timeIntervalSince1970 })
    }
    private var toDate: Binding<Date> {
        Binding(get: { toTS > 0 ? Date(timeIntervalSince1970: toTS) : Date() }, set: { toTS = $0.timeIntervalSince1970 })
    }

    private func f0(_ v: Double) -> String { Fmt.int(v) }
    private func f1(_ v: Double) -> String { Fmt.dec2(v) }   // recargas: 2 casas
    private func brl(_ v: Double) -> String { Fmt.brl(v) }
    private func perKwh(_ v: Double) -> String { Fmt.dec2(v) }
    private func dur(_ s: Double) -> String { let t = Int(s), h = t/3600, m = (t%3600)/60; return h > 0 ? "\(h)h \(m)min" : "\(m) min" }
    private static let df: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR"); f.dateFormat = "d MMM · HH:mm"; return f }()

    private func inPeriod(_ d: Date) -> Bool {
        let now = Date(); let cal = Calendar.current
        switch period {
        case 0: return cal.isDate(d, inSameDayAs: now)
        case 1: return d >= now.addingTimeInterval(-7*86400)
        case 2: return d >= now.addingTimeInterval(-30*86400)
        case 4:
            let lo = cal.startOfDay(for: fromDate.wrappedValue)
            let hi = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: toDate.wrappedValue)) ?? toDate.wrappedValue
            return d >= lo && d < hi
        default: return true
        }
    }
    private var filtered: [Charge] { loader.charges.filter { inPeriod($0.date) } }
    private var filteredRefuels: [Refuel] { refLoader.refuels.filter { inPeriod($0.date) } }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Picker("", selection: $source) {
                    Text("Recargas").tag(0); Text("Abastecimento").tag(1)
                }.pickerStyle(.segmented)
                Picker("", selection: $tab) {
                    Text("Histórico").tag(0); Text("Estatísticas").tag(1)
                }.pickerStyle(.segmented)

                periodChips
                if period == 4 && showCal {
                    DSCard {
                        VStack(spacing: 10) {
                            DatePicker("De", selection: fromDate, displayedComponents: .date)
                            DatePicker("Até", selection: toDate, in: fromDate.wrappedValue..., displayedComponents: .date)
                        }.font(.system(size: 14)).foregroundStyle(DS.text).tint(DS.green)
                            .environment(\.locale, Locale(identifier: "pt_BR"))
                    }
                }

                if source == 0 { if tab == 0 { historico } else { healthButton; estatisticas } }
                else { if tab == 0 { refHistorico } else { refEstatisticas } }
            }
            .padding(16)
        }
        .sheet(isPresented: $showHealth) { BatteryHealthSheet(charges: loader.charges) }
        .background(DS.bg.ignoresSafeArea())
        .overlay { if loader.loading && loader.charges.isEmpty { ProgressView().tint(DS.green) } }
        .overlay(alignment: .bottom) {
            if let t = toast {
                Text(t).font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.text)
                    .padding(.horizontal, 18).padding(.vertical, 12).background(DS.panel2)
                    .clipShape(Capsule()).overlay(Capsule().stroke(DS.border, lineWidth: 1))
                    .padding(.bottom, 30).transition(.opacity)
                    .task { try? await Task.sleep(nanoseconds: 2_000_000_000); toast = nil }
            }
        }
        .animation(.easeInOut, value: toast)
        .refreshable { await loader.load(); await refLoader.load() }
        // Sincroniza SEMPRE ao abrir (não só com cache vazio): senão recargas novas
        // só entravam via pull-to-refresh manual ou WS no exato momento do evento.
        .task { await loader.load(); await refLoader.load() }
    }

    private var periodChips: some View {
        let opts = ["Hoje", "7 dias", "30 dias", "Tudo", "Calendário"]
        return HStack(spacing: 6) {
            ForEach(Array(opts.enumerated()), id: \.offset) { i, label in
                let on = period == i
                Button {
                    if i == 4 { showCal = (period == 4) ? !showCal : true }  // re-clicar recolhe
                    else { showCal = false }
                    period = i
                } label: {
                    Text(label).font(.system(size: 11, weight: .bold)).minimumScaleFactor(0.8).lineLimit(1)
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
                VStack(alignment: .leading, spacing: 6) {
                    Text(loader.failed ? "Não foi possível carregar." : "Nenhuma recarga no período.")
                        .font(.subheadline).foregroundStyle(DS.muted)
                    if !loader.diag.isEmpty {
                        Text(loader.diag).font(.caption2).foregroundStyle(DS.muted.opacity(0.7))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 20)
            }
            ForEach(filtered) { c in chargeCard(c) }
        }
    }

    private func chargeCard(_ c: Charge) -> some View {
        let expanded = expandedCharge == c.id
        return DSCard {
            VStack(alignment: .leading, spacing: 12) {
                Button { withAnimation(.easeInOut(duration: 0.2)) { expandedCharge = expanded ? nil : c.id } } label: {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "bolt.fill").font(.caption).foregroundStyle(DS.green)
                            Text(c.location).font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.text).lineLimit(1)
                            Spacer()
                            Text(Self.df.string(from: c.date)).font(.caption).foregroundStyle(DS.muted)
                            Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(DS.muted)
                        }
                        HStack {
                            DSMetric(value: f1(c.kwh), unit: "kWh", label: "Na bateria", color: DS.green)
                            DSMetric(value: c.costTotal > 0 ? brl(c.costTotal) : "Grátis", label: "Custo", color: DS.text)
                            DSMetric(value: c.costPerKwh > 0 ? perKwh(c.costPerKwh) : "—", unit: "R$/kWh", label: "Preço")
                        }
                    }
                }.buttonStyle(.plain)

                if expanded {
                    Divider().overlay(DS.border)
                    HStack(spacing: 14) {
                        miniLabel("SOC", "\(f0(c.socStart))% → \(f0(c.socEnd))%")
                        miniLabel("Duração", dur(c.durationSec))
                        if c.avgPowerKw > 0 { miniLabel("Potência média", "\(f1(c.avgPowerKw)) kW") }
                    }
                    if c.chargerKwh > 0 {
                        Text("Medidor: \(f1(c.chargerKwh)) kWh · entrou \(f1(c.kwh)) kWh · perda \(f1(c.lossKwh)) kWh (\(f0(c.lossPct))%)")
                            .font(.caption2).foregroundStyle(DS.muted)
                    }
                    ChargeEditFields(meter: c.chargerKwh, total: c.costTotal, location: c.location == "Local desconhecido" ? "" : c.location) { m, t, loc in
                        Task {
                            await loader.edit(c.id, charger: m, total: t, location: loc, batteryKwh: c.kwh)
                            withAnimation { expandedCharge = nil }
                            toast = "Recarga salva ✓"
                        }
                    }
                }
            }
        }
    }

    private var healthButton: some View {
        DSCard {
            Button { showHealth = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "heart.text.square.fill").font(.title3).foregroundStyle(DS.teal)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Saúde da bateria").font(.subheadline.weight(.semibold)).foregroundStyle(DS.text)
                        Text("Capacidade útil e degradação ao longo do tempo").font(.caption).foregroundStyle(DS.muted)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(DS.muted)
                }
            }
        }
    }

    // MARK: Estatísticas
    private var estatisticas: some View {
        let f = filtered
        let kwh = f.reduce(0) { $0 + $1.kwh }
        let chg = f.reduce(0) { $0 + $1.chargerKwh }
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
                        DSMetric(value: chg > 0 ? f0(eff) : "—", unit: "%", label: "Eficiência", color: DS.green)
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
            map[key] = (fmt.string(from: c.date), (map[key]?.1 ?? 0) + c.kwh)
        }
        let buckets = map.sorted { $0.key < $1.key }.map { Bucket(id: $0.key, label: $0.value.0, kwh: $0.value.1) }
        return DSCard(title: "kWh por mês", icon: "chart.bar.fill") {
            if buckets.count < 2 {
                Text("Precisa de mais de um mês de dados.").font(.caption).foregroundStyle(DS.muted)
            } else {
                Chart(buckets) { b in
                    BarMark(x: .value("Mês", b.label), y: .value("kWh", b.kwh)).foregroundStyle(DS.green)
                }
                .frame(height: 160)
                .chartYAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(DS.border); AxisValueLabel() } }
            }
        }
    }

    private func locationsCard(_ f: [Charge]) -> some View {
        struct Agg { var kwh = 0.0; var charger = 0.0; var cost = 0.0; var count = 0 }
        var map: [String: Agg] = [:]
        for c in f {
            var a = map[c.location] ?? Agg()
            a.kwh += c.kwh; a.charger += c.chargerKwh; a.cost += c.costTotal; a.count += 1
            map[c.location] = a
        }
        let rows = map.sorted { $0.value.kwh > $1.value.kwh }.prefix(8)
        return DSCard(title: "Por carregador", icon: "mappin.and.ellipse") {
            VStack(spacing: 12) {
                ForEach(Array(rows), id: \.key) { loc, a in
                    let loss = a.charger > 0 ? (a.charger - a.kwh) / a.charger * 100 : 0
                    VStack(spacing: 3) {
                        HStack {
                            Text(loc).font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.text).lineLimit(1)
                            Spacer()
                            Text(brl(a.cost)).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.text)
                        }
                        HStack(spacing: 10) {
                            Text("\(a.count)×").font(.caption2).foregroundStyle(DS.muted)
                            Text("bateria \(f1(a.kwh)) kWh").font(.caption2).foregroundStyle(DS.green)
                            if a.charger > 0 {
                                Text("medidor \(f1(a.charger)) kWh").font(.caption2).foregroundStyle(DS.teal)
                                Text("perda \(f0(loss))%").font(.caption2.weight(.bold)).foregroundStyle(loss > 15 ? DS.red : DS.orange)
                            }
                            Spacer()
                        }
                    }
                }
            }
        }
    }

    // MARK: Abastecimento
    private var refHistorico: some View {
        VStack(spacing: 14) {
            if filteredRefuels.isEmpty {
                Text("Nenhum abastecimento no período.").font(.subheadline).foregroundStyle(DS.muted)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 20)
            }
            ForEach(filteredRefuels) { r in
                DSCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "fuelpump.fill").font(.caption).foregroundStyle(DS.orange)
                            Text(r.location).font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.text).lineLimit(1)
                            Spacer()
                            Text(Self.df.string(from: r.date)).font(.caption).foregroundStyle(DS.muted)
                        }
                        HStack {
                            DSMetric(value: f1(r.liters), unit: "L", label: "Litros", color: DS.orange)
                            DSMetric(value: brl(r.total), label: "Total")
                            DSMetric(value: perKwh(r.pricePerL), unit: "R$/L", label: "Preço")
                        }
                        if r.odometer > 0 {
                            Text("Hodômetro: \(String(format: "%.0f", r.odometer)) km").font(.caption2).foregroundStyle(DS.muted)
                        }
                    }
                }
            }
        }
    }

    private var refEstatisticas: some View {
        let f = filteredRefuels
        let liters = f.reduce(0) { $0 + $1.liters }
        let cost = f.reduce(0) { $0 + $1.total }
        return VStack(spacing: 14) {
            if f.isEmpty {
                Text("Sem dados no período.").font(.subheadline).foregroundStyle(DS.muted).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 20)
            } else {
                DSCard {
                    HStack {
                        DSMetric(value: "\(f.count)", label: "Abastec.", color: DS.orange)
                        DSMetric(value: f1(liters), unit: "L", label: "Litros", color: DS.orange)
                        DSMetric(value: brl(cost), label: "Custo total")
                    }
                }
                DSCard {
                    HStack {
                        DSMetric(value: liters > 0 ? perKwh(cost/liters) : "—", unit: "R$/L", label: "Preço médio")
                        DSMetric(value: brl(cost / Double(f.count)), label: "Custo médio")
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

// Edição inline de uma recarga: medidor (kWh) + custo total.
private struct ChargeEditFields: View {
    let meter: Double
    let total: Double
    let location: String
    let onSave: (Double?, Double?, String?) -> Void
    @State private var m = ""
    @State private var t = ""
    @State private var loc = ""
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                field("Medidor (kWh)", $m, .decimalPad)
                field("Custo total (R$)", $t, .decimalPad)
            }
            field("Local", $loc, .default)
            Button { onSave(Double(m.replacingOccurrences(of: ",", with: ".")), Double(t.replacingOccurrences(of: ",", with: ".")), loc) } label: {
                Text("Salvar").font(.system(size: 14, weight: .bold)).frame(maxWidth: .infinity).frame(height: 42)
                    .foregroundStyle(.black).background(DS.green).clipShape(RoundedRectangle(cornerRadius: 11))
            }
        }
        .onAppear { if !loaded { m = meter > 0 ? String(format: "%.2f", meter) : ""; t = total > 0 ? String(format: "%.2f", total) : ""; loc = location; loaded = true } }
    }
    private func field(_ ph: String, _ text: Binding<String>, _ kb: UIKeyboardType) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(ph.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(DS.muted)
            TextField(ph, text: text).keyboardType(kb).foregroundStyle(DS.text)
                .padding(9).background(DS.panel2).clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(DS.border, lineWidth: 1))
        }
    }
}
