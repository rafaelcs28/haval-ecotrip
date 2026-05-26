//
//  PreClimatLiveActivity.swift
//  Layouts da Live Activity da pré-climatização (lock screen + Dynamic Island).
//  Iniciada/atualizada LOCALMENTE pelo app (PreClimatManager) — conta gratuita
//  não tem APNs, então não há push-to-start; a LA só existe com o app vivo.
//
import ActivityKit
import SwiftUI
import WidgetKit

// Metadados visuais por fase.
private func phaseMeta(_ phase: String) -> (icon: String, color: Color, title: String) {
    switch phase {
    case "scheduled": return ("clock.fill",                 .cyan,   "Pré-climatização agendada")
    case "starting":  return ("power",                      .orange, "Ligando o motor…")
    case "engine_on": return ("checkmark.circle.fill",      .green,  "Motor ligado")
    case "cooling":   return ("snowflake",                  .cyan,   "Climatizando")
    case "restoring": return ("arrow.uturn.backward.circle",.orange, "Restaurando AC")
    case "ended":     return ("checkmark.seal.fill",        .green,  "Pré-climatização encerrada")
    case "failed":    return ("exclamationmark.triangle.fill", .red, "Pré-climatização falhou")
    default:          return ("thermometer.snowflake",      .cyan,   "Pré-climatização")
    }
}

// Legenda da contagem regressiva conforme a fase.
private func countdownCaption(_ phase: String) -> String {
    switch phase {
    case "scheduled": return "começa em"
    case "cooling":   return "termina em"
    default:          return ""
    }
}

struct PreClimatLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PreClimatActivityAttributes.self) { context in
            PreClimatLockScreenView(state: context.state,
                                    scheduledTime: context.attributes.scheduledTime,
                                    carName: context.attributes.carName)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.cyan)

        } dynamicIsland: { context in
            let meta = phaseMeta(context.state.phase)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label {
                            Text(meta.title).font(.caption).bold()
                        } icon: {
                            Image(systemName: meta.icon).foregroundStyle(meta.color)
                        }
                        if context.state.temp > 0 {
                            Text(String(format: "%.0f° · fan %d/7", context.state.temp, context.state.fan))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let endsAt = context.state.endsAt, !context.state.isFinal {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(endsAt, style: .timer)
                                .font(.title3).bold().monospacedDigit()
                                .foregroundStyle(meta.color)
                                .multilineTextAlignment(.trailing)
                            Text(countdownCaption(context.state.phase))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.detail).font(.caption).foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: meta.icon).foregroundStyle(meta.color)
            } compactTrailing: {
                if let endsAt = context.state.endsAt, !context.state.isFinal {
                    Text(endsAt, style: .timer).monospacedDigit()
                        .frame(maxWidth: 52).foregroundStyle(meta.color)
                } else {
                    Image(systemName: "thermometer.snowflake").foregroundStyle(meta.color)
                }
            } minimal: {
                Image(systemName: meta.icon).foregroundStyle(meta.color)
            }
            .keylineTint(.cyan)
        }
    }
}

// ───────────────────────────────────────────────────────────────
//  LOCK SCREEN
// ───────────────────────────────────────────────────────────────
struct PreClimatLockScreenView: View {
    let state: PreClimatActivityAttributes.ContentState
    let scheduledTime: String
    let carName: String

    var body: some View {
        let meta = phaseMeta(state.phase)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: meta.icon).foregroundStyle(meta.color)
                Text(meta.title).font(.headline)
                Spacer()
                Text(scheduledTime.isEmpty ? carName : scheduledTime)
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(state.detail).font(.subheadline)
                Spacer()
                if let endsAt = state.endsAt, !state.isFinal {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(endsAt, style: .timer)
                            .font(.title2).bold().monospacedDigit()
                            .foregroundStyle(meta.color)
                            .multilineTextAlignment(.trailing)
                        let cap = countdownCaption(state.phase)
                        if !cap.isEmpty {
                            Text(cap).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if state.temp > 0 {
                HStack {
                    Label(String(format: "%.0f °C", state.temp), systemImage: "thermometer")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Label("ventilação \(state.fan)/7", systemImage: "wind")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
    }
}
