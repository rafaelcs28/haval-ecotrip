//
//  ChargeActivityLiveActivity.swift
//  Live Activity de recarga — estilo v2 Rodada 10 (frame 10a): SOC é o hero
//  (o número que cresce), kW/kWh/custo descem pra régua de micro-métricas.
//  Concluída → variante verde de confirmação (anatomia da pós-Travar 9b).
//
import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

// Formato compacto v2: "1h24" / "42 min".
private func chargeRemainingShort(_ min: Int) -> String {
    guard min > 0 else { return "—" }
    if min >= 60 { return "\(min / 60)h\(String(format: "%02d", min % 60))" }
    return "\(min) min"
}

// Ícone compacto pra Dynamic Island: anel mostra o SOC ao redor do carrinho.
// Resolve o caso de 2 LAs simultâneas (Haval verde + BYD azul) competindo por
// espaço quando o user pluga o segundo carro — sem texto, só símbolo.
private struct CarChargeRing: View {
    let soc: Double
    let charging: Bool
    let accent: Color
    var body: some View {
        ZStack {
            Circle().stroke(accent.opacity(0.25), lineWidth: 2.2)
            Circle().trim(from: 0, to: CGFloat(min(100, max(0, soc)) / 100))
                .stroke(accent, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: charging ? "bolt.car.fill" : "checkmark.circle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(accent)
        }
        .frame(width: 22, height: 22)
    }
}

// Linha de ações da LA de recarga. Trancar/Destrancar segue o estado real da
// trava (state.locked); o botão de limite mostra a meta atual e cicla os presets.
@available(iOS 17.0, *)
@ViewBuilder
private func chargeLAButtons(_ s: ChargeActivityAttributes.ContentState) -> some View {
    HStack(spacing: 6) {
        if s.locked == true {
            LAActionButton(title: "Destrancar", systemImage: "lock.open.fill", tint: .orange, intent: UnlockCarIntent())
        } else {
            LAActionButton(title: "Trancar", systemImage: "lock.fill", intent: LockCarIntent())
        }
        LAActionButton(title: "Limite \(Int(s.targetPct))%", systemImage: "bolt.fill", tint: .green, intent: CycleChargeLimitIntent())
    }
}

struct ChargeActivityLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ChargeActivityAttributes.self) { context in
            ChargeLockScreenView(state: context.state, carName: context.attributes.carName)
                .activityBackgroundTint(LAv2.bg)
                .activitySystemActionForegroundColor(LAv2.green)

        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: s.charging ? "bolt.fill" : "checkmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(LAv2.green)
                        .frame(width: 40, height: 40)
                        .background(LAv2.green.opacity(0.15), in: Circle())
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        if s.charging {
                            (Text("\(Int(s.soc))%").foregroundStyle(LAv2.green)
                                + Text(" · \(chargeRemainingShort(s.remainingMin)) restante").foregroundStyle(LAv2.text))
                                .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                                .lineLimit(1).minimumScaleFactor(0.7)
                            Text(diSubline(s))
                                .font(.system(size: 11.5)).monospacedDigit().foregroundStyle(LAv2.text2)
                                .lineLimit(1).minimumScaleFactor(0.6)
                        } else {
                            Text("Recarga concluída · \(Int(s.soc))%")
                                .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(LAv2.green)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if s.charging {
                        VStack(alignment: .trailing, spacing: 3) {
                            LACaps(text: "live", color: LAv2.green)
                            if s.targetPct > 0, s.targetPct < 100 {
                                Text("→ \(Int(s.targetPct))%")
                                    .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                                    .foregroundStyle(LAv2.muted)
                            }
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if #available(iOS 17.0, *), s.charging {
                        chargeLAButtons(s)
                    }
                }
            } compactLeading: {
                CarChargeRing(soc: s.soc, charging: s.charging, accent: LAv2.green)
            } compactTrailing: {
                // Vazio: o anel ao redor do carro já mostra o SOC. Libera espaço
                // pra outras LAs (ex: BYD da Grasi) também aparecerem na DI.
                EmptyView()
            } minimal: {
                CarChargeRing(soc: s.soc, charging: s.charging, accent: LAv2.green)
            }
            .keylineTint(LAv2.green)
        }
    }

    private func diSubline(_ s: ChargeActivityAttributes.ContentState) -> String {
        var parts = ["\(laDec1(s.powerKw)) kW", "+\(laDec1(s.sessionKwh)) kWh"]
        if s.remainingMin > 0 {
            let ready = s.updatedAt.addingTimeInterval(Double(s.remainingMin) * 60)
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            parts.append("pronto ~ \(f.string(from: ready))")
        }
        return parts.joined(separator: " · ")
    }
}

