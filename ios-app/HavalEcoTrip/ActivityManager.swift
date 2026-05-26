//
//  ActivityManager.swift
//  Atualiza a Live Activity de carga em foreground (polling 5s) e via push
//  APNS quando o celular está bloqueado (requer AuthKey .p8 configurada no
//  bridge — ver APNS_ENABLED no .env). Sem a .p8 o pushType é nil e só o
//  polling de foreground funciona; com a .p8 o servidor empurra atualizações
//  diretamente a cada ~60s sem depender do app estar ativo.
//
import Foundation
import ActivityKit

@MainActor
final class ActivityManager: ObservableObject {

    @Published var currentActivity: Activity<ChargeActivityAttributes>?
    @Published var status: String = "Inativo"

    private var pollingTask: Task<Void, Never>?
    private let pollInterval: TimeInterval = 5    // 5s entre polls

    // Auto-start: chamado no .onAppear / scenePhase=active.
    // 2 caminhos:
    //   (a) Já tem Activity → garante polling ativo e força update imediato
    //       (cobre o caso "iPhone bloqueado por horas, Activity congelada").
    //   (b) Sem Activity → se carro está carregando, inicia.
    func autoStartIfCharging() async {
        guard Settings.isConfigured else { return }
        // (a) Activity já existe — pode estar congelada. Garante que o polling
        // está rodando e força 1 update imediato pra trazer dados frescos.
        if let existing = Activity<ChargeActivityAttributes>.activities.first(where: { $0.activityState == .active }) {
            if currentActivity == nil { currentActivity = existing }
            if pollingTask == nil { startPolling() }
            await pollOnce()   // refresh imediato
            return
        }
        // (b) Sem Activity — só cria se carro está carregando
        guard let url = URL(string: Settings.bridgeURL + "/api/state") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 4
        req.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (json["charging_state"] as? String) == "Carregando" else { return }
            await start()
        } catch { /* offline, sem rede etc. — silencia */ }
    }

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
            // pushType: .token — iOS gera um push token único para esta Activity;
            // o app manda pro servidor via /api/activity/start e o bridge usa o
            // apns_live_activity.js pra mandar updates direto no celular bloqueado.
            // Requer APNS_ENABLED=true + AuthKey .p8 no .env do bridge.
            // Se o APNS não estiver configurado, pushType: nil funciona mas só
            // atualiza em foreground.
            let usePushType: Activity<ChargeActivityAttributes>.PushType? = Settings.apnsEnabled ? .token : nil
            let activity = try Activity<ChargeActivityAttributes>.request(
                attributes: attributes,
                content: content,
                pushType: usePushType
            )
            currentActivity = activity
            status = "Activity iniciada — polling…"
            startPolling()
            if usePushType == .token {
                monitorPushToken(activity: activity)
            }
        } catch {
            status = "Erro: \(error.localizedDescription)"
        }
    }

    // ── Push token monitoring (só com pushType: .token) ──────────────────────
    // Monitora atualizações do token e registra no servidor. iOS pode trocar o
    // token durante a vida da Activity, por isso o loop continua até encerrar.
    private func monitorPushToken(activity: Activity<ChargeActivityAttributes>) {
        Task { [weak self] in
            for await tokenData in activity.pushTokenUpdates {
                let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                await self?.registerTokenWithServer(activityId: activity.id, token: hex)
            }
        }
    }

    private func registerTokenWithServer(activityId: String, token: String) async {
        guard let url = URL(string: Settings.bridgeURL + "/api/activity/start") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "activity_id": activityId, "push_token": token
        ])
        req.timeoutInterval = 8
        try? await URLSession.shared.data(for: req)
    }

    // Atualiza a Live Activity ativa diretamente de um payload (sem fetch).
    // Chamado pelo UNUserNotificationCenterDelegate quando chega charge_live.
    static func updateFromPayload(soc: Double, pwr: Double, rem: Double, kwh: Double) async {
        let activities = await MainActor.run {
            Activity<ChargeActivityAttributes>.activities.filter { $0.activityState == .active }
        }
        guard let activity = activities.first else { return }
        let state = ChargeActivityAttributes.ContentState(
            soc: soc, powerKw: pwr, sessionKwh: kwh,
            remainingMin: Int(rem.rounded()), charging: true,
            updatedAtMs: Date().timeIntervalSince1970 * 1000
        )
        await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(60 * 60)))
    }

    func stop() async {
        if let id = currentActivity?.id {
            Task { await unregisterTokenFromServer(activityId: id) }
        }
        ChargingKeepAlive.shared.chargingDidStop()
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

    private func unregisterTokenFromServer(activityId: String) async {
        guard let url = URL(string: Settings.bridgeURL + "/api/activity/stop") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["activity_id": activityId])
        req.timeoutInterval = 8
        try? await URLSession.shared.data(for: req)
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
