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
            await runPoll()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }

    /// Versão standalone do polling (sem UI/Combine), reusa lógica do NotificationPoller.
    private static func runPoll() async {
        guard !Settings.bridgeURL.isEmpty, !Settings.bridgeToken.isEmpty else { return }
        guard let url = URL(string: Settings.bridgeURL + "/api/push/history") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
            let lastSeenKey = "notif_last_seen_ts"
            let lastSeen = UserDefaults.standard.double(forKey: lastSeenKey)
            var newMax = lastSeen
            var toFire: [(ts: Double, title: String, body: String, type: String)] = []
            for entry in arr {
                let ts = (entry["ts"] as? Double) ?? 0
                if ts <= lastSeen { break }
                toFire.append((
                    ts,
                    (entry["title"] as? String) ?? "EcoTrip",
                    (entry["body"]  as? String) ?? "",
                    (entry["type"]  as? String) ?? "generic"
                ))
                if ts > newMax { newMax = ts }
            }
            for n in toFire.reversed() {
                let content = UNMutableNotificationContent()
                content.title = n.title
                content.body  = n.body
                content.sound = .default
                if n.type == "charge_live" { content.interruptionLevel = .passive }
                let r = UNNotificationRequest(identifier: "\(n.type)-\(Int(n.ts))", content: content, trigger: nil)
                try? await UNUserNotificationCenter.current().add(r)
            }
            if newMax > lastSeen { UserDefaults.standard.set(newMax, forKey: lastSeenKey) }
        } catch { /* silencioso */ }
    }
}
