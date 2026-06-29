//
//  PreClimatLiveActivity.swift
//  Live Activity da pré-climatização — mesma linguagem da recarga: título fixo
//  + pílula de status, contagem grande, barra com trilho e chips de temperatura.
//  Criada e atualizada pelo bridge via APNs (push-to-start + updates).
//
import ActivityKit
import SwiftUI
import WidgetKit

private func phaseMeta(_ phase: String) -> (icon: String, color: Color, status: String) {
    switch phase {
    case "scheduled": return ("clock.fill",                   .cyan,   "Agendada")
    case "starting":  return ("power",                        .orange, "Ligando")
    case "engine_on": return ("checkmark.circle.fill",        .green,  "Motor ligado")
    case "cooling":   return ("snowflake",                    .cyan,   "Climatizando")
    case "restoring": return ("arrow.uturn.backward.circle",  .orange, "Restaurando")
    case "ended":     return ("checkmark.seal.fill",          .green,  "Concluída")
    case "failed":    return ("exclamationmark.triangle.fill",.red,    "Falhou")
    default:          return ("thermometer.snowflake",        .cyan,   "Pré-clima")
    }
}

private func countdownCaption(_ phase: String) -> String {
    switch phase {
    case "scheduled": return "começa em"
    case "cooling":   return "termina em"
    default:          return ""
    }
}

// Pílula de status colorida (reaproveitada no lock screen e na ilha).
private struct StatusPill: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
    }
}

// Chip de temperatura: bolinha colorida + rótulo + valor.
private struct TempChip: View {
    let label: String
    let value: Double
    let color: Color
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text("\(Int(value))°").font(.subheadline).bold().foregroundStyle(.primary)
        }
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
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Pré-clima", systemImage: meta.icon)
                            .font(.caption).bold().foregroundStyle(meta.color)
                            .labelStyle(.titleAndIcon)
                        StatusPill(text: meta.status, color: meta.color)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let endsAt = s.endsAt, !s.isFinal, !countdownCaption(s.phase).isEmpty {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(endsAt, style: .timer)
                                .font(.system(size: 24, weight: .bold, design: .rounded))
                                .monospacedDigit().foregroundStyle(meta.color)
                                .multilineTextAlignment(.trailing).frame(maxWidth: 78)
                            Text(countdownCaption(s.phase)).font(.caption2).foregroundStyle(.secondary)
                        }
                    } else if s.tempIn != 0 {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("\(Int(s.tempIn))°")
                                .font(.system(size: 24, weight: .bold, design: .rounded))
                                .foregroundStyle(meta.color)
                            Text("interna").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        if let endsAt = s.endsAt, !s.isFinal, !countdownCaption(s.phase).isEmpty {
                            ProgressView(timerInterval: s.updatedAt...endsAt, countsDown: false)
                                .tint(meta.color).labelsHidden()
                        }
                        HStack(spacing: 14) {
                            if s.tempIn  != 0 { TempChip(label: "Int", value: s.tempIn,  color: .cyan) }
                            if s.tempOut != 0 { TempChip(label: "Ext", value: s.tempOut, color: .orange) }
                            Spacer()
                            if s.temp > 0 {
                                Text(String(format: "AC %.0f° · %d/7", s.temp, s.fan))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            if s.isCancellable, let cancelURL = URL(string: "havalecotrip://preclimat-cancel") {
                                Link(destination: cancelURL) {
                                    Label("Cancelar", systemImage: "xmark.circle.fill")
                                        .font(.caption2.weight(.semibold)).foregroundStyle(.red)
                                        .padding(.horizontal, 10).padding(.vertical, 5)
                                        .background(Color.red.opacity(0.15), in: Capsule())
                                }
                            }
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: meta.icon).foregroundStyle(meta.color)
            } compactTrailing: {
                if let endsAt = s.endsAt, !s.isFinal, !countdownCaption(s.phase).isEmpty {
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

    private var hasCountdown: Bool {
        state.endsAt != nil && !state.isFinal && !countdownCaption(state.phase).isEmpty
    }

    var body: some View {
        let meta = phaseMeta(state.phase)
        VStack(alignment: .leading, spacing: 10) {
            // Cabeçalho: ícone + título fixo + pílula de status + horário
            HStack(spacing: 8) {
                Image(systemName: meta.icon).foregroundStyle(meta.color)
                Text("Pré-climatização").font(.headline)
                StatusPill(text: meta.status, color: meta.color)
                Spacer()
                if !scheduledTime.isEmpty {
                    Label(scheduledTime, systemImage: "alarm")
                        .font(.caption2).foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }
            }

            // Herói: contagem grande + barra, OU detalhe textual nas fases sem timer
            if let endsAt = state.endsAt, hasCountdown {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(endsAt, style: .timer)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit().foregroundStyle(meta.color)
                        .frame(maxWidth: 150, alignment: .leading)
                    Text(countdownCaption(state.phase))
                        .font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                }
                ProgressView(timerInterval: state.updatedAt...endsAt, countsDown: false)
                    .tint(meta.color).labelsHidden()
            } else {
                Text(state.detail.isEmpty ? meta.status : state.detail)
                    .font(.title3).bold().foregroundStyle(meta.color)
            }

            // Rodapé: chips de temperatura + AC/ventilação
            HStack(spacing: 14) {
                if state.tempIn  != 0 { TempChip(label: "Interna", value: state.tempIn,  color: .cyan) }
                if state.tempOut != 0 { TempChip(label: "Externa", value: state.tempOut, color: .orange) }
                Spacer()
                if state.temp > 0 {
                    Label(String(format: "%.0f° · fan %d/7", state.temp, state.fan),
                          systemImage: "fan.fill")
                        .font(.caption2).foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }
            }

            // Botão Cancelar: abre o app (havalecotrip://preclimat-cancel), que pede
            // confirmação antes de restaurar o AC e desligar o motor.
            if state.isCancellable, let cancelURL = URL(string: "havalecotrip://preclimat-cancel") {
                Link(destination: cancelURL) {
                    Label("Cancelar", systemImage: "xmark.circle.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(.red)
                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                        .background(Color.red.opacity(0.15), in: Capsule())
                }
            }
        }
        .padding(14)
    }
}
