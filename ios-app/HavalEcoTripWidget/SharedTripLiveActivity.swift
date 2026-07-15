//
//  SharedTripLiveActivity.swift
//  Visual da LA "trajeto compartilhado contigo" — cor azul ciano. Toque na LA
//  abre o deep link grasi-recarga://shared-trip?token=<TOKEN>, que o app
//  Grasi Recarga intercepta e mostra a página do trajeto.
//
import ActivityKit
import SwiftUI
import WidgetKit

private let stripAccent = Color(red: 0.30, green: 0.80, blue: 0.95)   // ciano
private let delayAccent = Color(red: 0.98, green: 0.72, blue: 0.20)   // âmbar (trânsito ruim)

/// Pill "Atraso de X min hoje" — só quando o bridge devolve delayMin > threshold
/// (5min). Escondida em delay ≤ 5min (dentro do normal) ou nil (sem cálculo).
@ViewBuilder
private func delayPill(_ delayMin: Int?) -> some View {
    if let d = delayMin, d > 5 {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill").font(.caption2)
            Text("Atraso de \(d) min hoje").font(.caption2).bold()
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(delayAccent.opacity(0.22), in: Capsule())
        .foregroundStyle(delayAccent)
    }
}

private func stripEta(_ min: Int) -> String {
    guard min > 0 else { return "—" }
    if min >= 60 { return "~\(min / 60)h\(String(format: "%02d", min % 60))" }
    return "~\(min) min"
}

/// URL que o iOS abre quando o usuário toca na LA. Custom scheme do app —
/// quem captura é o BydRecargaApp.onOpenURL no Grasi Recarga.
private func stripDeepLink(_ token: String) -> URL? {
    URL(string: "grasi-recarga://shared-trip?token=\(token)")
}

struct SharedTripLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SharedTripActivityAttributes.self) { context in
            SharedTripLockScreenView(state: context.state, attrs: context.attributes)
                .widgetURL(stripDeepLink(context.attributes.shareToken))
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(stripAccent)

        } dynamicIsland: { context in
            let s = context.state
            let token = context.attributes.shareToken
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.from)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(stripAccent).lineLimit(1).minimumScaleFactor(0.5)
                        Text("compartilhou trajeto").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(stripEta(s.etaToDestMin))
                            .font(.title3).bold().foregroundStyle(stripAccent)
                            .lineLimit(1).minimumScaleFactor(0.6)
                        Text("\(s.socPct)% SOC").font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 4) {
                        Image(systemName: s.moving ? "car.fill" : "parkingsign.circle")
                            .font(.caption2).foregroundStyle(stripAccent)
                        Text(s.destName.isEmpty ? "Trajeto em andamento" : "Indo pra \(s.destName)")
                            .font(.caption2).foregroundStyle(stripAccent)
                            .lineLimit(1).minimumScaleFactor(0.6)
                        Spacer(minLength: 4)
                        delayPill(s.delayMin)
                    }
                }
            } compactLeading: {
                Image(systemName: "shared.with.you").foregroundStyle(stripAccent)
            } compactTrailing: {
                Text(stripEta(s.etaToDestMin)).bold().foregroundStyle(stripAccent)
                    .lineLimit(1).minimumScaleFactor(0.5)
            } minimal: {
                Image(systemName: "shared.with.you").foregroundStyle(stripAccent)
            }
            .keylineTint(stripAccent)
            .widgetURL(stripDeepLink(token))
        }
    }
}

struct SharedTripLockScreenView: View {
    let state: SharedTripActivityAttributes.ContentState
    let attrs: SharedTripActivityAttributes

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "shared.with.you").foregroundStyle(stripAccent)
                Text("\(attrs.from) compartilhou trajeto")
                    .font(.headline).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                Text("Toque pra abrir").font(.caption2).foregroundStyle(.secondary)
            }
            if !state.destName.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "mappin.and.ellipse").font(.caption).foregroundStyle(.secondary)
                    Text("Indo pra \(state.destName)").font(.subheadline)
                        .foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: 4)
                    delayPill(state.delayMin)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(stripEta(state.etaToDestMin))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(stripAccent).lineLimit(1).minimumScaleFactor(0.6)
                    Text("TEMPO").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary).tracking(0.4)
                }
                Spacer()
                VStack(alignment: .center, spacing: 2) {
                    Text(state.distToDestKm > 0 ? String(format: "%.1f", state.distToDestKm) : "—")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(stripAccent).lineLimit(1).minimumScaleFactor(0.6)
                    Text("KM").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary).tracking(0.4)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(state.socPct)")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(state.socPct < 15 ? .red : stripAccent)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text("% SOC").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary).tracking(0.4)
                }
            }
        }
        .padding(14)
    }
}
