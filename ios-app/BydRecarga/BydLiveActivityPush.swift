//
//  BydLiveActivityPush.swift
//  Versão minimal do LiveActivityPush — registra SÓ o push-to-start token da
//  Live Activity do BYD Song Pro. O bridge cria/atualiza/encerra a LA via APNs
//  (push-to-start, iOS 17.2+) quando o BYD começa/termina a carregar.
//
import Foundation
import ActivityKit

@MainActor
final class BydLiveActivityPush {
    static let shared = BydLiveActivityPush()
    private init() {}
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        observe()
    }

    private func observe() {
        // Push-to-start token (iOS 17.2+) — permite o bridge CRIAR a LA com o
        // app fechado/bloqueado.
        if #available(iOS 17.2, *) {
            Task {
                for await tokenData in Activity<SongProActivityAttributes>.pushToStartTokenUpdates {
                    await register("/api/activity/pts-token", body: [
                        "type": "SongProActivityAttributes",
                        "push_to_start_token": hex(tokenData),
                        "device_id": BydSettings.deviceId,
                    ])
                }
            }
        }
        // Atividades já ativas + futuras (inclui as criadas por push-to-start).
        for activity in Activity<SongProActivityAttributes>.activities { track(activity) }
        Task {
            for await activity in Activity<SongProActivityAttributes>.activityUpdates {
                track(activity)
            }
        }
    }

    private func track(_ activity: Activity<SongProActivityAttributes>) {
        let id = activity.id
        Task {
            for await tokenData in activity.pushTokenUpdates {
                await register("/api/activity/start", body: [
                    "type": "SongProActivityAttributes", "activity_id": id,
                    "push_token": hex(tokenData),
                    "device_id": BydSettings.deviceId,
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
        guard BydSettings.isConfigured,
              let url = URL(string: BydSettings.baseURL + pathSuffix) else { return }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = "POST"
        req.addValue("Bearer " + BydSettings.bridgeToken, forHTTPHeaderField: "Authorization")
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
    }
}
