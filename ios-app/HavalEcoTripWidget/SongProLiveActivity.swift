//
//  SongProLiveActivity.swift
//  Live Activity da BYD Song Pro (Grasi) — visual idêntico ao Charge,
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

// Anel ao redor do carro pra Dynamic Island compact/minimal. Reduz a área
// ocupada quando há 2 LAs (Haval verde + BYD azul) ativas ao mesmo tempo.
private struct SongProCarRing: View {
    let soc: Double
    let charging: Bool
    let accent: Color
    var body: some View {
        ZStack {
            Circle().stroke(accent.opacity(0.25), lineWidth: 2.2)
            Circle().trim(from: 0, to: CGFloat(min(100, max(0, soc)) / 100))
                .stroke(accent, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: charging ? "bolt.car.fill" : "checkmark.circle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(accent)
        }
        .frame(width: 22, height: 22)
    }
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
                            .lineLimit(1).minimumScaleFactor(0.5)
                        Text(songProRemainingLabel(s.remainingMin))
                            .font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        SongProBar(soc: s.soc, accent: s.charging ? songProAccent : .blue)
                        // Label expandido em HStack manual: o `Label` nativo perdia o
                        // ícone na borda da DI (corte da safe-area). Image fixa + Text
                        // com minScale garante que ambos cabem mesmo apertado.
                        HStack(spacing: 4) {
                            Image(systemName: s.charging ? "bolt.car.fill" : "checkmark.circle.fill")
                                .font(.caption2).foregroundStyle(s.charging ? songProAccent : .blue)
                            Text(s.charging ? "Carregando" : "Concluído")
                                .font(.caption2).foregroundStyle(s.charging ? songProAccent : .blue)
                                .lineLimit(1).minimumScaleFactor(0.6)
                            Spacer(minLength: 4)
                            Text("BYD da Grasi")
                                .font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(1).minimumScaleFactor(0.5)
                                .layoutPriority(1)
                        }
                    }
                }
            } compactLeading: {
                SongProCarRing(soc: s.soc, charging: s.charging, accent: s.charging ? songProAccent : .blue)
            } compactTrailing: {
                // Vazio: anel já mostra o SOC. Libera espaço pra LA Haval coexistir.
                EmptyView()
            } minimal: {
                SongProCarRing(soc: s.soc, charging: s.charging, accent: s.charging ? songProAccent : .blue)
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
                Text(state.charging ? "Carregando · BYD da Grasi" : "Recarga concluída · BYD da Grasi")
                    .font(.headline).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 6)
                Text(carName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(Int(state.soc))")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundStyle(accent)
                Text("%").font(.title3).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f kW", state.powerKw))
                    .font(.title3).bold().foregroundStyle(accent)
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            SongProBar(soc: state.soc, accent: accent)
            HStack(spacing: 6) {
                Label(songProRemainingLabel(state.remainingMin), systemImage: "clock")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 6)
                Label(String(format: "%.2f kWh", state.sessionKwh), systemImage: "bolt.batteryblock")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.6).layoutPriority(1)
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
