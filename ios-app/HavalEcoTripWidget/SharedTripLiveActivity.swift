//
//  SharedTripLiveActivity.swift
//  LA "trajeto compartilhado contigo" — aparece só pra Grasi pareada quando
//  o Rafael cria um share no Haval Hub. Toque abre a URL pública do trajeto
//  no Safari (mesma tela que sai do Hub — bridge/public/shared-trip.html),
//  fallback pro deep link do BydRecarga se attrs.shareURL vier vazio.
//
import ActivityKit
import SwiftUI
import WidgetKit

private let stripAccent = Color(red: 0.30, green: 0.80, blue: 0.95)   // ciano
private let stripAccent2 = Color(red: 0.55, green: 0.90, blue: 0.98) // ciano claro (gradient)
private let delayAccent = Color(red: 0.98, green: 0.72, blue: 0.20)   // âmbar (trânsito ruim)
private let dimText = Color(white: 0.75)

@ViewBuilder
private func delayPill(_ delayMin: Int?) -> some View {
    if let d = delayMin, d > 5 {
        HStack(spacing: 3) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9))
            Text("\(d) min hj").font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(delayAccent.opacity(0.22), in: Capsule())
        .foregroundStyle(delayAccent)
    }
}

private func stripEta(_ min: Int) -> String {
    guard min > 0 else { return "—" }
    if min >= 60 { return "~\(min / 60)h\(String(format: "%02d", min % 60))" }
    return "~\(min) min"
}

private func kmStr(_ km: Double) -> String {
    guard km > 0 else { return "—" }
    return String(format: "%.1f", km).replacingOccurrences(of: ".", with: ",") + " km"
}

/// URL que o iOS abre no toque. Prioriza URL pública (Safari); fallback pro
/// deep link do BydRecarga só se shareURL não vier no attrs (LAs antigas).
private func stripLink(_ attrs: SharedTripActivityAttributes) -> URL? {
    if let s = attrs.shareURL, let u = URL(string: s) { return u }
    return URL(string: "grasi-recarga://shared-trip?token=\(attrs.shareToken)")
}

/// Barra de progresso ciano com gradient. Trilho escuro + fill animado.
private struct SharedTripProgressBar: View {
    let progress: Double   // 0..1
    var body: some View {
        GeometryReader { g in
            let p = max(0, min(1, progress))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                Capsule()
                    .fill(LinearGradient(colors: [stripAccent, stripAccent2],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: g.size.width * p)
                    .shadow(color: stripAccent.opacity(0.5), radius: 3, x: 0, y: 0)
            }
        }
        .frame(height: 6)
    }
}

struct SharedTripLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SharedTripActivityAttributes.self) { context in
            SharedTripLockScreenView(state: context.state, attrs: context.attributes)
                .widgetURL(stripLink(context.attributes))
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(stripAccent)

        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.currentAddress?.isEmpty == false ? s.currentAddress! : "Posição atualizando…")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(dimText).lineLimit(1).minimumScaleFactor(0.7)
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down").font(.system(size: 10, weight: .bold))
                                .foregroundStyle(stripAccent)
                            Text(s.destName.isEmpty ? "Trajeto em andamento" : s.destName)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(stripAccent).lineLimit(1).minimumScaleFactor(0.6)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    delayPill(s.delayMin)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        SharedTripProgressBar(progress: s.progress ?? 0)
                        HStack(spacing: 8) {
                            Text(stripEta(s.etaToDestMin))
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(stripAccent)
                            Text("·").foregroundStyle(dimText.opacity(0.6))
                            Text(kmStr(s.distToDestKm))
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(dimText)
                            Spacer()
                        }
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
            .widgetURL(stripLink(context.attributes))
        }
    }
}

struct SharedTripLockScreenView: View {
    let state: SharedTripActivityAttributes.ContentState
    let attrs: SharedTripActivityAttributes

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Linha 1: endereço atual (posição do carro).
            if let addr = state.currentAddress, !addr.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "car.fill").font(.system(size: 11)).foregroundStyle(dimText.opacity(0.7))
                    Text(addr)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(dimText).lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            // Linha 2: seta ↓ destino + pill de atraso.
            HStack(spacing: 6) {
                Image(systemName: "arrow.down").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(stripAccent)
                Text(state.destName.isEmpty ? "Trajeto em andamento" : state.destName)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.6)
                Spacer(minLength: 4)
                delayPill(state.delayMin)
            }
            // Linha 3: barra + ETA + km + "Abrir".
            HStack(spacing: 10) {
                SharedTripProgressBar(progress: state.progress ?? 0)
                    .frame(maxWidth: .infinity)
                Text(stripEta(state.etaToDestMin))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(stripAccent)
                    .fixedSize()
                Text("·").font(.system(size: 12)).foregroundStyle(dimText.opacity(0.6))
                Text(kmStr(state.distToDestKm))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(dimText)
                    .fixedSize()
                Text("Abrir")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(stripAccent.opacity(0.85))
                    .padding(.leading, 2)
                    .fixedSize()
            }
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 10, trailing: 14))
    }
}
