//
//  ActivityManager.swift
//  Cuida do ciclo de vida da Live Activity:
//   - request() inicia uma nova Activity com estado vazio.
//   - Observa pushToken e envia pro bridge (POST /api/activity/start).
//   - end() encerra e avisa o bridge.
//
//  Atualizações em tempo real chegam DO bridge via APNs Push (NÃO pelo app):
//  isso é o que permite o Live Activity continuar funcionando com o app
//  totalmente morto.
//
import Foundation
import ActivityKit

@MainActor
final class ActivityManager: ObservableObject {

    @Published var currentActivity: Activity<ChargeActivityAttributes>?
    @Published var status: String = "Inativo"

    func start() async {
        guard Settings.isConfigured else {
            status = "Configure URL e token primeiro"
            return
        }
        // Se já tem activity ativa, não cria outra
        if let active = Activity<ChargeActivityAttributes>.activities.first(where: { $0.activityState == .active }) {
            currentActivity = active
            status = "Activity já ativa"
            await observePushToken(of: active)
            return
        }
        let attributes = ChargeActivityAttributes(carName: "Haval H6 PHEV")
        let initial = ChargeActivityAttributes.ContentState(
            soc: 0, powerKw: 0, sessionKwh: 0, remainingMin: 0, charging: false,
            updatedAtMs: Date().timeIntervalSince1970 * 1000
        )
        do {
            let content = ActivityContent(state: initial, staleDate: Date().addingTimeInterval(60 * 60))
            let activity = try Activity<ChargeActivityAttributes>.request(
                attributes: attributes,
                content: content,
                pushType: .token   // crítico: solicita pushToken pro bridge atualizar
            )
            currentActivity = activity
            status = "Activity iniciada — aguardando pushToken…"
            await observePushToken(of: activity)
        } catch {
            status = "Erro: \(error.localizedDescription)"
        }
    }

    func stop() async {
        guard let activity = currentActivity else { return }
        // Avisa o bridge pra parar de mandar pushes
        await unregisterFromBridge()
        let final = ChargeActivityAttributes.ContentState(
            soc: 0, powerKw: 0, sessionKwh: 0, remainingMin: 0, charging: false,
            updatedAtMs: Date().timeIntervalSince1970 * 1000
        )
        let content = ActivityContent(state: final, staleDate: nil)
        await activity.end(content, dismissalPolicy: .immediate)
        currentActivity = nil
        status = "Encerrada"
    }

    private func observePushToken(of activity: Activity<ChargeActivityAttributes>) async {
        for await tokenData in activity.pushTokenUpdates {
            let tokenHex = tokenData.map { String(format: "%02x", $0) }.joined()
            await registerWithBridge(pushToken: tokenHex, activityId: activity.id)
        }
    }

    private func registerWithBridge(pushToken: String, activityId: String) async {
        guard let url = URL(string: Settings.bridgeURL + "/api/activity/start") else {
            status = "URL inválida"; return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "push_token":  pushToken,
            "activity_id": activityId,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                status = "Conectada ao bridge ✓"
            } else {
                status = "Bridge rejeitou: HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)"
            }
        } catch {
            status = "Erro ao registrar: \(error.localizedDescription)"
        }
    }

    private func unregisterFromBridge() async {
        guard let url = URL(string: Settings.bridgeURL + "/api/activity/stop") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: req)
    }
}
