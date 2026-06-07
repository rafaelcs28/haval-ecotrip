//  BatteryHealthSheet.swift
//  Tendência de saúde da bateria: estima a capacidade útil (kWh) de cada recarga
//  (energia / ganho de SOC) e mostra a evolução no tempo + degradação aproximada.
//  100% client-side, das recargas já sincronizadas.

import SwiftUI
import Charts

struct BatteryHealthSheet: View {
    let charges: [Charge]
    @Environment(\.dismiss) private var dismiss

    private let factoryKwh = 34.0   // capacidade útil de fábrica (H6 PHEV) — base inicial

    private struct Point: Identifiable { let id = UUID(); let date: Date; let cap: Double }

    // Capacidade por sessão = energia / (ΔSOC/100). Só sessões com ganho relevante.
    private var points: [Point] {
        charges.compactMap { c -> Point? in
            let gain = c.socEnd - c.socStart
            guard gain >= 15, c.kwh > 1 else { return nil }
            let cap = c.kwh / (gain / 100.0)
            guard cap > 8, cap < 60 else { return nil }
            return Point(date: c.date, cap: cap)
        }.sorted { $0.date < $1.date }
    }

    private var current: Double {
        let tail = points.suffix(5); guard !tail.isEmpty else { return 0 }
        return tail.reduce(0) { $0 + $1.cap } / Double(tail.count)
    }
    // Degradação medida contra a capacidade de FÁBRICA (34 kWh), não as 1ªs medições.
    private var degradationPct: Double {
        guard current > 0 else { return 0 }
        return max((factoryKwh - current) / factoryKwh * 100, 0)
    }
    // State of Health = capacidade atual / fábrica.
    private var soh: Double { current > 0 ? min(current / factoryKwh * 100, 100) : 0 }
    private var sohColor: Color { soh >= 90 ? DS.green : (soh >= 80 ? DS.yellow : DS.orange) }

    // Regressão linear (mínimos quadrados) sobre os pontos: kWh por ano + predição.
    private var trend: (perYear: Double, predict: (Date) -> Double)? {
        let pts = points
        guard pts.count >= 3, let t0 = pts.first?.date else { return nil }
        let xs = pts.map { $0.date.timeIntervalSince(t0) }, ys = pts.map { $0.cap }
        let n = Double(pts.count)
        let sx = xs.reduce(0, +), sy = ys.reduce(0, +)
        let sxx = zip(xs, xs).reduce(0) { $0 + $1.0 * $1.1 }
        let sxy = zip(xs, ys).reduce(0) { $0 + $1.0 * $1.1 }
        let denom = n * sxx - sx * sx
        guard abs(denom) > 1e-6 else { return nil }
        let slope = (n * sxy - sx * sy) / denom         // kWh por segundo
        let intercept = (sy - slope * sx) / n
        return (slope * 365 * 86400, { d in intercept + slope * d.timeIntervalSince(t0) })
    }
    private var trendPoints: [Point] {
        guard let tr = trend, let f = points.first?.date, let l = points.last?.date, f != l else { return [] }
        return [Point(date: f, cap: tr.predict(f)), Point(date: l, cap: tr.predict(l))]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if points.count < 3 {
                        DSCard {
                            Text("Ainda sem recargas suficientes pra estimar (precisa de algumas recargas com ganho de SOC ≥ 15%).")
                                .font(.callout).foregroundStyle(DS.muted)
                        }
                    } else {
                        DSCard {
                            VStack(spacing: 6) {
                                Text("Saúde da bateria (SOH)").font(.caption).foregroundStyle(DS.muted)
                                Text("\(Int(soh.rounded()))%").font(.system(size: 56, weight: .heavy, design: .rounded)).foregroundStyle(sohColor)
                                if let tr = trend {
                                    Text(abs(tr.perYear) < 0.3 ? "tendência estável"
                                         : "\(tr.perYear < 0 ? "" : "+")\(Fmt.dec1(tr.perYear)) kWh/ano")
                                        .font(.subheadline).foregroundStyle(tr.perYear < -0.3 ? DS.orange : DS.muted)
                                }
                            }.frame(maxWidth: .infinity).padding(.vertical, 4)
                        }
                        HStack(spacing: 12) {
                            DSCard { metric("Capacidade atual", "\(Fmt.dec1(current)) kWh", DS.green) }
                            DSCard { metric("Degradação", "\(Fmt.dec1(degradationPct))%",
                                            degradationPct > 10 ? DS.orange : DS.muted) }
                        }
                        DSCard(title: "Capacidade útil por recarga", icon: "chart.xyaxis.line") {
                            Chart {
                                ForEach(points) { p in
                                    LineMark(x: .value("Data", p.date), y: .value("kWh", p.cap), series: .value("s", "cap"))
                                        .foregroundStyle(DS.green)
                                    PointMark(x: .value("Data", p.date), y: .value("kWh", p.cap))
                                        .foregroundStyle(DS.green.opacity(0.5))
                                }
                                ForEach(trendPoints) { tp in
                                    LineMark(x: .value("Data", tp.date), y: .value("kWh", tp.cap), series: .value("s", "trend"))
                                        .foregroundStyle(DS.teal)
                                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                                }
                                RuleMark(y: .value("Fábrica", factoryKwh))
                                    .foregroundStyle(DS.muted.opacity(0.6))
                                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                    .annotation(position: .top, alignment: .leading) {
                                        Text("fábrica \(Fmt.int(factoryKwh)) kWh").font(.system(size: 9)).foregroundStyle(DS.muted)
                                    }
                            }
                            .frame(height: 180)
                            .chartYScale(domain: .automatic(includesZero: false))
                        }
                        DSCard {
                            metric("Capacidade de fábrica", "\(Fmt.int(factoryKwh)) kWh", DS.muted)
                        }
                    }
                    Text("Estimativa: capacidade = energia da recarga ÷ ganho de SOC. Valores variam com temperatura e taxa de carga — leia a TENDÊNCIA, não um ponto isolado.")
                        .font(.caption2).foregroundStyle(DS.muted).frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Saúde da bateria")
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
