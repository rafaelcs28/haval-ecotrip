//
//  ChargeActivityLiveActivity.swift
//  Define todos os layouts da Live Activity de recarga:
//   - lockScreen / banner   → quando iPhone está bloqueado
//   - Dynamic Island compact (leading + trailing)
//   - Dynamic Island expanded (long press)
//   - Dynamic Island minimal (várias activities)
//
import ActivityKit
import SwiftUI
import WidgetKit

struct ChargeActivityLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ChargeActivityAttributes.self) { context in
            // ──── LOCK SCREEN / NOTIFICATION BANNER ────────────────────────
            LockScreenView(state: context.state, carName: context.attributes.carName)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.green)

        } dynamicIsland: { context in
            DynamicIsland {
                // ──── DYNAMIC ISLAND EXPANDED (long press) ────────────────
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label {
                            Text("\(Int(context.state.soc))%")
                                .font(.title3).bold()
                        } icon: {
                            Image(systemName: "battery.100.bolt").foregroundStyle(.green)
                        }
                        Text("SOC").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(format: "%.1f kW", context.state.powerKw))
                            .font(.title3).bold().foregroundStyle(.green)
                        Text(remainingLabel(min: context.state.remainingMin))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Image(systemName: context.state.charging ? "bolt.fill" : "checkmark.circle.fill")
                            .foregroundStyle(context.state.charging ? .green : .blue)
                        Text(context.state.charging ? "Carregando" : "Concluído")
                            .font(.caption).bold()
                        Spacer()
                        Text(String(format: "%.1f kWh", context.state.sessionKwh))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                // ──── DYNAMIC ISLAND COMPACT (sempre visível) ─────────────
                Image(systemName: "bolt.fill").foregroundStyle(.green)
            } compactTrailing: {
                Text("\(Int(context.state.soc))%")
                    .foregroundStyle(.green).bold()
            } minimal: {
                Image(systemName: "bolt.fill").foregroundStyle(.green)
            }
            .keylineTint(.green)
        }
    }

    private func remainingLabel(min: Int) -> String {
        guard min > 0 else { return "—" }
        if min >= 60 {
            let h = min / 60, m = min % 60
            return "~\(h)h\(String(format: "%02d", m))"
        }
        return "~\(min) min"
    }
}

// ───────────────────────────────────────────────────────────────
//  LOCK SCREEN VIEW — layout grande, mostra todos os campos
// ───────────────────────────────────────────────────────────────
struct LockScreenView: View {
    let state: ChargeActivityAttributes.ContentState
    let carName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: state.charging ? "bolt.fill" : "checkmark.circle.fill")
                    .foregroundStyle(state.charging ? .green : .blue)
                Text(state.charging ? "Carregando" : "Recarga concluída")
                    .font(.headline)
                Spacer()
                Text(carName).font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline) {
                Text("\(Int(state.soc))")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(.green)
                Text("%").font(.title2).foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(String(format: "%.1f kW", state.powerKw))
                        .font(.title3).bold()
                    Text(remainingLabel())
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                MiniStat(label: "Energia", value: String(format: "%.1f", state.sessionKwh), unit: "kWh")
                Spacer()
                MiniStat(label: "Atualizado", value: relativeTime(), unit: "")
            }
        }
        .padding(14)
    }

    private func remainingLabel() -> String {
        guard state.remainingMin > 0 else { return "—" }
        if state.remainingMin >= 60 {
            let h = state.remainingMin / 60, m = state.remainingMin % 60
            return "~\(h)h\(String(format: "%02d", m))"
        }
        return "~\(state.remainingMin) min"
    }

    private func relativeTime() -> String {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return fmt.localizedString(for: state.updatedAt, relativeTo: Date())
    }
}

struct MiniStat: View {
    let label: String, value: String, unit: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.callout).bold()
                if !unit.isEmpty { Text(unit).font(.caption2).foregroundStyle(.secondary) }
            }
        }
    }
}
