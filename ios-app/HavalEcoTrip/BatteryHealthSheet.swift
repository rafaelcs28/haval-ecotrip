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

    // Ciclos equivalentes: soma dos ganhos de SOC ÷ 100 (carga completa equivalente).
    private var cycles: Int {
        let sum = charges.reduce(0.0) { $0 + max(0, $1.socEnd - $1.socStart) }
        return Int((sum / 100).rounded())
    }

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

    // Variação de SOH no período coberto pelos pontos (início → agora).
    private var sohDeltaText: String? {
        let pts = points
        guard pts.count >= 3, let first = pts.first?.cap, first > 0 else { return nil }
        let startSoh = min(first / factoryKwh * 100, 100)
        let d = soh - startSoh
        return "\(d < 0 ? "" : "+")\(Fmt.dec1(d))% no período"
    }

    // --- Hábitos de recarga derivados das sessões (sem sensor de temperatura). ---
    private struct Habit: Identifiable { let id = UUID(); let icon: String; let label: String; let value: String; let verdict: String; let color: Color }

    private var habits: [Habit] {
        var out: [Habit] = []
        let valid = charges.filter { $0.kwh > 1 }
        // % de sessões que passaram de 90% de SOC (estresse do topo da bateria).
        if !valid.isEmpty {
            let over90 = valid.filter { $0.socEnd > 90 }.count
            let pct = Double(over90) / Double(valid.count) * 100
            let v = pct <= 10 ? "ótimo" : (pct <= 25 ? "saudável" : "atenção")
            out.append(Habit(icon: "battery.100", label: "Acima de 90%", value: "\(Fmt.int(pct))%",
                             verdict: v, color: pct <= 25 ? DS.green : DS.orange))
        }
        // % de sessões em potência alta (proxy de DC rápida — desgasta mais).
        let powered = valid.filter { $0.avgPowerKw > 0 }
        if !powered.isEmpty {
            let fast = powered.filter { $0.avgPowerKw >= 20 }.count
            let pct = Double(fast) / Double(powered.count) * 100
            let v = pct <= 20 ? "saudável" : (pct <= 40 ? "moderado" : "atenção")
            out.append(Habit(icon: "bolt.fill", label: "Carga rápida", value: "\(Fmt.int(pct))%",
                             verdict: v, color: pct <= 40 ? DS.green : DS.orange))
        }
        // SOC médio de fim de recarga.
        if !valid.isEmpty {
            let avgEnd = valid.reduce(0.0) { $0 + $1.socEnd } / Double(valid.count)
            let v = avgEnd <= 82 ? "ideal" : "acima do ideal"
            out.append(Habit(icon: "gauge.with.dots.needle.50percent", label: "SOC final médio", value: "\(Fmt.int(avgEnd))%",
                             verdict: v, color: avgEnd <= 82 ? DS.green : DS.yellow))
        }
        return out
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if points.count < 3 {
                        emptyState
                    } else {
                        hero
                        if let spark = sohDeltaText { sparkCard(delta: spark) }
                        if !habits.isEmpty { habitsCard }
                    }
                    Text("estimativa: capacidade = energia da recarga ÷ ganho de SOC · leia a tendência, não um ponto isolado · seu limite de 80% está ajudando a preservar a bateria")
                        .font(.system(size: 10.5)).foregroundStyle(DS.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Saúde da bateria")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fechar") { dismiss() } } }
        }
    }

    private var emptyState: some View {
        DSCard {
            VStack(spacing: 10) {
                Image(systemName: "battery.75").font(.system(size: 40)).foregroundStyle(DS.muted)
                Text("Ainda sem recargas suficientes pra estimar (precisa de algumas recargas com ganho de SOC ≥ 15%).")
                    .font(.callout).foregroundStyle(DS.muted).multilineTextAlignment(.center)
            }.frame(maxWidth: .infinity).padding(.vertical, 10)
        }
    }

    // Hero: SOH grande (ultraLight) + capacidade útil / fábrica + ciclos.
    private var hero: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(Fmt.dec1(soh))%")
                        .font(.system(size: 60, weight: .ultraLight, design: .rounded))
                        .foregroundStyle(sohColor).monospacedDigit()
                }
                Text("SAÚDE DA BATERIA").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DS.muted).tracking(0.5)
                Text("\(Fmt.dec1(current)) de \(Fmt.dec1(factoryKwh)) kWh · ~\(cycles) ciclos")
                    .font(.system(size: 12)).foregroundStyle(DS.text2).padding(.top, 4)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                splitValue("\(Fmt.dec1(current)) kWh", "capacidade atual", DS.green)
                splitValue("\(Fmt.dec1(degradationPct))%", "degradação", degradationPct > 10 ? DS.orange : DS.muted)
            }
        }
    }

    // Sparkline da SOH nos meses cobertos + variação no período.
    private func sparkCard(delta: String) -> some View {
        DSCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("SOH NO PERÍODO").font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.muted).tracking(0.5)
                    Spacer()
                    Text(delta).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(delta.hasPrefix("+") ? DS.green : DS.orange)
                }
                Chart {
                    ForEach(points) { p in
                        let s = min(p.cap / factoryKwh * 100, 100)
                        LineMark(x: .value("Data", p.date), y: .value("SOH", s))
                            .foregroundStyle(DS.green).interpolationMethod(.catmullRom)
                        AreaMark(x: .value("Data", p.date), y: .value("SOH", s))
                            .foregroundStyle(LinearGradient(colors: [DS.green.opacity(0.22), .clear], startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.catmullRom)
                    }
                }
                .frame(height: 90)
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXAxis(.hidden)
                .chartYAxis { AxisMarks(position: .trailing) { v in
                    AxisValueLabel { if let d = v.as(Double.self) { Text("\(Fmt.int(d))%").font(.system(size: 9)).foregroundStyle(DS.muted) } }
                } }
            }
        }
    }

    // Lista de hábitos com veredito (fundo painel2, hairlines).
    private var habitsCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(habits.enumerated()), id: \.element.id) { i, h in
                HStack(spacing: 10) {
                    Image(systemName: h.icon).font(.system(size: 14)).foregroundStyle(DS.text2).frame(width: 20)
                    Text(h.label).font(.system(size: 13)).foregroundStyle(DS.text)
                    Spacer()
                    Text(h.value).font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(DS.text).monospacedDigit()
                    Text(h.verdict).font(.system(size: 11, weight: .semibold)).foregroundStyle(h.color)
                }
                .padding(.horizontal, 12).padding(.vertical, 11)
                if i < habits.count - 1 { Divider().background(DS.divider) }
            }
        }
        .background(DS.panel2)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private func splitValue(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(value).font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(color).monospacedDigit()
            Text(label).font(.system(size: 9.5)).foregroundStyle(DS.muted)
        }
    }
}
