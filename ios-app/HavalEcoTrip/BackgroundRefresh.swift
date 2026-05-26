//
//  BackgroundRefresh.swift
//  Acorda o app em background periodicamente pra puxar notificações novas
//  do bridge. iOS decide quando rodar (geralmente 15-30min de intervalo) e
//  dá ~30s pra completar antes de suspender de novo.
//
//  Limitações Apple:
//   - Sem garantia de frequência; iOS aprende quando o user usa o app.
//   - Se user mata o app por swipe, BG refresh para até o app ser reaberto.
//   - "Atualização em 2º plano" precisa estar ON em Ajustes > Geral.
//
//  Em conjunto com o polling de foreground (30s) e o PWA standalone (Web
//  Push instantâneo), forma uma rede que cobre a maioria dos cenários.
//
import Foundation
import BackgroundTasks
import UserNotifications
import ActivityKit

enum BackgroundRefresh {
    static let identifier = "br.com.consorciolimpagyn.havalecotrip.notif-refresh"

    /// Registra o handler. Chame no init do App (antes de App.body).
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            handle(task: refreshTask)
        }
    }

    /// Agenda a próxima execução. Chame quando app vai pra background.
    static func schedule() {
        let req = BGAppRefreshTaskRequest(identifier: identifier)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)  // mín 15min
        do {
            try BGTaskScheduler.shared.submit(req)
        } catch {
            print("[bgrefresh] falha submit:", error)
        }
    }

    private static func handle(task: BGAppRefreshTask) {
        // Reagenda IMEDIATAMENTE — iOS pode matar antes de terminar
        schedule()

        let work = Task {
            // Notificações agora chegam por APNs (não fazemos mais polling do
            // histórico aqui — evitaria duplicar com o alerta APNs). Mantemos só
            // a atualização da Live Activity de recarga como fallback.
            await updateActiveLiveActivity()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }

    /// Pega a primeira Activity ativa do app e chama Activity.update() com
    /// o state atual do bridge. No-op se não há Activity ativa.
    private static func updateActiveLiveActivity() async {
        // Acesso a Activity<T>.activities exige @MainActor
        let activities = await MainActor.run {
            Activity<ChargeActivityAttributes>.activities.filter { $0.activityState == .active }
        }
        guard let activity = activities.first else { return }
        guard let url = URL(string: Settings.bridgeURL + "/api/state") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let charging = (json["charging_state"] as? String) == "Carregando"
            let soc = (json["soc_pct"]              as? Double) ?? 0
            let pwr = (json["charge_power_kw"]      as? Double) ?? 0
            let kwh = (json["charge_session_kwh"]   as? Double) ?? 0
            let rem = (json["charge_remaining_min"] as? Double) ?? 0
            let state = ChargeActivityAttributes.ContentState(
                soc: soc, powerKw: pwr, sessionKwh: kwh,
                remainingMin: Int(rem.rounded()),
                charging: charging,
                updatedAtMs: Date().timeIntervalSince1970 * 1000
            )
            let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(60 * 60))
            await activity.update(content)
        } catch { /* silencioso */ }
    }

}
