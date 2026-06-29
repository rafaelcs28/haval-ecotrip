//
//  CompanionInboundLiveActivity.swift
//  Visual da LA "companion indo até a Grasi" — cor magenta clara pra distinguir
//  rapidamente das LAs do carro (azul recarga/viagem).
//
import ActivityKit
import SwiftUI
import WidgetKit

private let inboundAccent = Color(red: 0.95, green: 0.55, blue: 0.85)   // rosa claro
private let inboundDim    = Color(red: 1.00, green: 0.70, blue: 0.90)

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
                .activitySystemActionForegroundColor(inboundAccent)

        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.name)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(inboundAccent).lineLimit(1).minimumScaleFactor(0.5)
                        Text("a caminho").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(inboundEta(s.etaMin))
                            .font(.title3).bold().foregroundStyle(inboundAccent)
                            .lineLimit(1).minimumScaleFactor(0.6)
                        Text(String(format: "%.1f km", s.distKm))
                            .font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 4) {
                        Image(systemName: s.active ? "figure.walk.arrival" : "checkmark.circle.fill")
                            .font(.caption2).foregroundStyle(inboundAccent)
                        Text(s.active ? "Vindo até você" : "Chegou")
                            .font(.caption2).foregroundStyle(inboundAccent)
                            .lineLimit(1).minimumScaleFactor(0.6)
                        Spacer(minLength: 4)
                    }
                }
            } compactLeading: {
                Image(systemName: "figure.walk.arrival").foregroundStyle(inboundAccent)
            } compactTrailing: {
                Text(inboundEta(s.etaMin)).bold().foregroundStyle(inboundAccent)
                    .lineLimit(1).minimumScaleFactor(0.5)
            } minimal: {
                Image(systemName: "figure.walk.arrival").foregroundStyle(inboundAccent)
            }
            .keylineTint(inboundAccent)
        }
    }
}

struct CompanionInboundLockScreenView: View {
    let state: CompanionInboundActivityAttributes.ContentState
    let name: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: state.active ? "figure.walk.arrival" : "checkmark.circle.fill")
                    .foregroundStyle(inboundAccent)
                Text(state.active ? "\(state.name) está vindo até você" : "\(state.name) chegou")
                    .font(.headline).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 4)
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(inboundEta(state.etaMin))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(inboundAccent).lineLimit(1).minimumScaleFactor(0.6)
                    Text("TEMPO").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary).tracking(0.4)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.1f", state.distKm))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(inboundAccent).lineLimit(1).minimumScaleFactor(0.6)
                    Text("KM").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary).tracking(0.4)
                }
            }
        }
        .padding(14)
    }
}
