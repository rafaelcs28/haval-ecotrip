//
//  InfraLiveActivity.swift
//  Live Activity de infra/monitoramento (lock screen + Dynamic Island).
//  Mostra na tela bloqueada enquanto o HA da empresa reportar algo fora do ar;
//  encerra sozinha quando o bridge sinaliza que voltou tudo.
//
import ActivityKit
import SwiftUI
import WidgetKit

struct InfraLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: InfraActivityAttributes.self) { context in
            InfraLockScreenView(state: context.state)
                .activityBackgroundTint(context.state.active ? Color.red.opacity(0.18) : Color.green.opacity(0.14))
                .activitySystemActionForegroundColor(context.state.active ? .red : .green)

        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(s.active ? "Infra com problema" : "Infra OK",
                          systemImage: s.active ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(s.active ? .red : .green)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if s.active {
                        Text("\(s.downCount)/\(s.totalCount)")
                            .font(.title2).bold().foregroundStyle(.red)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if s.active {
                        Text(s.issuesText).font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text("Tudo normal").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: s.active ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(s.active ? .red : .green)
            } compactTrailing: {
                if s.active {
                    Text("\(s.downCount)").foregroundStyle(.red).bold()
                }
            } minimal: {
                Image(systemName: s.active ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(s.active ? .red : .green)
            }
            .keylineTint(s.active ? .red : .green)
        }
    }
}

struct InfraLockScreenView: View {
    let state: InfraActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: state.active ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(state.active ? .red : .green)
                Text(state.active ? "Infra com problema" : "Infra normalizada").font(.headline)
                Spacer()
                if state.active {
                    Text("\(state.downCount)/\(state.totalCount)")
                        .font(.title3).bold().foregroundStyle(.red)
                }
            }
            Text(state.active ? state.issuesText : "Tudo normal agora.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(14)
    }
}
