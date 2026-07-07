//
//  SecurityLiveActivity.swift
//  Live Activity de carro destravado/desprotegido (lock screen + Dynamic Island).
//  Estilo v2 Rodada 9 (frame 9b): gramática de anomalia — o que está aberto,
//  há quanto tempo, distância do usuário e ação Travar inline (App Intent).
//  Resolvido → variante verde de confirmação que se dispensa sozinha.
//
import ActivityKit
import SwiftUI
import WidgetKit

struct SecurityLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SecurityActivityAttributes.self) { context in
            SecurityLockScreenView(state: context.state, carName: context.attributes.carName)
                .activityBackgroundTint(LAv2.bg)
                .activitySystemActionForegroundColor(context.state.active ? LAv2.red : LAv2.green)

        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: s.active ? "lock.open.fill" : "checkmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(s.active ? LAv2.red : LAv2.green)
                        .frame(width: 40, height: 40)
                        .background((s.active ? LAv2.red : LAv2.green).opacity(0.15), in: Circle())
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        if s.active {
                            (Text(securityHeadline(s)) + sinceText(s))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(LAv2.red)
                                .lineLimit(1).minimumScaleFactor(0.7)
                            Text(securityIssueLine(s))
                                .font(.system(size: 11.5)).foregroundStyle(LAv2.text2)
                                .lineLimit(1).minimumScaleFactor(0.6)
                        } else {
                            Text("Travado · o carro confirmou")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(LAv2.green)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if s.active, s.unlocked {
                        if #available(iOS 17.0, *) { LockPillButton() }
                    }
                }
            } compactLeading: {
                Image(systemName: s.active ? "lock.open.fill" : "lock.fill")
                    .foregroundStyle(s.active ? LAv2.red : LAv2.green)
            } compactTrailing: {
                if s.active, let since = s.since {
                    Text(since, style: .relative)
                        .font(.system(size: 12, weight: .bold)).monospacedDigit()
                        .foregroundStyle(LAv2.red)
                        .frame(maxWidth: 46)
                        .lineLimit(1).minimumScaleFactor(0.5)
                } else if s.active {
                    Text("\(s.openCount)").bold().foregroundStyle(LAv2.red)
                }
            } minimal: {
                Image(systemName: s.active ? "lock.open.fill" : "lock.fill")
                    .foregroundStyle(s.active ? LAv2.red : LAv2.green)
            }
            .keylineTint(s.active ? LAv2.red : LAv2.green)
        }
    }
}

// MARK: - Lock screen

struct SecurityLockScreenView: View {
    let state: SecurityActivityAttributes.ContentState
    let carName: String

