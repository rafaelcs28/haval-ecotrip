//
//  MotorLiveActivity.swift
//  Live Activity de motor ligado remotamente (lock screen + Dynamic Island).
//  Estilo v2 (gramática da Rodada 9): timer como hero, contexto de cabine e
//  ação Desligar inline (App Intent). Encerra em variante de confirmação.
//
import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct MotorLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MotorActivityAttributes.self) { context in
            MotorLockScreenView(state: context.state, carName: context.attributes.carName)
                .activityBackgroundTint(LAv2.bg)
                .activitySystemActionForegroundColor(context.state.active ? LAv2.orange : LAv2.text2)

        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: s.active ? "key.fill" : "key.slash")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(s.active ? LAv2.orange : LAv2.text2)
                        .frame(width: 40, height: 40)
                        .background((s.active ? LAv2.orange : LAv2.text2).opacity(0.15), in: Circle())
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        if s.active {
                            (Text("Motor ligado há ") + Text(s.startedAt, style: .relative))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(LAv2.orange)
                                .lineLimit(1).minimumScaleFactor(0.7)
                            Text(motorContextLine(s))
                                .font(.system(size: 11.5)).foregroundStyle(LAv2.text2)
                                .lineLimit(1).minimumScaleFactor(0.6)
                        } else {
                            Text("Motor desligado")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(LAv2.text2)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if s.active {
                        if #available(iOS 17.0, *) { EngineOffPillButton() }
                    }
                }
            } compactLeading: {
                Image(systemName: s.active ? "key.fill" : "key.slash")
                    .foregroundStyle(s.active ? LAv2.orange : LAv2.text2)
            } compactTrailing: {
                if s.active {
                    Text(s.startedAt, style: .timer)
                        .font(.system(size: 12, weight: .bold)).monospacedDigit()
                        .foregroundStyle(LAv2.orange)
                        .frame(maxWidth: 46)
                        .lineLimit(1).minimumScaleFactor(0.5)
                }
            } minimal: {
                Image(systemName: s.active ? "key.fill" : "key.slash")
                    .foregroundStyle(s.active ? LAv2.orange : LAv2.text2)
            }
            .keylineTint(s.active ? LAv2.orange : LAv2.text2)
        }
    }
}

// MARK: - Lock screen

struct MotorLockScreenView: View {
    let state: MotorActivityAttributes.ContentState
    let carName: String

    var body: some View {
        Group {
            if state.active { runningBody } else { endedBody }
        }
        .padding(14)
        .background(alignment: .topLeading) {
            RadialGradient(colors: [(state.active ? LAv2.orange : LAv2.green).opacity(0.14), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 220)
        }
    }

    private var runningBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header: tile + carro | tag LIGADO
            HStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(.black)
                    .frame(width: 22, height: 22)
                    .background(LAv2.orange, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(carName)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(LAv2.text)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 6)
                Text("MOTOR LIGADO")
                    .font(.system(size: 10, weight: .bold)).tracking(1)
                    .foregroundStyle(LAv2.orange)
            }
            // Corpo: PNG do carro | timer hero + contexto | Desligar
            HStack(alignment: .center, spacing: 13) {
                Image("haval_h6_top")
                    .resizable().scaledToFit()
                    .frame(width: 56, height: 56)
                    .shadow(color: .black.opacity(0.5), radius: 6, y: 3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.startedAt, style: .timer)
                        .font(.system(size: 26, weight: .light)).tracking(-0.5)
                        .monospacedDigit()
                        .foregroundStyle(LAv2.orange)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text(motorContextLine(state))
                        .font(.system(size: 11.5)).foregroundStyle(LAv2.text)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text(state.acOn ? "A/C ligado · climatizando" : "A/C desligado")
                        .font(.system(size: 10.5))
                        .foregroundStyle(state.acOn ? LAv2.teal : LAv2.text2)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                Spacer(minLength: 8)
                VStack(spacing: 4) {
                    if #available(iOS 17.0, *) { EngineOffPillButton() }
                    Text("desliga na hora")
                        .font(.system(size: 8.5)).foregroundStyle(LAv2.muted)
                }
            }
            // Rodapé: lembrete | hora
            VStack(spacing: 8) {
                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
                HStack {
                    Text("Não esqueça o motor ligado")
                        .font(.system(size: 10.5)).foregroundStyle(LAv2.text2)
                    Spacer(minLength: 6)
                    Text(state.updatedAt, format: .dateTime.hour().minute())
                        .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(LAv2.muted)
                }
            }
        }
    }

    // Variante de confirmação (motor desligou) — bridge encerra com dismissal.
    private var endedBody: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 34)).foregroundStyle(LAv2.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Motor desligado")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(LAv2.text)
                Text("ficou ligado por \(runMinutes) min")
                    .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(LAv2.text2)
            }
            Spacer(minLength: 6)
            Text(state.updatedAt, format: .dateTime.hour().minute())
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(LAv2.muted)
        }
    }

    private var runMinutes: Int {
        max(0, Int((state.updatedAtMs - state.startedAtMs) / 60_000))
    }
}

// Botão Desligar (pill orange, texto preto) — App Intent, sem abrir o app.
@available(iOS 17.0, *)
private struct EngineOffPillButton: View {
    var body: some View {
        Button(intent: EngineOffIntent()) {
            Text("Desligar")
                .font(.system(size: 13, weight: .bold)).foregroundStyle(.black)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 18).padding(.vertical, 9)
                .background(LAv2.orange, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

// Linha de contexto: cabine · externa.
private func motorContextLine(_ s: MotorActivityAttributes.ContentState) -> String {
    "cabine \(Int(s.cabinTemp.rounded()))° · externa \(Int(s.outsideTemp.rounded()))°"
}
