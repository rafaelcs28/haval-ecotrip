//
//  LiveActivityPush.swift
//  Registra no bridge os tokens APNs das Live Activities (conta paga):
//   - push-to-start token (por TIPO): permite o SERVIDOR criar a LA com o app
//     fechado/bloqueado (iOS 17.2+).
//   - update token (por atividade): permite o servidor atualizar/encerrar a LA.
//
//  Substitui o antigo keep-alive de localização/áudio — agora quem dirige as
//  Live Activities é o bridge via APNs.
//
import Foundation
import ActivityKit

@MainActor
final class LiveActivityPush {
    static let shared = LiveActivityPush()
    private init() {}
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        observe(ChargeActivityAttributes.self,   type: "ChargeActivityAttributes")
        observe(PreClimatActivityAttributes.self, type: "PreClimatActivityAttributes")
        observe(TripActivityAttributes.self,      type: "TripActivityAttributes")
        observe(MotorActivityAttributes.self,     type: "MotorActivityAttributes")
        observe(SecurityActivityAttributes.self,  type: "SecurityActivityAttributes")
    }

    private func observe<T: ActivityAttributes>(_ attr: T.Type, type: String) {
        // Push-to-start token (iOS 17.2+).
        if #available(iOS 17.2, *) {
            Task {
                for await tokenData in Activity<T>.pushToStartTokenUpdates {
                    await register("/api/activity/pts-token", body: [
                        "type": type,
                        "push_to_start_token": hex(tokenData),
                        "device_id": Settings.notifDeviceId,
                    ])
                }
            }
        }
        // Atividades já ativas + futuras (inclui as criadas por push-to-start).
        for activity in Activity<T>.activities { track(activity, type: type) }
        Task {
            for await activity in Activity<T>.activityUpdates { track(activity, type: type) }
        }
    }

    private func track<T: ActivityAttributes>(_ activity: Activity<T>, type: String) {
        let id = activity.id
        Task {
            for await tokenData in activity.pushTokenUpdates {
                await register("/api/activity/start", body: [
                    "type": type, "activity_id": id,
                    "push_token": hex(tokenData),
                    "device_id": Settings.notifDeviceId,
                ])
            }
        }
        Task {
            for await state in activity.activityStateUpdates {
                if state == .dismissed || state == .ended {
                    await register("/api/activity/stop", body: ["activity_id": id])
                }
            }
        }
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func register(_ pathSuffix: String, body: [String: Any]) async {
        guard Settings.isConfigured, let url = URL(string: Settings.bridgeURL + pathSuffix) else { return }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = "POST"
        req.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
    }
}
