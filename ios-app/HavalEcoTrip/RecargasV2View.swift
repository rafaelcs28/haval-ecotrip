//
//  RecargasV2View.swift
//  Recargas v2 — histórico com sessão expandida + curva de potência (6a),
//  estatísticas kWh/mês + por carregador (6b). design-v2/README.md §4.
//  V1 (NativeRecargasView) intacta; troca via ui_v2.
//

import SwiftUI

// MARK: - amostra da curva de potência (GET /api/charges/:ts/samples)

struct ChargeSample {
    let t: Double
    let kw: Double
    let soc: Double
}

enum ChargeCurve {
    static func load(_ ts: Double) async -> [ChargeSample] {
        let u = BridgeRouter.shared.currentURL
        let base = u.hasSuffix("/") ? String(u.dropLast()) : u
        guard let url = URL(string: "\(base)/api/charges/\(Int(ts))/samples") else { return [] }
        var req = URLRequest(url: url); req.timeoutInterval = 12
        req.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        guard let (d, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let raw = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return [] }
        func num(_ v: Any?) -> Double {
            switch v {
            case let d as Double: return d
            case let i as Int: return Double(i)
            case let n as NSNumber: return n.doubleValue
            default: return 0
            }
        }
        var out = raw.map { ChargeSample(t: num($0["t"]), kw: num($0["powerKw"]), soc: num($0["socPct"])) }
        if out.count > 240 { let step = out.count / 240 + 1; out = out.enumerated().filter { $0.offset % step == 0 }.map { $0.element } }
        return out
    }
}

// MARK: - View

struct RecargasV2View: View {
    @StateObject private var loader = ChargesLoader()
    @StateObject private var refLoader = RefuelsLoader()
    @ObservedObject private var car = CarStore.shared
    @AppStorage("rec2_source") private var source = 0    // 0 recargas · 1 abastecimento
    @AppStorage("rec2_tab") private var tab = 0          // 0 histórico · 1 estatísticas
    @AppStorage("rec2_kind") private var kind = 2        // 0 hoje · 1 7d · 2 30d · 3 mês · 4 personalizado
    @AppStorage("rec2_month") private var monthOffset = 0
    @AppStorage("rec2_from") private var fromTS: Double = 0
    @AppStorage("rec2_to") private var toTS: Double = 0
    @State private var expandedId: Double?
    @State private var curve: [ChargeSample] = []
    @State private var curveForId: Double = 0
    @State private var showAll = false
    @State private var showHealth = false
    @State private var showAnalysis = false
    @State private var showForecast = false
    @State private var editingId: Double?
    @State private var editingRefuel: Refuel?
    @State private var toast: String?

    private var fromDate: Binding<Date> { Binding(get: { fromTS > 0 ? Date(timeIntervalSince1970: fromTS) : Date() }, set: { fromTS = $0.timeIntervalSince1970 }) }
    private var toDate: Binding<Date> { Binding(get: { toTS > 0 ? Date(timeIntervalSince1970: toTS) : Date() }, set: { toTS = $0.timeIntervalSince1970 }) }
    private var periodLabel: String { PeriodUtil.label(kind: kind, monthOffset: monthOffset) }

