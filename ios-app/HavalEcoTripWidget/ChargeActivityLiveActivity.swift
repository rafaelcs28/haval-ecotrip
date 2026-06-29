//
//  ChargeActivityLiveActivity.swift
//  Live Activity de recarga — estilo "número grande + barra de progresso".
//   - lockScreen: SOC grande, barra até 100%, potência/tempo/kWh embaixo.
//   - Dynamic Island compact/expanded/minimal.
//
import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

private func chargeRemainingLabel(_ min: Int, target: Double = 0) -> String {
    guard min > 0 else { return "—" }
    let t = (target > 0 && target < 100) ? " até \(Int(target))%" : ""
    if min >= 60 { return "~\(min / 60)h\(String(format: "%02d", min % 60))\(t)" }
    return "~\(min) min\(t)"
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
        LAActionButton(title: "Pré-clima", systemImage: "thermometer.snowflake", intent: PreclimaIntent())
        if s.locked == true {
            LAActionButton(title: "Destrancar", systemImage: "lock.open.fill", tint: .orange, intent: UnlockCarIntent())
        } else {
            LAActionButton(title: "Trancar", systemImage: "lock.fill", intent: LockCarIntent())
        }
        LAActionButton(title: "\(Int(s.targetPct))%", systemImage: "bolt.fill", tint: .green, intent: CycleChargeLimitIntent())
    }
}

struct ChargeActivityLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ChargeActivityAttributes.self) { context in
            ChargeLockScreenView(state: context.state, carName: context.attributes.carName)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.green)

        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Int(s.soc))%")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(s.charging ? .green : .blue)
                        Text("bateria").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(format: "%.1f kW", s.powerKw))
                            .font(.title3).bold().foregroundStyle(.green)
                            .lineLimit(1).minimumScaleFactor(0.5)
                        Text(chargeRemainingLabel(s.remainingMin, target: s.targetPct))
                            .font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        ChargeBar(soc: s.soc, target: s.targetPct, accent: s.charging ? .green : .blue)
                        // HStack manual em vez de Label: na DI expanded o ícone do Label
                        // era cortado pela safe-area lateral. Image fixa + Text com
                        // minScale garante que tanto carrinho quanto "Carregando" cabem.
                        HStack(spacing: 4) {
                            Image(systemName: s.charging ? "bolt.car.fill" : "checkmark.circle.fill")
                                .font(.caption2).foregroundStyle(s.charging ? .green : .blue)
                            Text(s.charging ? "Carregando" : "Concluído")
                                .font(.caption2).foregroundStyle(s.charging ? .green : .blue)
                                .lineLimit(1).minimumScaleFactor(0.6)
                            Spacer(minLength: 4)
                            Text(String(format: "%.1f kWh", s.sessionKwh))
                                .font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(1).minimumScaleFactor(0.5).layoutPriority(1)
                        }
                        if #available(iOS 17.0, *) {
                            chargeLAButtons(s)
                        }
                    }
                }
            } compactLeading: {
                CarChargeRing(soc: s.soc, charging: s.charging, accent: s.charging ? .green : .blue)
            } compactTrailing: {
                // Vazio: o anel ao redor do carro já mostra o SOC. Libera espaço
                // pra outras LAs (ex: BYD da Grasi) também aparecerem na DI.
                EmptyView()
            } minimal: {
                CarChargeRing(soc: s.soc, charging: s.charging, accent: s.charging ? .green : .blue)
            }
            .keylineTint(.green)
        }
    }
}

struct ChargeLockScreenView: View {
    let state: ChargeActivityAttributes.ContentState
    let carName: String

    var body: some View {
        let accent: Color = state.charging ? .green : .blue
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: state.charging ? "bolt.car.fill" : "checkmark.circle.fill")
                    .foregroundStyle(accent)
                Text(state.charging ? "Carregando" : "Recarga concluída")
                    .font(.headline).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 6)
                Text(carName).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(Int(state.soc))")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundStyle(accent)
                Text("%").font(.title3).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f kW", state.powerKw))
                    .font(.title3).bold().foregroundStyle(accent)
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            ChargeBar(soc: state.soc, target: state.targetPct, accent: accent)
            HStack(spacing: 6) {
                Label(chargeRemainingLabel(state.remainingMin, target: state.targetPct), systemImage: "clock")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 6)
                Label(String(format: "%.1f kWh", state.sessionKwh), systemImage: "bolt.batteryblock")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.6).layoutPriority(1)
            }
            if #available(iOS 17.0, *) {
                chargeLAButtons(state)
                    .padding(.top, 2)
            }
        }
        .padding(14)
    }
}

// Barra de carga: preenche até o SOC e marca a META (limite) com um tick sutil.
struct ChargeBar: View {
    let soc: Double
    let target: Double
    let accent: Color
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.15)).frame(height: 6)
                Capsule().fill(accent)
                    .frame(width: w * CGFloat(min(100, max(0, soc)) / 100), height: 6)
                if target > 0 && target < 100 {
                    RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.75))
                        .frame(width: 2, height: 11)
                        .offset(x: w * CGFloat(min(100, max(0, target)) / 100) - 1)
                }
            }
            .frame(height: 11, alignment: .leading)
        }
        .frame(height: 11)
    }
}