struct ChargeLockScreenView: View {
    let state: ChargeActivityAttributes.ContentState
    let carName: String

    private var readyAt: Date? {
        guard state.charging, state.remainingMin > 0 else { return nil }
        return state.updatedAt.addingTimeInterval(Double(state.remainingMin) * 60)
    }

    var body: some View {
        Group {
            if state.charging { chargingBody } else { doneBody }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(alignment: .topTrailing) {
            RadialGradient(colors: [LAv2.green.opacity(0.14), .clear],
                           center: .topTrailing, startRadius: 0, endRadius: 220)
        }
    }

    // Variante em andamento — SOC hero + barra com ponto + régua de métricas.
    private var chargingBody: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Header: tile raio + carro | dot + frescor
            HStack(spacing: 7) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(.black)
                    .frame(width: 17, height: 17)
                    .background(LAv2.green, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                Text("\(carName) · carregando")
                    .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(LAv2.text2)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 6)
                Circle().fill(LAv2.green).frame(width: 5, height: 5)
                (Text("há ") + Text(state.updatedAt, style: .relative))
                    .font(.system(size: 10)).foregroundStyle(LAv2.muted)
                    .lineLimit(1)
            }
            // Hero: SOC → meta | restante · pronto ~ (uma linha só)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("\(Int(state.soc))")
                    .font(.system(size: 28, weight: .light)).tracking(-1)
                    .monospacedDigit().foregroundStyle(LAv2.green)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text("%").font(.system(size: 13)).foregroundStyle(LAv2.green)
                if state.targetPct > 0, state.targetPct < 100 {
                    Text("→ \(Int(state.targetPct))%")
                        .font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(LAv2.text2)
                }
                Spacer(minLength: 8)
                (Text("\(chargeRemainingShort(state.remainingMin)) restante")
                    .font(.system(size: 12.5, weight: .semibold)).foregroundColor(LAv2.text)
                    + Text(readyAt.map { r in
                        " · ~ " + r.formatted(.dateTime.hour().minute())
                    } ?? "")
                    .font(.system(size: 11)).foregroundColor(LAv2.text2))
                    .monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(height: 28)
            progressBar
            // Régua de micro-métricas
            HStack {
                Text("\(laDec1(state.powerKw)) kW")
                Spacer(minLength: 6)
                Text("+\(laDec1(state.sessionKwh)) kWh")
                if let c = state.costBrl, c > 0 {
                    Spacer(minLength: 6)
                    Text("R$ \(laDec2(c))")
                }
            }
            .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(LAv2.text2)
            .lineLimit(1).minimumScaleFactor(0.7)
            if #available(iOS 17.0, *) {
                chargeLAButtons(state)
            }
        }
    }

    // Barra h8: fill green até o SOC, ponto branco 10px com glow, tick amarelo no limite.
    private var progressBar: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let frac = CGFloat(min(100, max(0, state.soc)) / 100)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.55)).frame(height: 8)
                Capsule()
                    .fill(LinearGradient(colors: [LAv2.green.opacity(0.55), LAv2.green],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(8, w * frac), height: 8)
                if state.targetPct > 0, state.targetPct < 100 {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color(red: 0.980, green: 0.800, blue: 0.082))
                        .frame(width: 2, height: 13)
                        .offset(x: w * CGFloat(state.targetPct / 100) - 1)
                }
                Circle().fill(.white)
                    .frame(width: 10, height: 10)
                    .shadow(color: LAv2.green.opacity(0.6), radius: 3)
                    .offset(x: max(0, min(w - 10, w * frac - 5)))
            }
            .frame(height: 13, alignment: .leading)
        }
        .frame(height: 13)
    }

    // Variante verde de confirmação — bridge encerra com stale/dismissal.
    private var doneBody: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 34)).foregroundStyle(LAv2.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Recarga concluída · \(Int(state.soc))%")
                    .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(LAv2.text)
                Text(doneSub)
                    .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(LAv2.text2)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            Spacer(minLength: 6)
            Text(state.updatedAt, format: .dateTime.hour().minute())
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(LAv2.muted)
        }
    }

    private var doneSub: String {
        var s = "+\(laDec1(state.sessionKwh)) kWh"
        if let c = state.costBrl, c > 0 { s += " · R$ \(laDec2(c))" }
        return s
    }
}
