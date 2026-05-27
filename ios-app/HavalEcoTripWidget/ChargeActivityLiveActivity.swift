//
//  ChargeActivityLiveActivity.swift
//  Live Activity de recarga — estilo "número grande + barra de progresso".
//   - lockScreen: SOC grande, barra até 100%, potência/tempo/kWh embaixo.
//   - Dynamic Island compact/expanded/minimal.
//
import ActivityKit
import SwiftUI
import WidgetKit

private func chargeRemainingLabel(_ min: Int) -> String {
    guard min > 0 else { return "—" }
    if min >= 60 { return "~\(min / 60)h\(String(format: "%02d", min % 60))" }
    return "~\(min) min"
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
                        Text(chargeRemainingLabel(s.remainingMin))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        ProgressView(value: min(100, max(0, s.soc)), total: 100)
                            .tint(s.charging ? .green : .blue)
                        HStack {
                            Label(s.charging ? "Carregando" : "Concluído",
                                  systemImage: s.charging ? "bolt.fill" : "checkmark.circle.fill")
                                .font(.caption2).foregroundStyle(s.charging ? .green : .blue)
                            Spacer()
                            Text(String(format: "%.1f kWh", s.sessionKwh))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: s.charging ? "bolt.fill" : "checkmark.circle.fill")
                    .foregroundStyle(s.charging ? .green : .blue)
            } compactTrailing: {
                Text("\(Int(s.soc))%").bold().foregroundStyle(s.charging ? .green : .blue)
            } minimal: {
                Image(systemName: "bolt.fill").foregroundStyle(.green)
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
            HStack {
                Image(systemName: state.charging ? "bolt.fill" : "checkmark.circle.fill")
                    .foregroundStyle(accent)
                Text(state.charging ? "Carregando" : "Recarga concluída").font(.headline)
                Spacer()
                Text(carName).font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(Int(state.soc))")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundStyle(accent)
                Text("%").font(.title3).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f kW", state.powerKw))
                    .font(.title3).bold().foregroundStyle(accent)
            }
            ProgressView(value: min(100, max(0, state.soc)), total: 100)
                .tint(accent)
            HStack {
                Label(chargeRemainingLabel(state.remainingMin), systemImage: "clock")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Label(String(format: "%.1f kWh", state.sessionKwh), systemImage: "bolt.batteryblock")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }
}
