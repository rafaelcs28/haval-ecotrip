//
//  PreClimatLiveActivity.swift
//  Live Activity da pré-climatização — mesma linguagem da recarga:
//  número grande (contagem) + barra de progresso (por tempo) + stats.
//  Criada e atualizada pelo bridge via APNs (push-to-start + updates).
//
import ActivityKit
import SwiftUI
import WidgetKit

private func phaseMeta(_ phase: String) -> (icon: String, color: Color, title: String) {
    switch phase {
    case "scheduled": return ("clock.fill",                  .cyan,   "Pré-climatização agendada")
    case "starting":  return ("power",                       .orange, "Ligando o motor…")
    case "engine_on": return ("checkmark.circle.fill",       .green,  "Motor ligado")
    case "cooling":   return ("snowflake",                   .cyan,   "Climatizando")
    case "restoring": return ("arrow.uturn.backward.circle", .orange, "Restaurando AC")
    case "ended":     return ("checkmark.seal.fill",         .green,  "Pré-climatização encerrada")
    case "failed":    return ("exclamationmark.triangle.fill",.red,   "Pré-climatização falhou")
    default:          return ("thermometer.snowflake",       .cyan,   "Pré-climatização")
    }
}

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
            let s = context.state
            let meta = phaseMeta(s.phase)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(meta.title, systemImage: meta.icon)
                            .font(.caption).bold().foregroundStyle(meta.color)
                            .labelStyle(.titleAndIcon)
                        if s.temp > 0 {
                            Text(String(format: "%.0f° · fan %d/7", s.temp, s.fan))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let endsAt = s.endsAt, !s.isFinal {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(endsAt, style: .timer)
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                                .monospacedDigit().foregroundStyle(meta.color)
                                .multilineTextAlignment(.trailing).frame(maxWidth: 70)
                            Text(countdownCaption(s.phase)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let endsAt = s.endsAt, !s.isFinal {
                        ProgressView(timerInterval: s.updatedAt...endsAt, countsDown: false)
                            .tint(meta.color).labelsHidden()
                    } else {
                        Text(s.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: meta.icon).foregroundStyle(meta.color)
            } compactTrailing: {
                if let endsAt = s.endsAt, !s.isFinal {
                    Text(endsAt, style: .timer).monospacedDigit()
                        .frame(maxWidth: 50).foregroundStyle(meta.color)
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
                Text(scheduledTime).font(.caption).foregroundStyle(.secondary)
            }
            if let endsAt = state.endsAt, !state.isFinal {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(endsAt, style: .timer)
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .monospacedDigit().foregroundStyle(meta.color)
                    Text(countdownCaption(state.phase))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                ProgressView(timerInterval: state.updatedAt...endsAt, countsDown: false)
                    .tint(meta.color).labelsHidden()
            } else {
                Text(state.detail).font(.title3).bold()
            }
            HStack {
                if state.temp > 0 {
                    Label(String(format: "%.0f °C", state.temp), systemImage: "thermometer")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if state.fan > 0 {
                    Label("ventilação \(state.fan)/7", systemImage: "wind")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
    }
}
