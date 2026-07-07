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
            charging: true, targetPct: 80, costBrl: 9.84,
            updatedAtMs: Date().timeIntervalSince1970 * 1000)
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

    static func trip() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        endActive(Activity<TripActivityAttributes>.activities)
        let state = TripActivityAttributes.ContentState(
            distKm: 23.7, netKwh: 4.1, effKwh100: 17.3, timeSec: 1860,
            avgSpeedKmh: 46, fuelL: 0, active: true,
            updatedAtMs: Date().timeIntervalSince1970 * 1000,
            socPct: 71, rangeKm: 48,
            speedKmh: 72, destName: "Escritório", destEtaMin: 8, destKm: 8.2)
        _ = try? Activity.request(
            attributes: TripActivityAttributes(carName: carName),
            content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(3600)))
    }

    static func motor() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        endActive(Activity<MotorActivityAttributes>.activities)
        let now = Date()
        let state = MotorActivityAttributes.ContentState(
            startedAtMs: now.addingTimeInterval(-360).timeIntervalSince1970 * 1000,  // ligado há 6 min
            cabinTemp: 24, outsideTemp: 31, acOn: true, active: true,
            updatedAtMs: now.timeIntervalSince1970 * 1000)
        _ = try? Activity.request(
            attributes: MotorActivityAttributes(carName: carName),
            content: ActivityContent(state: state, staleDate: now.addingTimeInterval(3600)))
    }

    static func security() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        endActive(Activity<SecurityActivityAttributes>.activities)
        let state = SecurityActivityAttributes.ContentState(
            unlocked: true,
            doorFL: true, doorFR: false, doorRL: false, doorRR: false,
            winFL: false, winFR: false, winRL: false, winRR: true,
            trunk: false, sunroof: true,
            summary: "Destrancado · Porta diant. esq. · Vidro tras. dir. · Teto solar",
            active: true,
            updatedAtMs: Date().timeIntervalSince1970 * 1000,
            sinceMs: Date().addingTimeInterval(-720).timeIntervalSince1970 * 1000,  // há 12 min
            userDistKm: 1.2,
            locationShort: "Estac. Flamboyant G2")
        _ = try? Activity.request(
            attributes: SecurityActivityAttributes(carName: carName),
            content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(3600)))
    }

    static func parking() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        endActive(Activity<ParkingActivityAttributes>.activities)
        let now = Date()
        let state = ParkingActivityAttributes.ContentState(
            distM: 340, bearingDeg: 45,
            carLat: -16.6725, carLng: -49.2554,
            parkedAtMs: now.addingTimeInterval(-1500).timeIntervalSince1970 * 1000,  // estac. há 25 min
            updatedAtMs: now.timeIntervalSince1970 * 1000)
        _ = try? Activity.request(
            attributes: ParkingActivityAttributes(carName: carName),
            content: ActivityContent(state: state, staleDate: now.addingTimeInterval(3600)))
    }

    // Encerra todas as Live Activities ativas.
    static func stopAll() {
        endActive(Activity<ChargeActivityAttributes>.activities)
        endActive(Activity<PreClimatActivityAttributes>.activities)
        endActive(Activity<TripActivityAttributes>.activities)
        endActive(Activity<MotorActivityAttributes>.activities)
        endActive(Activity<SecurityActivityAttributes>.activities)
        endActive(Activity<ParkingActivityAttributes>.activities)
    }

    // Encerra atividades ativas do tipo antes de criar a de preview (evita duplicar).
    private static func endActive<T: ActivityAttributes>(_ activities: [Activity<T>]) {
        for a in activities where a.activityState == .active {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
