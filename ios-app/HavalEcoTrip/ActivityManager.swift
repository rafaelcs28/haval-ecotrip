//
//  ActivityManager.swift
//  Versão app-driven (free Apple ID, sem AuthKey APNs paga):
//   - request() inicia uma Activity local.
//   - Enquanto app está em foreground, um Task em loop faz polling do bridge
//     a cada 5s e chama Activity.update() com o novo content-state.
//   - Quando o iPhone bloqueia, o iOS pode matar o app em ~30s; a Activity
//     continua exibida com o ÚLTIMO estado até o user desbloquear/reabrir
//     o app — limitação conhecida sem APNs push.
//   - Se mais tarde você pagar a Developer Account (US$ 99/ano), basta
//     trocar `pushType: nil` por `pushType: .token` e configurar o bridge
//     com a AuthKey — o backend APNs já está pronto.
//
import Foundation
import ActivityKit

@MainActor
final class ActivityManager: ObservableObject {

    @Published var currentActivity: Activity<ChargeActivityAttributes>?
    @Published var status: String = "Inativo"

    private var pollingTask: Task<Void, Never>?
    private let pollInterval: TimeInterval = 5    // 5s entre polls

    func start() async {
        guard Settings.isConfigured else {
            status = "Configure URL e token primeiro"
            return
        }
        if let active = Activity<ChargeActivityAttributes>.activities.first(where: { $0.activityState == .active }) {
            currentActivity = active
            status = "Activity já ativa — retomando polling"
            startPolling()
            return
        }
        let attributes = ChargeActivityAttributes(carName: "Haval H6 PHEV")
        let initial = ChargeActivityAttributes.ContentState(
            soc: 0, powerKw: 0, sessionKwh: 0, remainingMin: 0, charging: false,
            updatedAtMs: Date().timeIntervalSince1970 * 1000
        )
        do {
            let content = ActivityContent(state: initial, staleDate: Date().addingTimeInterval(60 * 60))
            // pushType nil = app-driven. Pra trocar pra push remoto: .token
            // (requer Apple Developer Program pago + AuthKey APNs configurada).
            let activity = try Activity<ChargeActivityAttributes>.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
            currentActivity = activity
            status = "Activity iniciada — polling…"
            startPolling()
        } catch {
            status = "Erro: \(error.localizedDescription)"
        }
    }

    func stop() async {
        stopPolling()
        guard let activity = currentActivity else { return }
        let final = ChargeActivityAttributes.ContentState(
            soc: 0, powerKw: 0, sessionKwh: 0, remainingMin: 0, charging: false,
            updatedAtMs: Date().timeIntervalSince1970 * 1000
        )
        let content = ActivityContent(state: final, staleDate: nil)
        await activity.end(content, dismissalPolicy: .immediate)
        currentActivity = nil
        status = "Encerrada"
    }

    // ── Polling loop ──────────────────────────────────────────────────────────
    private func startPolling() {
        stopPolling()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(nanoseconds: UInt64(5 * 1_000_000_000))
            }
        }
    }

    private func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func pollOnce() async {
        guard let activity = currentActivity else { return }
        guard let url = URL(string: Settings.bridgeURL + "/api/state") else {
            status = "URL inválida"; return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 4
        req.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                status = "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)"
                return
            }
            // Bridge devolve um JSON gigante; só nos interessam alguns campos.
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let charging = (json["charging_state"] as? String) == "Carregando"
            let soc      = (json["soc_pct"]              as? Double) ?? 0
            let pwr      = (json["charge_power_kw"]      as? Double) ?? 0
            let kwh      = (json["charge_session_kwh"]   as? Double) ?? 0
            let rem      = (json["charge_remaining_min"] as? Double) ?? 0

            let state = ChargeActivityAttributes.ContentState(
                soc: soc,
                powerKw: pwr,
                sessionKwh: kwh,
                remainingMin: Int(rem.rounded()),
                charging: charging,
                updatedAtMs: Date().timeIntervalSince1970 * 1000
            )
            let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(60 * 60))
            await activity.update(content)
            status = charging
                ? String(format: "Ativa · SOC %.0f%% · %.1f kW", soc, pwr)
                : "Não está carregando"
        } catch {
            status = "Erro fetch: \(error.localizedDescription)"
        }
    }
}
