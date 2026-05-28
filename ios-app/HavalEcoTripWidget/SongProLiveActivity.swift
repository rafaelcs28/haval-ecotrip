//
//  SongProLiveActivity.swift
//  Live Activity da BYD Song Pro (esposa) — visual idêntico ao Charge,
//  porém com cor AZUL CLARINHO em vez de verde, pra distinção rápida.
//
import ActivityKit
import SwiftUI
import WidgetKit

// Azul clarinho — distinto do verde da LA do Haval.
private let songProAccent = Color(red: 0.45, green: 0.75, blue: 1.0)
private let songProAccentDim = Color(red: 0.55, green: 0.80, blue: 1.0)

private func songProRemainingLabel(_ min: Int) -> String {
    guard min > 0 else { return "—" }
    if min >= 60 { return "~\(min / 60)h\(String(format: "%02d", min % 60))" }
    return "~\(min) min"
}

struct SongProLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SongProActivityAttributes.self) { context in
            SongProLockScreenView(state: context.state, carName: context.attributes.carName)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(songProAccent)

        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Int(s.soc))%")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(s.charging ? songProAccent : .blue)
                        Text("Song Pro").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(format: "%.1f kW", s.powerKw))
                            .font(.title3).bold().foregroundStyle(songProAccent)
                        Text(songProRemainingLabel(s.remainingMin))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        SongProBar(soc: s.soc, accent: s.charging ? songProAccent : .blue)
                        HStack {
                            Label(s.charging ? "Carregando" : "Concluído",
                                  systemImage: s.charging ? "bolt.car.fill" : "checkmark.circle.fill")
                                .font(.caption2).foregroundStyle(s.charging ? songProAccent : .blue)
                            Spacer()
                            Text("👩 esposa")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: s.charging ? "bolt.car.fill" : "checkmark.circle.fill")
                    .foregroundStyle(s.charging ? songProAccent : .blue)
            } compactTrailing: {
                Text("\(Int(s.soc))%").bold().foregroundStyle(s.charging ? songProAccent : .blue)
            } minimal: {
                Image(systemName: "bolt.car.fill").foregroundStyle(songProAccent)
            }
            .keylineTint(songProAccent)
        }
    }
}

struct SongProLockScreenView: View {
    let state: SongProActivityAttributes.ContentState
    let carName: String

    var body: some View {
        let accent: Color = state.charging ? songProAccent : .blue
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: state.charging ? "bolt.car.fill" : "checkmark.circle.fill")
                    .foregroundStyle(accent)
                Text(state.charging ? "Carregando (esposa)" : "Recarga concluída (esposa)").font(.headline)
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
            SongProBar(soc: state.soc, accent: accent)
            HStack {
                Label(songProRemainingLabel(state.remainingMin), systemImage: "clock")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Label(String(format: "%.2f kWh", state.sessionKwh), systemImage: "bolt.batteryblock")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }
}

struct SongProBar: View {
    let soc: Double
    let accent: Color
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.15)).frame(height: 6)
                Capsule().fill(accent)
                    .frame(width: w * CGFloat(min(100, max(0, soc)) / 100), height: 6)
            }
            .frame(height: 11, alignment: .leading)
        }
        .frame(height: 11)
    }
}
