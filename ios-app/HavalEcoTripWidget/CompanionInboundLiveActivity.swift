//
//  CompanionInboundLiveActivity.swift
//  Visual da LA "companion indo até a Grasi" — cor magenta clara pra distinguir
//  rapidamente das LAs do carro (azul recarga/viagem).
//
import ActivityKit
import SwiftUI
import WidgetKit

private let inboundAccent = Color(red: 0.95, green: 0.55, blue: 0.85)   // rosa claro — vindo
private let inboundDim    = Color(red: 1.00, green: 0.70, blue: 0.90)
private let arrivedAccent = Color(red: 0.30, green: 0.85, blue: 0.55)   // verde — chegou (sai em 10min)

/// Cor por estado: rosa enquanto se aproxima, verde quando chegou.
private func inboundColor(_ active: Bool) -> Color { active ? inboundAccent : arrivedAccent }

private func inboundEta(_ min: Int) -> String {
    guard min > 0 else { return "chegou" }
    if min >= 60 { return "~\(min / 60)h\(String(format: "%02d", min % 60))" }
    return "~\(min) min"
}

struct CompanionInboundLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CompanionInboundActivityAttributes.self) { context in
            CompanionInboundLockScreenView(state: context.state, name: context.attributes.name)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(inboundColor(context.state.active))

        } dynamicIsland: { context in
            let s = context.state
            let c = inboundColor(s.active)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.name)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(c).lineLimit(1).minimumScaleFactor(0.5)
                        Text(s.active ? "a caminho" : "chegou").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(inboundEta(s.etaMin))
                            .font(.title3).bold().foregroundStyle(c)
                            .lineLimit(1).minimumScaleFactor(0.6)
                        Text(s.active ? String(format: "%.1f km", s.distKm) : "agora")
                            .font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 4) {
                        Image(systemName: s.active ? "figure.walk.arrival" : "checkmark.circle.fill")
                            .font(.caption2).foregroundStyle(c)
                        Text(s.active ? "Vindo até você" : "Chegou ✓")
                            .font(.caption2).foregroundStyle(c)
                            .lineLimit(1).minimumScaleFactor(0.6)
                        Spacer(minLength: 4)
                    }
                }
            } compactLeading: {
                Image(systemName: s.active ? "figure.walk.arrival" : "checkmark.circle.fill")
                    .foregroundStyle(c)
            } compactTrailing: {
                Text(inboundEta(s.etaMin)).bold().foregroundStyle(c)
                    .lineLimit(1).minimumScaleFactor(0.5)
            } minimal: {
                Image(systemName: s.active ? "figure.walk.arrival" : "checkmark.circle.fill")
                    .foregroundStyle(c)
            }
            .keylineTint(c)
        }
    }
}

struct CompanionInboundLockScreenView: View {
    let state: CompanionInboundActivityAttributes.ContentState
    let name: String

    var body: some View {
        let c = inboundColor(state.active)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: state.active ? "figure.walk.arrival" : "checkmark.circle.fill")
                    .foregroundStyle(c)
                Text(state.active ? "\(state.name) está vindo até você" : "\(state.name) chegou ✓")
                    .font(.headline).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 4)
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.active ? inboundEta(state.etaMin) : "agora")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(c).lineLimit(1).minimumScaleFactor(0.6)
                    Text(state.active ? "TEMPO" : "STATUS")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary).tracking(0.4)
                }
                Spacer()
                if state.active {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(format: "%.1f", state.distKm))
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .foregroundStyle(c).lineLimit(1).minimumScaleFactor(0.6)
                        Text("KM").font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary).tracking(0.4)
                    }
                } else {
                    VStack(alignment: .trailing, spacing: 2) {
                        Image(systemName: "house.fill")
                            .font(.system(size: 26)).foregroundStyle(c)
                        Text("EM CASA").font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary).tracking(0.4)
                    }
                }
            }
        }
        .padding(14)
    }
}
