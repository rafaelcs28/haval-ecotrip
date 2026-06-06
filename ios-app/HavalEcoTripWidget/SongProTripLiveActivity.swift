//
//  SongProTripLiveActivity.swift
//  Live Activity de deslocamento do BYD Song Pro (BYD da Grasi) — azul clarinho.
//  Lock screen: tempo · km · SOC lado a lado. Dynamic Island compact/expanded.
//
import ActivityKit
import SwiftUI
import WidgetKit

private let tripAccent = Color(red: 0.45, green: 0.75, blue: 1.0)

private func spTripDuration(_ sec: Int) -> String {
    guard sec > 0 else { return "0min" }
    let h = sec / 3600, m = (sec % 3600) / 60
    return h > 0 ? "\(h)h\(String(format: "%02d", m))" : "\(m)min"
}

// Métrica vertical (valor grande + unidade + rótulo) pro trio lado a lado.
private struct SPTripMetric: View {
    let value: String
    var unit: String = ""
    let label: String
    var color: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.5)
                if !unit.isEmpty {
                    Text(unit).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.6)
                }
            }
            Text(label.uppercased()).font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary).tracking(0.4).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SongProTripLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SongProTripActivityAttributes.self) { context in
            SongProTripLockScreenView(state: context.state, carName: context.attributes.carName)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(tripAccent)

        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: "%.1f km", s.distKm))
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(tripAccent).lineLimit(1).minimumScaleFactor(0.5)
                        Text("BYD da Grasi").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(spTripDuration(s.timeSec))
                            .font(.title3).bold().foregroundStyle(tripAccent)
                            .lineLimit(1).minimumScaleFactor(0.6)
                        Text("\(Int(s.socPct))% SOC").font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 4) {
                        Image(systemName: s.active ? "car.fill" : "checkmark.circle.fill")
                            .font(.caption2).foregroundStyle(tripAccent)
                        Text(s.active ? "Em deslocamento" : "Deslocamento encerrado")
                            .font(.caption2).foregroundStyle(tripAccent)
                            .lineLimit(1).minimumScaleFactor(0.6)
                        Spacer(minLength: 4)
                        Label(String(format: "%.0f km/h", s.avgSpeedKmh), systemImage: "speedometer")
                            .font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.6).layoutPriority(1)
                    }
                }
            } compactLeading: {
                Image(systemName: "car.fill").foregroundStyle(tripAccent)
            } compactTrailing: {
                Text(String(format: "%.1f", s.distKm)).bold().foregroundStyle(tripAccent)
            } minimal: {
                Image(systemName: "car.fill").foregroundStyle(tripAccent)
            }
            .keylineTint(tripAccent)
        }
    }
}

struct SongProTripLockScreenView: View {
    let state: SongProTripActivityAttributes.ContentState
    let carName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: state.active ? "car.fill" : "checkmark.circle.fill")
                    .foregroundStyle(tripAccent)
                Text(state.active ? "Em deslocamento" : "Deslocamento encerrado")
                    .font(.headline).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 6)
                Text(carName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 10) {
                SPTripMetric(value: spTripDuration(state.timeSec), label: "Tempo", color: tripAccent)
                SPTripMetric(value: String(format: "%.1f", state.distKm), unit: "km", label: "Distância", color: tripAccent)
                SPTripMetric(value: "\(Int(state.socPct))", unit: "%", label: "Bateria",
                             color: state.socPct < 15 ? .red : tripAccent)
            }
            HStack {
                Label(String(format: "%.0f km/h média", state.avgSpeedKmh), systemImage: "speedometer")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                Spacer()
            }
            // Distância + tempo de carro do veículo até o celular do monitor (menor caminho).
            if state.active, let d = state.distToPhoneKm, d > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "location.fill.viewfinder").foregroundStyle(tripAccent)
                    Text(String(format: "%.1f km até você", d))
                        .font(.subheadline).fontWeight(.semibold)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    if let m = state.etaToPhoneMin, m > 0 {
                        Text("·").foregroundStyle(.secondary)
                        Text("\(m) min de carro").font(.subheadline)
                            .foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
    }
}
