//  MonthlyReportSheet.swift
//  Relatório mensal: km, kWh, gasolina, R$, %EV, economia vs gasolina e CO₂
//  evitado, por mês — com exportação CSV das viagens do mês.

import SwiftUI
import UIKit

struct MonthlyReportSheet: View {
    let trips: [Trip]
    let priceKwh: Double
    let priceGas: Double
    let kmPerLGas: Double
    @Environment(\.dismiss) private var dismiss
    @State private var month: Date = Date()
    @State private var csvURL: URL?
    @State private var pdfURL: URL?

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
    // Mês anterior ao selecionado (pra deltas comparativos).
    private var prevMonth: Date? { cal.date(byAdding: .month, value: -1, to: month) }
    private var prevMonthTrips: [Trip] {
        guard let p = prevMonth else { return [] }
        return trips.filter { cal.isDate($0.date, equalTo: p, toGranularity: .month) && $0.distKm > 0.1 }
    }

    private struct Tot { var km = 0.0, kwh = 0.0, fuelL = 0.0, cost = 0.0, evKm = 0.0, duration = 0.0; var n = 0 }
    private func totals(_ list: [Trip]) -> Tot {
        var t = Tot()
        for v in list {
            t.km += v.distKm; t.kwh += v.netKwh; t.fuelL += v.fuelL
            t.cost += v.netKwh * priceKwh + v.fuelL * gasL
            t.duration += v.timeSec
            if v.fuelL < 0.05 { t.evKm += v.distKm }
            t.n += 1
        }
        return t
    }
    private var tot: Tot { totals(monthTrips) }
    private var prevTot: Tot { totals(prevMonthTrips) }
    private func savingsOf(_ t: Tot) -> Double { max(t.km / baselineKmL * gasL - t.cost, 0) }
    private var savings: Double { savingsOf(tot) }
    private var co2: Double { max((tot.km / baselineKmL - tot.fuelL) * CO2_PER_L - tot.kwh * CO2_PER_KWH, 0) }
    private func evShareOf(_ t: Tot) -> Double { t.km > 0 ? t.evKm / t.km * 100 : 0 }
    private var evShare: Double { evShareOf(tot) }

    // Score médio do mês (viagens com driveScore).
    private func avgScore(_ list: [Trip]) -> Double? {
        let s = list.compactMap { $0.driveScore }
        return s.isEmpty ? nil : Double(s.reduce(0, +)) / Double(s.count)
    }
    // Delta percentual formatado (nil se base 0). Ex.: "-8%", "+4%".
    private func deltaPct(_ cur: Double, _ prev: Double) -> String? {
        guard prev > 0 else { return nil }
        let d = (cur - prev) / prev * 100
        if abs(d) < 0.5 { return "0%" }
        return (d > 0 ? "+" : "") + "\(Int(d.rounded()))%"
    }
    // Delta em pontos absolutos (pra % EV e score). Ex.: "+4", "-3".
    private func deltaPts(_ cur: Double, _ prev: Double) -> String {
        let d = cur - prev
        if abs(d) < 0.5 { return "0" }
        return (d > 0 ? "+" : "") + "\(Int(d.rounded()))"
    }