    private var filtered: [Charge] {
        loader.charges.filter { PeriodUtil.contains(kind: kind, monthOffset: monthOffset, from: fromDate.wrappedValue, to: toDate.wrappedValue, $0.date) }
    }
    private var filteredRefuels: [Refuel] {
        refLoader.refuels.filter { PeriodUtil.contains(kind: kind, monthOffset: monthOffset, from: fromDate.wrappedValue, to: toDate.wrappedValue, $0.date) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                headerRow
                segmented
                if source == 0 { hero } else { refHero }
                subChips
                PeriodFilterBar(kind: $kind, monthOffset: $monthOffset, earliest: earliestDate)
                if kind == 4 { PeriodCalendarCard(from: fromDate, to: toDate) }
                if source == 0 {
                    if tab == 0 { historico } else { estatisticas }
                } else {
                    if tab == 0 { refHistorico } else { refEstatisticas }
                }
            }
            .padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 16)
        }
        .background(DS.bg.ignoresSafeArea())
        .refreshable { await loader.load(); await refLoader.load() }
        .task {
            await loader.load(); await refLoader.load()
            if expandedId == nil { expandedId = filtered.first?.id }
        }
        .onChange(of: expandedId) { loadCurve() }
        .onChange(of: loader.charges.first?.id) { if expandedId == nil { expandedId = filtered.first?.id }; loadCurve() }
        .sheet(isPresented: $showHealth) { BatteryHealthSheet(charges: loader.charges) }
        .sheet(isPresented: $showAnalysis) { ChargeAnalysisSheet(charges: loader.charges) }
        .sheet(isPresented: $showForecast) { ChargeForecastSheet() }
        .sheet(item: $editingRefuel) { r in
            RefuelEditSheet(refuel: r) { liters, pricePerL, location in
                Task { await refLoader.patch(r, liters: liters, pricePerL: pricePerL, location: location) }
            }
        }
        .overlay(alignment: .bottom) {
            if let t = toast {
                Text(t).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.text)
                    .padding(.horizontal, 16).padding(.vertical, 10).background(DS.panel2, in: Capsule())
                    .overlay(Capsule().stroke(DS.border, lineWidth: 1))
                    .padding(.bottom, 24).transition(.opacity)
                    .task { try? await Task.sleep(nanoseconds: 2_000_000_000); toast = nil }
            }
        }
        .animation(.easeInOut, value: toast)
    }

    private func loadCurve() {
        guard let id = expandedId, id != curveForId else { return }
        curveForId = id
        curve = []
        Task { curve = await ChargeCurve.load(id) }
    }

    // MARK: header + segmented + hero

    private var headerRow: some View {
        HStack {
            Text("Recargas").font(.system(size: 24, weight: .bold)).foregroundStyle(DS.text)
            Spacer()
            Button { showHealth = true } label: {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.green)
                    .frame(width: 36, height: 36)
                    .background(DS.panel2, in: Circle())
            }.buttonStyle(.plain)
        }
    }

    private var segmented: some View {
        HStack(spacing: 4) {
            segButton("Recargas", 0)
            segButton("Abastecimento", 1)
        }
        .padding(4)
        .background(DS.panel2, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func segButton(_ label: String, _ idx: Int) -> some View {
        let on = source == idx
        return Button { withAnimation(.easeInOut(duration: 0.15)) { source = idx } } label: {
            Text(label)
                .font(.system(size: 13, weight: on ? .bold : .semibold))
                .foregroundStyle(on ? DS.text : DS.muted)
                .frame(maxWidth: .infinity).frame(height: 34)
                .background(on ? DS.panel3 : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }.buttonStyle(.plain)
    }

    private var hero: some View {
        let f = filtered
        let kwh = f.reduce(0.0) { $0 + $1.kwh }
        let cost = f.reduce(0.0) { $0 + $1.costTotal }
        return HStack(alignment: .firstTextBaseline) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(Fmt.dec1(kwh))
                    .font(.system(size: 56, weight: .ultraLight)).tracking(-2)
                    .monospacedDigit().foregroundStyle(DS.text)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text("kWh").font(.system(size: 15)).foregroundStyle(DS.muted)
            }
            Spacer(minLength: 10)
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(f.count) recargas · \(periodLabel)")
                    .font(.system(size: 12.5, weight: .bold)).foregroundStyle(DS.green)
                Text("\(Fmt.brl(cost)) · média R$ \(kwh > 0 && cost > 0 ? Fmt.dec2(cost / kwh) : "—")/kWh")
                    .font(.system(size: 11.5)).foregroundStyle(DS.text2)
                if car.priceKwh > 0 {
                    Text("tarifa atual R$ \(Fmt.dec2(car.priceKwh))/kWh")
                        .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(DS.muted)
                }
            }
        }
    }

    private var refHero: some View {
        let f = filteredRefuels
        let l = f.reduce(0.0) { $0 + $1.liters }
        let cost = f.reduce(0.0) { $0 + $1.total }
        return HStack(alignment: .firstTextBaseline) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(Fmt.dec1(l))
                    .font(.system(size: 56, weight: .ultraLight)).tracking(-2)
                    .monospacedDigit().foregroundStyle(DS.text)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text("L").font(.system(size: 15)).foregroundStyle(DS.muted)
            }
            Spacer(minLength: 10)
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(f.count) abastec. · \(periodLabel)")
                    .font(.system(size: 12.5, weight: .bold)).foregroundStyle(DS.orange)
                Text("\(Fmt.brl(cost)) · média R$ \(l > 0 && cost > 0 ? Fmt.dec2(cost / l) : "—")/L")
                    .font(.system(size: 11.5)).foregroundStyle(DS.text2)
                if car.priceGas > 0 {
                    Text("preço atual R$ \(Fmt.dec2(car.priceGas))/L")
                        .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(DS.muted)
                }
            }
        }
    }

    private var earliestDate: Date? {
        source == 0 ? loader.charges.last?.date : refLoader.refuels.last?.date
    }

    private var subChips: some View {
        HStack(spacing: 8) {
            tabChip("Histórico", 0)
            tabChip("Estatísticas", 1)
            Spacer()
        }
    }

    private func tabChip(_ label: String, _ idx: Int) -> some View {
        let on = tab == idx
        return Button { tab = idx } label: {
            Text(label)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(on ? DS.green : DS.text2)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(on ? DS.green.opacity(0.10) : DS.panel2, in: Capsule())
                .overlay(Capsule().stroke(on ? DS.green.opacity(0.5) : .clear, lineWidth: 1))
        }.buttonStyle(.plain)
    }

    // MARK: 6a — histórico

    private var historico: some View {
        let list = filtered
        let visible = showAll ? list : Array(list.prefix(5))
        return LazyVStack(spacing: 10) {
            if list.isEmpty {
                Text(loader.failed ? "Não foi possível carregar." : "Nenhuma recarga no período.")
                    .font(.system(size: 13)).foregroundStyle(DS.muted)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
            }
            ForEach(visible) { c in
                if expandedId == c.id { expandedCard(c) } else { collapsedRow(c) }
            }
            if !showAll && list.count > 5 {
                Button { withAnimation { showAll = true } } label: {
                    Text("Ver todas as \(list.count) recargas ›")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.text2)
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                }.buttonStyle(.plain)
            }
        }
    }

    private func dayLabel(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "hoje" }
        if cal.isDateInYesterday(d) { return "ontem" }
        let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = d > Date().addingTimeInterval(-6 * 86400) ? "EEE" : "d MMM"
        return f.string(from: d).lowercased()
    }
    private func hhmm(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }
    private func durText(_ s: Double) -> String {
        let t = Int(s), h = t / 3600, m = (t % 3600) / 60
        return h > 0 ? "\(h)h\(String(format: "%02d", m))" : "\(m) min"
    }
    private func acdc(_ c: Charge) -> String {
        c.avgPowerKw >= 10 ? "DC \(Fmt.int(c.avgPowerKw)) kW" : "AC \(Fmt.dec1(c.avgPowerKw)) kW"
    }

    private func collapsedRow(_ c: Charge) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { expandedId = c.id; editingId = nil }
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(c.location)
                        .font(.system(size: 14, weight: .bold)).foregroundStyle(DS.text).lineLimit(1)
                    Text("\(dayLabel(c.date)) \(hhmm(c.date)) · \(acdc(c)) · \(Fmt.int(c.socStart))% → \(Fmt.int(c.socEnd))% · \(durText(c.durationSec))")
                        .font(.system(size: 11)).foregroundStyle(DS.text2)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 8)
                Text("\(Fmt.dec1(c.kwh)) kWh\(c.costTotal > 0 ? " · \(Fmt.brl(c.costTotal))" : "")")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.text)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(DS.muted)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(DS.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DS.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expandedId = c.id; editingId = c.id }
            } label: {
                Label("Editar medidor · custo · local", systemImage: "pencil")
            }
        }
    }

    // Alvo por software (ex.: 97%) tem prioridade — o carro fica em 100 e o bridge corta.
    private var effectiveLimit: Double {
        let custom = car.num("charge_custom_target")
        return custom > 0 ? custom : car.num("charge_limit_pct")
    }

    private func expandedCard(_ c: Charge) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(c.location).font(.system(size: 16, weight: .bold)).foregroundStyle(DS.text).lineLimit(1)
                    Text("\(dayLabel(c.date)) · \(hhmm(c.date)) – \(hhmm(c.date.addingTimeInterval(c.durationSec))) · \(acdc(c))")
                        .font(.system(size: 11.5)).foregroundStyle(DS.text2)
                }
                Spacer(minLength: 8)
                Text("+\(Fmt.dec1(c.kwh)) kWh")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(DS.green)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(DS.green.opacity(0.12), in: Capsule())
                    .overlay(Capsule().stroke(DS.green.opacity(0.3), lineWidth: 1))
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { expandedId = nil; editingId = nil } }

            socBar(c)

            HStack(spacing: 8) {
                tile("CUSTO", c.costTotal > 0 ? Fmt.brl(c.costTotal) : "Grátis", nil, DS.text)
                tile("DURAÇÃO", durText(c.durationSec), nil, DS.text)
                tile("MÉDIA", Fmt.dec1(c.avgPowerKw), "kW", DS.teal)
                tile("R$/KWH", c.costPerKwh > 0 ? Fmt.dec2(c.costPerKwh) : "—", nil, DS.text)
            }

            if !curve.isEmpty && curveForId == c.id { powerCurve(c) }

            if c.chargerKwh > 0 {
                Text("Medidor \(Fmt.dec2(c.chargerKwh)) kWh · entrou \(Fmt.dec2(c.kwh)) · perda \(Fmt.int(c.lossPct))%")
                    .font(.system(size: 10.5)).foregroundStyle(DS.muted)
            }

            if editingId == c.id {
                ChargeEditV2(charge: c) { m, t, loc in
                    Task {
                        await loader.edit(c.id, charger: m, total: t, location: loc, batteryKwh: c.kwh)
                        editingId = nil
                        toast = "Recarga salva"
                    }
                }
            }
        }
        .padding(14)
        .background(DS.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(DS.green.opacity(0.28), lineWidth: 1))
        .contextMenu {
            Button { withAnimation { editingId = c.id } } label: {
                Label("Editar medidor · custo · local", systemImage: "pencil")
            }
        }
    }

    // Barra SOC de→até: trecho pré-recarga apagado, ganho em gradiente, marcador
    // amarelo no limite de carga configurado.
    private func socBar(_ c: Charge) -> some View {
        let limit = effectiveLimit
        return VStack(spacing: 5) {
            HStack {
                Text("SOC").font(.system(size: 9, weight: .bold)).foregroundStyle(DS.muted).tracking(1)
                Spacer()
                (Text("\(Fmt.int(c.socStart))% ").foregroundStyle(DS.text2)
                 + Text("→ \(Fmt.int(c.socEnd))%").foregroundStyle(DS.text))
                    .font(.system(size: 11, weight: .bold))
            }
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Rectangle().fill(DS.green.opacity(0.25))
                        .frame(width: w * c.socStart / 100)
                    Rectangle().fill(DS.greenGrad)
                        .frame(width: max(0, w * (c.socEnd - c.socStart) / 100))
                        .offset(x: w * c.socStart / 100)
                    if limit > 0 && limit < 100 {
                        Rectangle().fill(DS.yellow)
                            .frame(width: 2.5, height: 12)
                            .offset(x: w * limit / 100 - 1)
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 8)
        }
    }

    private func tile(_ label: String, _ value: String, _ unit: String?, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 8.5, weight: .bold)).foregroundStyle(DS.muted).tracking(0.8)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.system(size: 15, weight: .bold, design: .rounded))
                    .monospacedDigit().foregroundStyle(color)
                    .lineLimit(1).minimumScaleFactor(0.7)
                if let unit { Text(unit).font(.system(size: 9)).foregroundStyle(DS.muted) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(DS.panel2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func powerCurve(_ c: Charge) -> some View {
        let maxKw = max(curve.map(\.kw).max() ?? 1, 0.1)
        let maxT = max(curve.last?.t ?? 1, 1)
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("CURVA DE POTÊNCIA · KW")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(DS.muted).tracking(1)
                Spacer()
                Text("\(Fmt.dec1(maxKw)) máx").font(.system(size: 10)).foregroundStyle(DS.muted)
            }
            Canvas { ctx, size in
                guard curve.count > 1 else { return }
                var line = Path()
                var area = Path()
                for (i, s) in curve.enumerated() {
                    let x = CGFloat(s.t / maxT) * size.width
                    let y = size.height - CGFloat(s.kw / maxKw) * (size.height - 6) - 3
                    if i == 0 { line.move(to: .init(x: x, y: y)); area.move(to: .init(x: x, y: size.height)); area.addLine(to: .init(x: x, y: y)) }
                    else { line.addLine(to: .init(x: x, y: y)); area.addLine(to: .init(x: x, y: y)) }
                }
                area.addLine(to: .init(x: size.width, y: size.height))
                area.closeSubpath()
                ctx.fill(area, with: .color(DS.teal.opacity(0.14)))
                ctx.stroke(line, with: .color(DS.teal), lineWidth: 2)
            }
            .frame(height: 86)
            HStack {
                Text(hhmm(c.date)).font(.system(size: 9.5)).foregroundStyle(DS.muted)
                Spacer()
                Text(hhmm(c.date.addingTimeInterval(c.durationSec))).font(.system(size: 9.5)).foregroundStyle(DS.muted)
            }
        }
    }

    // MARK: 6b — estatísticas

    private var estatisticas: some View {
        VStack(spacing: 12) {
            kwhPorMes
            porCarregador
            custoMedioGrid
            drillList
        }
    }

    private var kwhPorMes: some View {
        let cal = Calendar.current
        let months: [(label: String, kwh: Double, current: Bool)] = (0..<6).reversed().map { off in
            let d = cal.date(byAdding: .month, value: -off, to: Date()) ?? Date()
            let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR"); f.dateFormat = "MMM"
            let kwh = loader.charges.filter { cal.isDate($0.date, equalTo: d, toGranularity: .month) }
                .reduce(0.0) { $0 + $1.kwh }
            return (f.string(from: d).uppercased().replacingOccurrences(of: ".", with: ""), kwh, off == 0)
        }
        let nonzero = months.filter { $0.kwh > 0 }
        let avg = nonzero.isEmpty ? 0 : nonzero.reduce(0.0) { $0 + $1.kwh } / Double(nonzero.count)
        let peak = max(months.map(\.kwh).max() ?? 1, 0.1)
        return card {
            VStack(spacing: 10) {
                HStack {
                    Text("KWH POR MÊS").font(.system(size: 10, weight: .bold)).foregroundStyle(DS.muted).tracking(1)
                    Spacer()
                    Text("média \(Fmt.dec1(avg))").font(.system(size: 11)).foregroundStyle(DS.text2)
                }
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(Array(months.enumerated()), id: \.offset) { _, m in
                        VStack(spacing: 4) {
                            Text(m.kwh > 0 ? Fmt.dec1(m.kwh) : "")
                                .font(.system(size: 9.5, weight: m.current ? .bold : .regular))
                                .foregroundStyle(m.current ? DS.green : DS.muted)
                                .lineLimit(1).minimumScaleFactor(0.7)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(m.current ? AnyShapeStyle(DS.greenGrad) : AnyShapeStyle(DS.panel3))
                                .frame(height: max(8, 92 * m.kwh / peak))
                            Text(m.label)
                                .font(.system(size: 8.5, weight: m.current ? .bold : .semibold))
                                .foregroundStyle(m.current ? DS.green : DS.muted).tracking(0.5)
                        }.frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private var porCarregador: some View {
        struct Agg { var kwh = 0.0; var cost = 0.0 }
        var map: [String: Agg] = [:]
        for c in filtered {
            var a = map[c.location] ?? Agg(); a.kwh += c.kwh; a.cost += c.costTotal; map[c.location] = a
        }
        let sorted = map.sorted { $0.value.kwh > $1.value.kwh }
        let top = Array(sorted.prefix(2))
        let rest = sorted.dropFirst(2)
        let restAgg = rest.reduce(Agg()) { var a = $0; a.kwh += $1.value.kwh; a.cost += $1.value.cost; return a }
        var rows: [(name: String, agg: Agg, color: Color)] = top.enumerated().map { i, e in
            (e.key, e.value, i == 0 ? DS.green : DS.teal)
        }
        if restAgg.kwh > 0 { rows.append(("Outros", restAgg, DS.muted)) }
        let total = max(rows.reduce(0.0) { $0 + $1.agg.kwh }, 0.1)
        return card {
            VStack(alignment: .leading, spacing: 12) {
                Text("POR CARREGADOR · \(periodLabel.uppercased())")
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(DS.muted).tracking(1)
                if rows.isEmpty {
                    Text("Sem recargas no período.").font(.system(size: 12)).foregroundStyle(DS.muted)
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    VStack(spacing: 5) {
                        HStack {
                            Text(r.name).font(.system(size: 13, weight: .bold))
                                .foregroundStyle(r.color == DS.muted ? DS.text2 : DS.text).lineLimit(1)
                            Spacer()
                            Text("\(Fmt.dec1(r.agg.kwh)) kWh\(r.agg.cost > 0 ? " · \(Fmt.brl(r.agg.cost))" : "")")
                                .font(.system(size: 11.5)).foregroundStyle(DS.text2)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.06))
                                Capsule().fill(r.color)
                                    .frame(width: max(6, geo.size.width * r.agg.kwh / total))
                            }
                        }.frame(height: 5)
                    }
                }
            }
        }
    }

    private var custoMedioGrid: some View {
        let f = filtered.filter { $0.costTotal > 0 && $0.kwh > 0 }
        let ac = f.filter { $0.avgPowerKw < 10 }
        let dc = f.filter { $0.avgPowerKw >= 10 }
        func avg(_ arr: [Charge]) -> Double {
            let kwh = arr.reduce(0.0) { $0 + $1.kwh }
            return kwh > 0 ? arr.reduce(0.0) { $0 + $1.costTotal } / kwh : 0
        }
        return HStack(spacing: 10) {
            costCard("CUSTO MÉDIO · AC", avg(ac), DS.text)
            costCard("CUSTO MÉDIO · DC", avg(dc), DS.orange)
        }
    }

    private func costCard(_ label: String, _ v: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 9, weight: .bold)).foregroundStyle(DS.muted).tracking(0.8)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(v > 0 ? "R$ \(Fmt.dec2(v))" : "—")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .monospacedDigit().foregroundStyle(v > 0 ? color : DS.muted)
                    .lineLimit(1).minimumScaleFactor(0.7)
                if v > 0 { Text("/kWh").font(.system(size: 10)).foregroundStyle(DS.muted) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(DS.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DS.border, lineWidth: 1))
    }

    // SoH estimado igual ao BatteryHealthSheet: média das 5 recargas mais
    // recentes com ganho de SOC relevante (charges já vem em ordem desc).
    private var sohPct: Double {
        let ordered = loader.charges.compactMap { c -> Double? in
            let gain = c.socEnd - c.socStart
            guard gain >= 15, c.kwh > 1 else { return nil }
            let cap = c.kwh / (gain / 100.0)
            return (cap > 8 && cap < 60) ? cap : nil
        }
        let tail = ordered.prefix(5)
        guard !tail.isEmpty else { return 0 }
        let cur = tail.reduce(0, +) / Double(tail.count)
        return min(cur / 34.0 * 100, 100)
    }

    private var drillList: some View {
        VStack(spacing: 0) {
            drillRow("Saúde da bateria", sohPct > 0 ? "SoH \(Fmt.dec1(sohPct))%" : nil, DS.green) { showHealth = true }
            Divider().overlay(DS.divider).padding(.leading, 14)
            drillRow("Análise de recarga", nil, DS.text2) { showAnalysis = true }
            Divider().overlay(DS.divider).padding(.leading, 14)
            drillRow("Previsão de recarga", nil, DS.text2) { showForecast = true }
        }
        .background(DS.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DS.border, lineWidth: 1))
    }

    private func drillRow(_ title: String, _ trailing: String?, _ tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.text)
                Spacer()
                if let trailing {
                    Text(trailing).font(.system(size: 12, weight: .bold)).foregroundStyle(tint)
                }
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(DS.muted)
            }
            .padding(.horizontal, 14).frame(height: 46)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DS.border, lineWidth: 1))
    }

    // MARK: abastecimento

    private var refHistorico: some View {
        LazyVStack(spacing: 10) {
            if filteredRefuels.isEmpty {
                Text("Nenhum abastecimento no período.")
                    .font(.system(size: 13)).foregroundStyle(DS.muted)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
            }
            ForEach(filteredRefuels) { r in refuelRow(r) }
        }
    }

    private func refuelRow(_ r: Refuel) -> some View {
        Button {
            editingRefuel = r
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "fuelpump.fill").font(.system(size: 13)).foregroundStyle(DS.orange)
                    .frame(width: 30, height: 30)
                    .background(DS.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(r.location).font(.system(size: 14, weight: .bold)).foregroundStyle(DS.text).lineLimit(1)
                    Text("\(dayLabel(r.date)) \(hhmm(r.date)) · \(Fmt.dec1(r.liters)) L · R$ \(Fmt.dec2(r.pricePerL))/L")
                        .font(.system(size: 11)).foregroundStyle(DS.text2)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 8)
                Text(Fmt.brl(r.total)).font(.system(size: 13, weight: .bold)).foregroundStyle(DS.text)
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(DS.muted)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(DS.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DS.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var refEstatisticas: some View {
        let f = filteredRefuels
        let liters = f.reduce(0.0) { $0 + $1.liters }
        let cost = f.reduce(0.0) { $0 + $1.total }
        return VStack(spacing: 10) {
            if f.isEmpty {
                Text("Sem dados no período.").font(.system(size: 13)).foregroundStyle(DS.muted)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
            } else {
                HStack(spacing: 10) {
                    costCardText("ABASTECIMENTOS", "\(f.count)", DS.orange)
                    costCardText("LITROS", Fmt.dec1(liters), DS.text)
                }
                HStack(spacing: 10) {
                    costCardText("PREÇO MÉDIO", liters > 0 ? "R$ \(Fmt.dec2(cost / liters))/L" : "—", DS.text)
                    costCardText("CUSTO TOTAL", Fmt.brl(cost), DS.text)
                }
            }
        }
    }

    private func costCardText(_ label: String, _ v: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 9, weight: .bold)).foregroundStyle(DS.muted).tracking(0.8)
            Text(v).font(.system(size: 19, weight: .bold, design: .rounded))
                .monospacedDigit().foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(DS.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DS.border, lineWidth: 1))
    }
}