    var body: some View {
        Group {
            if state.active { alertBody } else { confirmBody }
        }
        .padding(14)
        .background(alignment: .topLeading) {
            RadialGradient(colors: [(state.active ? LAv2.red : LAv2.green).opacity(0.14), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 220)
        }
    }

    // Variante de anomalia (destravado / algo aberto).
    private var alertBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header: tile + local | tag ATENÇÃO
            HStack(spacing: 8) {
                Image(systemName: "lock.open.fill")
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(.black)
                    .frame(width: 22, height: 22)
                    .background(LAv2.red, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(state.locationShort.map { "Haval · \($0)" } ?? carName)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(LAv2.text)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 6)
                Text("ATENÇÃO")
                    .font(.system(size: 10, weight: .bold)).tracking(1)
                    .foregroundStyle(LAv2.red)
            }
            // Corpo: PNG do carro | estado + contexto | Travar
            HStack(alignment: .center, spacing: 13) {
                Image("haval_h6_top")
                    .resizable().scaledToFit()
                    .frame(width: 56, height: 56)
                    .shadow(color: .black.opacity(0.5), radius: 6, y: 3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(securityHeadline(state))
                        .font(.system(size: 26, weight: .light)).tracking(-0.5)
                        .foregroundStyle(LAv2.red)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text(securityIssueLine(state))
                        .font(.system(size: 11.5)).foregroundStyle(LAv2.text)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    contextLine
                        .font(.system(size: 10.5)).monospacedDigit()
                        .foregroundStyle(LAv2.text2)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                Spacer(minLength: 8)
                if state.unlocked {
                    VStack(spacing: 4) {
                        if #available(iOS 17.0, *) { LockPillButton() }
                        Text("fecha vidros junto")
                            .font(.system(size: 8.5)).foregroundStyle(LAv2.muted)
                    }
                }
            }
            // Rodapé: o que está OK | ver no mapa
            VStack(spacing: 8) {
                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
                HStack {
                    Text(securityOkLine(state))
                        .font(.system(size: 10.5)).foregroundStyle(LAv2.text2)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: 6)
                    Link(destination: URL(string: "havalecotrip://")!) {
                        Text("Ver no mapa →")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(LAv2.text2)
                    }
                }
            }
        }
    }

    // Variante verde de confirmação (após travar) — bridge encerra com dismissal.
    private var confirmBody: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 34)).foregroundStyle(LAv2.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Travado · o carro confirmou")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(LAv2.text)
                Text(confirmSub)
                    .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(LAv2.text2)
            }
            Spacer(minLength: 6)
            Text(state.updatedAt, format: .dateTime.hour().minute())
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(LAv2.muted)
        }
    }

    private var contextLine: Text {
        var t = Text("")
        if let since = state.since {
            t = Text("há ") + Text(since, style: .relative)
        }
        if let d = state.userDistKm {
            let sep = state.since != nil ? " · " : ""
            t = t + Text("\(sep)você a \(d < 1 ? "\(Int(d * 1000)) m" : "\(laDec1(d)) km")")
        }
        return t
    }

    private var confirmSub: String {
        if let s = state.confirmSec, s > 0 { return "tudo fechado · respondeu em \(laDec1(s)) s" }
        return "tudo fechado e trancado"
    }
}

// Botão Travar (pill red, texto preto) — App Intent, trava sem abrir o app.
@available(iOS 17.0, *)
private struct LockPillButton: View {
    var body: some View {
        Button(intent: LockCarIntent()) {
            Text("Travar")
                .font(.system(size: 13, weight: .bold)).foregroundStyle(.black)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 18).padding(.vertical, 9)
                .background(LAv2.red, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Texto

// Palavra-estado grande: destravado domina; senão o que estiver aberto.
func securityHeadline(_ s: SecurityActivityAttributes.ContentState) -> String {
    if s.unlocked { return "Destravado" }
    if s.anyDoor { return "Aberto" }
    if s.anyWindow || s.sunroof { return "Vidro aberto" }
    return "Atenção"
}

private func sinceText(_ s: SecurityActivityAttributes.ContentState) -> Text {
    guard let since = s.since else { return Text("") }
    return Text(" há ") + Text(since, style: .relative)
}

// Linha do que está aberto (sem repetir "Destrancado", que já é o headline).
func securityIssueLine(_ s: SecurityActivityAttributes.ContentState) -> String {
    var items: [String] = []
    if s.doorFL { items.append("Porta diant. esq.") }
    if s.doorFR { items.append("Porta diant. dir.") }
    if s.doorRL { items.append("Porta tras. esq.") }
    if s.doorRR { items.append("Porta tras. dir.") }
    if s.trunk  { items.append("Porta-malas") }
    if s.winFL  { items.append("Vidro diant. esq.") }
    if s.winFR  { items.append("Vidro diant. dir.") }
    if s.winRL  { items.append("Vidro tras. esq.") }
    if s.winRR  { items.append("Vidro tras. dir.") }
    if s.sunroof { items.append("Teto solar") }
    if items.isEmpty { return "portas e vidros fechados" }
    let line = items.prefix(2).joined(separator: " · ")
    return items.count > 2 ? "\(line) +\(items.count - 2)" : "\(line) aberto"
}

// Rodapé: o que está OK (inverso dos issues).
func securityOkLine(_ s: SecurityActivityAttributes.ContentState) -> String {
    var ok: [String] = []
    if !s.anyDoor { ok.append("Portas fechadas") }
    if !s.anyWindow { ok.append("vidros fechados") }
    if !s.sunroof { ok.append("teto fechado") }
    return ok.isEmpty ? "Verifique o carro" : ok.joined(separator: " · ")
}
