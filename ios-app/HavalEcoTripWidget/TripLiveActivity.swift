//
//  TripLiveActivity.swift
//  Live Activity de viagem ao vivo (lock screen + Dynamic Island).
//  Estilo v2 Rodada 9 (frame 9a): km percorrido como hero, velocidade na régua
//  de micro-métricas, progresso do trajeto com destino/ETA.
//
import ActivityKit
import SwiftUI
import WidgetKit

private func tripDuration(_ sec: Int) -> String {
    guard sec > 0 else { return "0min" }
    let h = sec / 3600, m = (sec % 3600) / 60
    return h > 0 ? "\(h)h\(String(format: "%02d", m))" : "\(m)min"
}

struct TripLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TripActivityAttributes.self) { context in
            TripLockScreenView(state: context.state, carName: context.attributes.carName)
                .activityBackgroundTint(LAv2.bg)
                .activitySystemActionForegroundColor(LAv2.green)

        } dynamicIsland: { context in
            let s = context.state
            let hasDest = s.destName != nil && s.active
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: hasDest ? "location.north.fill" : "car.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(LAv2.green)
                        .frame(width: 40, height: 40)
                        .background(LAv2.green.opacity(0.15), in: Circle())
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(diCenterTitle(s))
                            .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(LAv2.text)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Text(diCenterSub(s))
                            .font(.system(size: 11.5)).monospacedDigit()
                            .foregroundStyle(LAv2.text2)
                            .lineLimit(1).minimumScaleFactor(0.6)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 3) {
                        if s.active { LACaps(text: "live", color: LAv2.green) }
                        if let soc = s.socPct {
                            Text("SOC \(Int(soc))%")
                                .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(soc < 15 ? LAv2.red : LAv2.green)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: hasDest ? "location.north.fill" : "car.fill")
                    .foregroundStyle(LAv2.green)
            } compactTrailing: {
                Text("\(laDec1(s.distKm)) km")
                    .bold().monospacedDigit().foregroundStyle(LAv2.green)
            } minimal: {
                Image(systemName: hasDest ? "location.north.fill" : "car.fill")
                    .foregroundStyle(LAv2.green)
            }
            .keylineTint(LAv2.green)
        }
    }
}

private func diCenterTitle(_ s: TripActivityAttributes.ContentState) -> String {
    if let d = s.destName, s.active { return "\(laDec1(s.distKm)) km · → \(d)" }
    return s.active ? "\(laDec1(s.distKm)) km · viagem em curso"
                    : "\(laDec1(s.distKm)) km · encerrada"
}

private func diCenterSub(_ s: TripActivityAttributes.ContentState) -> String {
    if let rest = s.destKm, let m = s.destEtaMin, s.active, m > 0 {
        let eta = s.updatedAt.addingTimeInterval(m * 60)
        let hm = eta.formatted(date: .omitted, time: .shortened)
        return "faltam \(laDec1(rest)) km · chega \(hm)"
    }
    var parts: [String] = [tripDuration(s.timeSec)]
    if s.effKwh100 > 0 { parts.append("\(laDec1(s.effKwh100)) kWh/100") }
    return parts.joined(separator: " · ")
}

struct TripLockScreenView: View {
    let state: TripActivityAttributes.ContentState
    let carName: String

    private var etaClock: Date? {
        guard let m = state.destEtaMin, m > 0 else { return nil }
        return state.updatedAt.addingTimeInterval(m * 60)
    }
    // Progresso do trajeto: rodado / (rodado + restante até o destino).
    private var progress: Double? {
        guard state.active, let rest = state.destKm, rest >= 0,
              state.distKm + rest > 0.3 else { return nil }
        return min(1, max(0, state.distKm / (state.distKm + rest)))
    }
    private var totalKm: Double? {
        guard let rest = state.destKm, rest >= 0 else { return nil }
        return state.distKm + rest
    }

