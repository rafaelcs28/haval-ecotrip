//
//  MotorLiveActivity.swift
//  Live Activity de motor ligado remotamente (lock screen + Dynamic Island).
//  Lembrete de segurança: conta "há X min" ao vivo no device e mostra a
//  temperatura interna; encerra quando o bridge sinaliza motor desligado.
//
import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct MotorLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MotorActivityAttributes.self) { context in
            MotorLockScreenView(state: context.state, carName: context.attributes.carName)
                .activityBackgroundTint(Color.orange.opacity(0.18))
                .activitySystemActionForegroundColor(.orange)

        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Motor ligado", systemImage: "key.fill")
                            .font(.caption).foregroundStyle(.orange)
                        if s.active {
                            Text(s.startedAt, style: .timer)
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                                .foregroundStyle(.orange)
                                .frame(maxWidth: 90)
                        } else {
                            Text("desligado").font(.title3).bold().foregroundStyle(.secondary)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(format: "%.0f°", s.cabinTemp))
                            .font(.title2).bold().foregroundStyle(.teal)
                        Text("interna").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        HStack {
                            if s.acOn {
                                Label("A/C ligado", systemImage: "fan.fill").font(.caption2).foregroundStyle(.teal)
                            }
                            Spacer()
                            Label(String(format: "externa %.0f°", s.outsideTemp), systemImage: "thermometer.medium")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        if s.active, #available(iOS 17.0, *) {
                            LAActionButton(title: "Desligar motor", systemImage: "power", tint: .orange, intent: EngineOffIntent())
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: "key.fill").foregroundStyle(.orange)
            } compactTrailing: {
                if context.state.active {
                    Text(context.state.startedAt, style: .timer)
                        .frame(maxWidth: 44).foregroundStyle(.orange).bold()
                } else {
                    Image(systemName: "key.slash").foregroundStyle(.secondary)
                }
            } minimal: {
                Image(systemName: "key.fill").foregroundStyle(.orange)
            }
            .keylineTint(.orange)
        }
    }
}

struct MotorLockScreenView: View {
    let state: MotorActivityAttributes.ContentState
    let carName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: state.active ? "key.fill" : "key.slash")
                    .foregroundStyle(state.active ? .orange : .secondary)
                Text(state.active ? "Motor ligado" : "Motor desligado").font(.headline)
                Spacer()
                Text(carName).font(.caption2).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if state.active {
                    Text("há").font(.title3).foregroundStyle(.secondary)
                    Text(state.startedAt, style: .timer)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(.orange)
                        .frame(maxWidth: 140, alignment: .leading)
                } else {
                    Text("Veículo desligado").font(.title3).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(String(format: "%.0f°", state.cabinTemp))
                        .font(.title2).bold().foregroundStyle(.teal)
                    Text("interna").font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack {
                if state.acOn {
                    Label("A/C ligado", systemImage: "fan.fill").font(.caption).foregroundStyle(.teal)
                }
                if state.active {
                    Spacer()
                    Label("Não esqueça ligado", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(.orange)
                }
                Spacer()
                Label(String(format: "externa %.0f°", state.outsideTemp), systemImage: "thermometer.medium")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if state.active, #available(iOS 17.0, *) {
                LAActionButton(title: "Desligar motor", systemImage: "power", tint: .orange, intent: EngineOffIntent())
                    .padding(.top, 2)
            }
        }
        .padding(14)
    }
}
