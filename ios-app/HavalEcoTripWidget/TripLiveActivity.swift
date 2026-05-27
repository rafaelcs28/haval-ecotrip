//
//  TripLiveActivity.swift
//  Live Activity de viagem ao vivo (lock screen + Dynamic Island).
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
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.teal)

        } dynamicIsland: { context in
            let s = context.state
            let accent: Color = s.isEV ? .green : .orange
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: "%.1f km", s.distKm))
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(.teal)
                        Text(s.isEV ? "elétrico" : "híbrido").font(.caption2).foregroundStyle(accent)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        if s.effKwh100 > 0 {
                            Text(String(format: "%.1f", s.effKwh100)).font(.title3).bold().foregroundStyle(.teal)
                            Text("kWh/100km").font(.caption2).foregroundStyle(.secondary)
                        } else {
                            Text(tripDuration(s.timeSec)).font(.title3).bold()
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Label(tripDuration(s.timeSec), systemImage: "clock").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Label(String(format: "%.1f kWh", s.netKwh), systemImage: "bolt").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Label(String(format: "%.0f km/h", s.avgSpeedKmh), systemImage: "speedometer").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: "car.fill").foregroundStyle(.teal)
            } compactTrailing: {
                Text(String(format: "%.1f", s.distKm)).bold().foregroundStyle(.teal)
            } minimal: {
                Image(systemName: "car.fill").foregroundStyle(.teal)
            }
            .keylineTint(.teal)
        }
    }
}

struct TripLockScreenView: View {
    let state: TripActivityAttributes.ContentState
    let carName: String

    var body: some View {
        let accent: Color = state.isEV ? .green : .orange
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: state.active ? "car.fill" : "checkmark.circle.fill")
                    .foregroundStyle(state.active ? .teal : .blue)
                Text(state.active ? "Viagem" : "Viagem encerrada").font(.headline)
                Text(state.isEV ? "· elétrico" : "· híbrido").font(.caption).foregroundStyle(accent)
                Spacer()
                Text(carName).font(.caption2).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(String(format: "%.1f", state.distKm))
                    .font(.system(size: 40, weight: .bold, design: .rounded)).foregroundStyle(.teal)
                Text("km").font(.title3).foregroundStyle(.secondary)
                Spacer()
                if state.effKwh100 > 0 {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(String(format: "%.1f", state.effKwh100))
                            .font(.title2).bold().foregroundStyle(.teal)
                        Text("kWh/100km").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Label(tripDuration(state.timeSec), systemImage: "clock").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Label(String(format: "%.1f kWh", state.netKwh), systemImage: "bolt").font(.caption).foregroundStyle(.secondary)
                if state.fuelL > 0.05 {
                    Spacer()
                    Label(String(format: "%.1f L", state.fuelL), systemImage: "fuelpump").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Label(String(format: "%.0f km/h", state.avgSpeedKmh), systemImage: "speedometer").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }
}