    var body: some View {
        let accent: Color = state.isEV ? LAv2.green : LAv2.orange
        VStack(alignment: .leading, spacing: 7) {
            // Cabeçalho: tile carro + estado | dot + "há Ns"
            HStack(spacing: 8) {
                Image(systemName: state.active ? "car.fill" : "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(.black)
                    .frame(width: 22, height: 22)
                    .background(state.active ? accent : Color.blue,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(state.active ? "\(carName) · viagem em curso"
                                  : "\(carName) · viagem encerrada")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(LAv2.text)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 6)
                if state.active {
                    Circle().fill(accent).frame(width: 6, height: 6)
                    (Text("há ") + Text(state.updatedAt, style: .relative))
                        .font(.system(size: 10.5)).foregroundStyle(LAv2.text2)
                        .lineLimit(1)
                }
            }
            // Hero: km percorrido + contexto "de total" | destino + chegada
            HStack(alignment: .center, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(laDec1(state.distKm))
                        .font(.system(size: 38, weight: .ultraLight)).monospacedDigit()
                        .tracking(-2).foregroundStyle(LAv2.text)
                    Text("km").font(.system(size: 14)).foregroundStyle(LAv2.muted)
                    if let total = totalKm, state.active {
                        Text("de \(laDec1(total))")
                            .font(.system(size: 12)).monospacedDigit()
                            .foregroundStyle(LAv2.text2)
                    }
                }
                Spacer(minLength: 8)
                if let dest = state.destName, state.active {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("→ \(dest)")
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(LAv2.text)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        if let eta = etaClock, let rest = state.destKm {
                            (Text("chega ") + Text(eta, format: .dateTime.hour().minute())
                                + Text(" · faltam \(laDec1(rest)) km"))
                                .font(.system(size: 11)).monospacedDigit()
                                .foregroundStyle(LAv2.text2)
                                .lineLimit(1).minimumScaleFactor(0.7)
                        }
                    }
                } else if !state.active && state.effKwh100 > 0 {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(laDec1(state.effKwh100))
                            .font(.system(size: 20, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(LAv2.teal)
                        LACaps(text: "kWh/100")
                    }
                }
            }
            // Barra de progresso do trajeto (só com destino ativo)
            if let p = progress {
                TripProgressBar(frac: p, destName: state.destName ?? "destino")
            }
            // Régua de micro-métricas (space-between)
            HStack(spacing: 6) {
                ForEach(Array(microMetrics.enumerated()), id: \.offset) { i, m in
                    if i > 0 { Spacer(minLength: 6) }
                    Text(m.0)
                        .font(.system(size: 10.5, weight: m.1 == nil ? .regular : .semibold))
                        .monospacedDigit()
                        .foregroundStyle(m.1 ?? LAv2.text2)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    // (texto, cor opcional) — nil = text2.
    private var microMetrics: [(String, Color?)] {
        var out: [(String, Color?)] = []
        if state.active, let v = state.speedKmh { out.append(("\(laAdjSpeed(v)) km/h", nil)) }
        out.append((tripDuration(state.timeSec), nil))
        if state.effKwh100 > 0 { out.append(("\(laDec1(state.effKwh100)) kWh/100", nil)) }
        if state.fuelL > 0.05 { out.append(("\(laDec1(state.fuelL)) L", nil)) }
        if let c = state.costBrl, c > 0, !state.active { out.append(("R$ \(laDec2(c))", nil)) }
        if state.tyreAlert == true {
            out.append((state.tyreMinPsi.map { "\(Int($0)) PSI" } ?? "PNEU", LAv2.red))
        } else if let soc = state.socPct {
            out.append(("SOC \(Int(soc))%", soc < 15 ? LAv2.red : LAv2.green))
        }
        return out
    }
}

// Barra do trajeto: trilho + preenchimento green + ponto branco com glow.
private struct TripProgressBar: View {
    let frac: Double
    let destName: String
    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12)).frame(height: 6)
                    Capsule().fill(LAv2.green)
                        .frame(width: max(6, w * frac), height: 6)
                    Circle().fill(.white)
                        .frame(width: 10, height: 10)
                        .shadow(color: LAv2.green.opacity(0.9), radius: 5)
                        .offset(x: min(w - 10, max(0, w * frac - 5)))
                }
                .frame(width: w, height: 10)
            }
            .frame(height: 10)
            HStack {
                LACaps(text: "início")
                Spacer()
                LACaps(text: destName)
            }
        }
    }
}
