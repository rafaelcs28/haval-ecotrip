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

    private struct Tot { var km = 0.0, kwh = 0.0, fuelL = 0.0, cost = 0.0, evKm = 0.0, duration = 0.0; var n = 0 }
    private var tot: Tot {
        var t = Tot()
        for v in monthTrips {
            t.km += v.distKm; t.kwh += v.netKwh; t.fuelL += v.fuelL
            t.cost += v.netKwh * priceKwh + v.fuelL * gasL
            t.duration += v.timeSec
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
                        DSActionButton(icon: "tablecells", title: "Exportar CSV do mês", color: DS.teal) { exportCSV() }
                        if let u = csvURL { ShareLink(item: u) { Label("Compartilhar CSV", systemImage: "doc") .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 10).background(DS.panel2).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)).foregroundStyle(DS.text) } }
                        DSActionButton(icon: "doc.richtext", title: "Exportar PDF do mês", color: DS.blue) { exportPDF() }
                        if let u = pdfURL { ShareLink(item: u) { Label("Compartilhar PDF", systemImage: "doc.fill") .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 10).background(DS.panel2).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)).foregroundStyle(DS.text) } }
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
                    Button { month = m; csvURL = nil; pdfURL = nil } label: {
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