// Edição inline (medidor/custo/local) no estilo v2.
private struct ChargeEditV2: View {
    let charge: Charge
    let onSave: (Double?, Double?, String?) -> Void
    @State private var m = ""
    @State private var t = ""
    @State private var loc = ""
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                field("MEDIDOR (KWH)", $m, .decimalPad)
                field("CUSTO (R$)", $t, .decimalPad)
            }
            field("LOCAL", $loc, .default)
            Button {
                onSave(Double(m.replacingOccurrences(of: ",", with: ".")),
                       Double(t.replacingOccurrences(of: ",", with: ".")),
                       loc.isEmpty ? nil : loc)
            } label: {
                Text("Salvar").font(.system(size: 13, weight: .bold)).foregroundStyle(.black)
                    .frame(maxWidth: .infinity).frame(height: 40)
                    .background(DS.green, in: RoundedRectangle(cornerRadius: 10))
            }.buttonStyle(.plain)
        }
        .onAppear {
            guard !loaded else { return }
            m = charge.chargerKwh > 0 ? String(format: "%.2f", charge.chargerKwh) : ""
            t = charge.costTotal > 0 ? String(format: "%.2f", charge.costTotal) : ""
            loc = charge.location == "Local desconhecido" ? "" : charge.location
            loaded = true
        }
    }

    private func field(_ label: String, _ text: Binding<String>, _ kb: UIKeyboardType) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 8.5, weight: .bold)).foregroundStyle(DS.muted).tracking(0.8)
            TextField("", text: text).keyboardType(kb)
                .font(.system(size: 13)).foregroundStyle(DS.text)
                .padding(9).background(DS.panel2, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(DS.border, lineWidth: 1))
        }
    }
}
