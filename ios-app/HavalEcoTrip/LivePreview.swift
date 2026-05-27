//
//  LivePreview.swift
//  Inicia as Live Activities LOCALMENTE com dados de exemplo — sem APNs/push,
//  então sem limite de push-to-start. Serve só pra validar o layout na tela
//  bloqueada / Dynamic Island a qualquer momento (botões nas Configurações).
//
import Foundation
import ActivityKit

@MainActor
enum LivePreview {
    private static let carName = "Haval H6 PHEV"

    static func charge() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        endActive(Activity<ChargeActivityAttributes>.activities)
        let state = ChargeActivityAttributes.ContentState(
            soc: 78, powerKw: 12.4, sessionKwh: 8.2, remainingMin: 65,
            charging: true, targetPct: 80, updatedAtMs: Date().timeIntervalSince1970 * 1000)
        _ = try? Activity.request(
            attributes: ChargeActivityAttributes(carName: carName),
            content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(3600)))
    }

    static func preclimat() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        endActive(Activity<PreClimatActivityAttributes>.activities)
        let now = Date()
        let state = PreClimatActivityAttributes.ContentState(
            phase: "cooling", detail: "Climatizando", temp: 22, fan: 3,
            tempIn: 23, tempOut: 31,
            endsAtMs: now.addingTimeInterval(1200).timeIntervalSince1970 * 1000,
            updatedAtMs: now.timeIntervalSince1970 * 1000)
        _ = try? Activity.request(
            attributes: PreClimatActivityAttributes(scheduledTime: "07:30", carName: carName),
            content: ActivityContent(state: state, staleDate: now.addingTimeInterval(1200)))
    }

    // Encerra todas as Live Activities ativas (recarga + pré-climatização).
    static func stopAll() {
        endActive(Activity<ChargeActivityAttributes>.activities)
        endActive(Activity<PreClimatActivityAttributes>.activities)
    }

    // Encerra atividades ativas do tipo antes de criar a de preview (evita duplicar).
    private static func endActive<T: ActivityAttributes>(_ activities: [Activity<T>]) {
        for a in activities where a.activityState == .active {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