    // ── Destaques ────────────────────────────────────────────────────────────
    private func routeLabel(_ t: Trip) -> String {
        if let r = t.rawName { return r }
        let s = [t.knownStart ?? "", t.knownEnd ?? ""].filter { !$0.isEmpty }
        return s.isEmpty ? "" : s.joined(separator: " → ")
    }
    // Trajeto mais frequente do mês (por nome de rota).
    private var topRoute: (label: String, count: Int)? {
        var freq: [String: Int] = [:]
        for t in monthTrips { let l = routeLabel(t); if !l.isEmpty { freq[l, default: 0] += 1 } }
        guard let best = freq.max(by: { $0.value < $1.value }), best.value > 1 else { return nil }
        return (best.key, best.value)
    }
    // Melhor viagem do mês (maior driveScore).
    private var bestTrip: Trip? { monthTrips.filter { $0.driveScore != nil }.max { ($0.driveScore ?? 0) < ($1.driveScore ?? 0) } }
    // Custo por km rodado no mês.
    private var costPerKm: Double { tot.km > 0 ? tot.cost / tot.km : 0 }
    // Custo/km equivalente só a gasolina (baseline), pra comparar.
    private var gasCostPerKm: Double { baselineKmL > 0 ? gasL / baselineKmL : 0 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if months.isEmpty {
                        DSCard { Text("Sem viagens pra relatar ainda.").font(.callout).foregroundStyle(DS.muted).frame(maxWidth: .infinity).padding(.vertical, 10) }
                    } else {
                        monthNav
                        heroSavings
                        gridCard
                        highlightsCard
                        HStack(spacing: 10) {
                            DSActionButton(icon: "doc.richtext", title: "Exportar PDF", color: DS.blue, compact: true) { exportPDF() }
                            DSActionButton(icon: "tablecells", title: "Exportar CSV", color: DS.teal, compact: true) { exportCSV() }
                        }
                        if let u = pdfURL { shareRow(u, "Compartilhar PDF", "doc.fill") }
                        if let u = csvURL { shareRow(u, "Compartilhar CSV", "doc") }
                        Text("Economia e CO₂ estimados vs. baseline de \(Fmt.dec1(baselineKmL)) km/L (gasolina \(Fmt.brl(gasL))/L).")
                            .font(.system(size: 10.5)).foregroundStyle(DS.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
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
        .presentationDetents([.large])
    }

    // Índice do mês atual dentro de `months` (ordem: recente → antigo).
    private var monthIdx: Int { months.firstIndex { cal.isDate($0, equalTo: month, toGranularity: .month) } ?? 0 }
    private func goto(_ i: Int) {
        guard months.indices.contains(i) else { return }
        month = months[i]; csvURL = nil; pdfURL = nil
    }

    // Cabeçalho "Junho · fechado" com navegação ‹ ›.
    private var monthNav: some View {
        HStack(spacing: 12) {
            Button { goto(monthIdx + 1) } label: {   // mais antigo
                Image(systemName: "chevron.left").font(.system(size: 15, weight: .bold))
                    .foregroundStyle(monthIdx + 1 < months.count ? DS.text : DS.muted)
                    .frame(width: 34, height: 34).background(DS.panel2).clipShape(Circle())
            }.buttonStyle(.plain).disabled(monthIdx + 1 >= months.count)
            VStack(spacing: 1) {
                Text(monthLongLabel(month)).font(.system(size: 16, weight: .bold)).foregroundStyle(DS.text)
                Text(cal.isDate(month, equalTo: Date(), toGranularity: .month) ? "em curso" : "fechado")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.muted)
            }.frame(maxWidth: .infinity)
            Button { goto(monthIdx - 1) } label: {   // mais recente
                Image(systemName: "chevron.right").font(.system(size: 15, weight: .bold))
                    .foregroundStyle(monthIdx - 1 >= 0 ? DS.text : DS.muted)
                    .frame(width: 34, height: 34).background(DS.panel2).clipShape(Circle())
            }.buttonStyle(.plain).disabled(monthIdx - 1 < 0)
        }
    }

    // Hero: economia do mês em numeral fino.
    private var heroSavings: some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("R$").font(.system(size: 22, weight: .light)).foregroundStyle(DS.green.opacity(0.8))
                Text(Fmt.int(savings)).font(.system(size: 56, weight: .ultraLight, design: .rounded))
                    .monospacedDigit().foregroundStyle(DS.green)
            }
            Text("ECONOMIZADOS VS GASOLINA").font(.system(size: 10, weight: .semibold))
                .tracking(0.6).foregroundStyle(DS.muted)
            if let d = deltaPct(savings, savingsOf(prevTot)) {
                Text("\(d) vs mês anterior").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.text2)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 8)
    }

    private var gridCard: some View {
        DSCard {
            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    cell(Fmt.km(tot.km), "km", "Distância", DS.blue, deltaPct(tot.km, prevTot.km))
                    cell("\(Int(evShare.rounded()))", "%", "Em EV", DS.green, deltaPts(evShare, evShareOf(prevTot)))
                    cell(Fmt.dec1(tot.kwh), "kWh", "Energia", DS.teal, nil)
                    cell(scoreStr(avgScore(monthTrips)), "", "Score", DS.orange,
                         (avgScore(monthTrips) != nil && avgScore(prevMonthTrips) != nil) ? deltaPts(avgScore(monthTrips)!, avgScore(prevMonthTrips)!) : nil)
                }
                Divider().overlay(DS.divider)
                HStack(spacing: 10) {
                    cell(Fmt.dec1(tot.fuelL), "L", "Gasolina", DS.orange, nil)
                    cell(Fmt.brl(tot.cost), "", "Custo", DS.text, nil)
                    cell("\(tot.n)", "", "Viagens", DS.muted, nil)
                    cell(Fmt.int(co2), "kg", "CO₂ evit.", DS.teal, nil)
                }
            }
        }
    }

    private func scoreStr(_ s: Double?) -> String { s.map { "\(Int($0.rounded()))" } ?? "—" }

    private func cell(_ v: String, _ unit: String, _ label: String, _ color: Color, _ delta: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(v).font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(color)
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
                if !unit.isEmpty { Text(unit).font(.system(size: 9)).foregroundStyle(DS.muted) }
            }
            Text(label.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(0.3)
                .foregroundStyle(DS.muted).lineLimit(1).minimumScaleFactor(0.6)
            if let d = delta {
                Text(d).font(.system(size: 10, weight: .bold))
                    .foregroundStyle(d.hasPrefix("-") ? DS.red : (d == "0" || d == "0%" ? DS.muted : DS.green))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    // Destaques: trajeto top, melhor viagem, custo/km vs gasolina.
    private var highlightsCard: some View {
        DSCard(title: "Destaques", icon: "star.fill") {
            VStack(spacing: 0) {
                if let r = topRoute { hlRow("map", "Trajeto mais frequente", r.label, "\(r.count)x", DS.blue) }
                if let b = bestTrip, let sc = b.driveScore {
                    if topRoute != nil { divRow }
                    let name = routeLabel(b)
                    hlRow("hand.thumbsup.fill", "Melhor viagem", name.isEmpty ? "Score do mês" : name, "\(sc)", DS.green)
                }
                if costPerKm > 0 {
                    if topRoute != nil || bestTrip != nil { divRow }
                    hlRow("dollarsign.circle", "Custo por km", "vs gasolina \(Fmt.brl(gasCostPerKm))", Fmt.brl(costPerKm), DS.teal)
                }
                if topRoute == nil && bestTrip == nil && costPerKm <= 0 {
                    Text("Sem destaques neste mês.").font(.system(size: 12)).foregroundStyle(DS.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var divRow: some View { Divider().overlay(DS.divider).padding(.vertical, 8) }

    private func hlRow(_ icon: String, _ label: String, _ sub: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(color).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.text)
                Text(sub).font(.system(size: 11)).foregroundStyle(DS.muted).lineLimit(1)
            }
            Spacer()
            Text(value).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(color).monospacedDigit()
        }
    }

    private func shareRow(_ u: URL, _ title: String, _ icon: String) -> some View {
        ShareLink(item: u) {
            Label(title, systemImage: icon).font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 11)
                .background(DS.panel2).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .foregroundStyle(DS.text)
        }
    }

    private func monthLongLabel(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR"); f.dateFormat = "MMMM"
        return f.string(from: d).capitalized
    }

    // ── Helpers de formatação compartilhados por CSV e PDF ───────────────────
    private func avgKmh(_ t: Trip) -> Double { t.timeSec >= 60 ? t.distKm / (t.timeSec / 3600) : 0 }
    private func dur(_ sec: Double) -> String {
        let s = Int(sec); return "\(s / 3600)h\(String(format: "%02d", (s % 3600) / 60))"
    }
    private func origin(_ t: Trip) -> String { t.knownStart ?? "" }
    private func dest(_ t: Trip) -> String { t.knownEnd ?? "" }
    private func sortedMonthTrips() -> [Trip] { monthTrips.sorted { $0.date < $1.date } }

    private func exportCSV() {
        let df = DateFormatter(); df.locale = Locale(identifier: "pt_BR"); df.dateFormat = "dd/MM/yyyy"
        let tf = DateFormatter(); tf.locale = Locale(identifier: "pt_BR"); tf.dateFormat = "HH:mm"
        let nf: (Double) -> String = { String(format: "%.2f", $0).replacingOccurrences(of: ".", with: ",") }
        let clean: (String) -> String = { $0.replacingOccurrences(of: ";", with: " ") }
        var csv = "\u{FEFF}Data;Hora;Origem;Destino;Distancia_km;Energia_kWh;Gasolina_L;Custo_R$;Duracao;Vel_media_kmh;Conducao\r\n"
        for t in sortedMonthTrips() {
            let cost = t.netKwh * priceKwh + t.fuelL * gasL
            let cols = [df.string(from: t.date), tf.string(from: t.date),
                        clean(origin(t)), clean(dest(t)),
                        nf(t.distKm), nf(t.netKwh), nf(t.fuelL), nf(cost),
                        dur(t.timeSec), String(Int(avgKmh(t).rounded())),
                        t.driveScore.map(String.init) ?? ""]
            csv += cols.joined(separator: ";") + "\r\n"
        }
        csv += "TOTAL;;;;\(nf(tot.km));\(nf(tot.kwh));\(nf(tot.fuelL));\(nf(tot.cost));\(dur(tot.duration));;\r\n"
        let mf = DateFormatter(); mf.dateFormat = "yyyy-MM"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("haval-\(mf.string(from: month)).csv")
        try? csv.data(using: .utf8)?.write(to: url)
        csvURL = url
    }

    // PDF de diário de bordo (IRPF/reembolso): cabeçalho com totais + tabela
    // paginada. Render nativo com UIGraphicsPDFRenderer (sem dependência).
    private func exportPDF() {
        let pageW: CGFloat = 595, pageH: CGFloat = 842, margin: CGFloat = 36
        let df = DateFormatter(); df.locale = Locale(identifier: "pt_BR"); df.dateFormat = "dd/MM"
        let tf = DateFormatter(); tf.locale = Locale(identifier: "pt_BR"); tf.dateFormat = "HH:mm"
        // Colunas: x relativo à margem + largura. Soma ~523pt (pageW-2*margin).
        let cols: [(String, CGFloat, CGFloat, NSTextAlignment)] = [
            ("Data", 0, 40, .left), ("Hora", 40, 34, .left),
            ("Trajeto", 74, 200, .left), ("km", 274, 44, .right),
            ("kWh", 318, 46, .right), ("R$", 364, 50, .right),
            ("Dur.", 414, 44, .right), ("km/h", 458, 36, .right), ("Cond.", 494, 38, .right),
        ]
        let head = [UIColor(white: 0.25, alpha: 1)]
        let bodyAttr: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 9)]
        let headAttr: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 9), .foregroundColor: head[0]]
        let nf: (Double) -> String = { String(format: "%.1f", $0) }
        let nf2: (Double) -> String = { String(format: "%.2f", $0) }

        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: pageW, height: pageH))
        let mf = DateFormatter(); mf.locale = Locale(identifier: "pt_BR"); mf.dateFormat = "MMMM 'de' yyyy"
        let rows = sortedMonthTrips()

        let data = renderer.pdfData { ctx in
            var y: CGFloat = margin
            func newPage() { ctx.beginPage(); y = margin }
            func drawHeaderBlock() {
                ("Diário de bordo — \(mf.string(from: month).capitalized)" as NSString)
                    .draw(at: CGPoint(x: margin, y: y), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 15)])
                y += 22
                let totLine = "\(tot.n) viagens · \(Fmt.km(tot.km)) km · \(nf2(tot.kwh)) kWh · \(nf2(tot.fuelL)) L · \(Fmt.brl(tot.cost)) · \(dur(tot.duration))"
                (totLine as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: [.font: UIFont.systemFont(ofSize: 10), .foregroundColor: head[0]])
                y += 24
                drawRow(cols.map { $0.0 }, headAttr); y += 2
                UIColor(white: 0.8, alpha: 1).setStroke()
                let p = UIBezierPath(); p.move(to: CGPoint(x: margin, y: y)); p.addLine(to: CGPoint(x: pageW - margin, y: y)); p.lineWidth = 0.5; p.stroke()
                y += 4
            }
            func drawRow(_ vals: [String], _ attr: [NSAttributedString.Key: Any]) {
                for (i, c) in cols.enumerated() {
                    let para = NSMutableParagraphStyle(); para.alignment = c.3; para.lineBreakMode = .byTruncatingTail
                    var a = attr; a[.paragraphStyle] = para
                    (vals[i] as NSString).draw(in: CGRect(x: margin + c.1, y: y, width: c.2, height: 12), withAttributes: a)
                }
                y += 13
            }
            newPage(); drawHeaderBlock()
            for t in rows {
                if y > pageH - margin - 16 { newPage(); drawHeaderBlock() }
                let traj = t.rawName ?? [origin(t), dest(t)].filter { !$0.isEmpty }.joined(separator: " → ")
                let cost = t.netKwh * priceKwh + t.fuelL * gasL
                drawRow([df.string(from: t.date), tf.string(from: t.date), traj,
                         nf(t.distKm), nf2(t.netKwh), nf2(cost),
                         dur(t.timeSec), String(Int(avgKmh(t).rounded())),
                         t.driveScore.map(String.init) ?? "—"], bodyAttr)
            }
        }
        let mf2 = DateFormatter(); mf2.dateFormat = "yyyy-MM"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("haval-\(mf2.string(from: month)).pdf")
        try? data.write(to: url)
        pdfURL = url
    }
}
