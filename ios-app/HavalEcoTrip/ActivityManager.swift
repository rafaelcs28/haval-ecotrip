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
    // A LA de recarga agora é CRIADA pelo bridge via push-to-start (mesmo com o
    // app fechado). O app não cria mais localmente — apenas adota a que existir
    // (indicador na UI + refresh imediato em foreground). Isso evita LA duplicada.
    func autoStartIfCharging() async {
        guard Settings.isConfigured else { return }
        if let existing = Activity<ChargeActivityAttributes>.activities.first(where: { $0.activityState == .active }) {
            if currentActivity == nil { currentActivity = existing }
            if pollingTask == nil { startPolling() }
            await pollOnce()   // refresh imediato
        }
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
            targetPct: 100,
            updatedAtMs: Date().timeIntervalSince1970 * 1000
        )
        do {
            let content = ActivityContent(state: initial, staleDate: Date().addingTimeInterval(60 * 60))
            let activity = try Activity<ChargeActivityAttributes>.request(
                attributes: attributes,
                content: content
            )
            currentActivity = activity
            status = "Activity iniciada — polling…"
            startPolling()
        } catch {
            status = "Erro: \(error.localizedDescription)"
        }
    }

    // Atualiza a Live Activity ativa diretamente de um payload (sem fetch).
    // Chamado pelo UNUserNotificationCenterDelegate quando chega charge_live.
    static func updateFromPayload(soc: Double, pwr: Double, rem: Double, kwh: Double) async {
        let activities = await MainActor.run {
            Activity<ChargeActivityAttributes>.activities.filter { $0.activityState == .active }
        }
        guard let activity = activities.first else { return }
        // Push charge_live não traz o alvo — preserva o que a LA já mostra (pode ser alvo custom 97%).
        let prevTarget = activity.content.state.targetPct
        let state = ChargeActivityAttributes.ContentState(
            soc: soc, powerKw: pwr, sessionKwh: kwh,
            remainingMin: Int(rem.rounded()), charging: true,
            targetPct: prevTarget,
            updatedAtMs: Date().timeIntervalSince1970 * 1000
        )
        await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(60 * 60)))
    }

    func stop() async {
        stopPolling()
        guard let activity = currentActivity else { return }
        let final = ChargeActivityAttributes.ContentState(
            soc: 0, powerKw: 0, sessionKwh: 0, remainingMin: 0, charging: false,
            targetPct: 100,
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

    // Alvo por software (ex.: 97%) tem prioridade — o carro fica em 100 e o bridge corta.
    nonisolated static func effectiveLimit(_ json: [String: Any]) -> Double {
        let custom = (json["charge_custom_target"] as? Double)
            ?? (json["charge_custom_target"] as? Int).map(Double.init) ?? 0
        return custom > 0 ? custom : (json["charge_limit_pct"] as? Double) ?? 100
    }

    private func pollOnce() async {
        guard let activity = currentActivity else { return }
        guard let url = URL(string: Settings.apiBase + "/api/state") else {
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
                targetPct: Self.effectiveLimit(json),
                updatedAtMs: Date().timeIntervalSince1970 * 1000
            )
            let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(60 * 60))
            if !charging {
                // Recarga encerrada — para Live Activity e keep-alive.
                await stop()
                return
            }
            await activity.update(content)
            status = String(format: "Ativa · SOC %.0f%% · %.1f kW", soc, pwr)
        } catch {
            status = "Erro fetch: \(error.localizedDescription)"
        }
    }
}
