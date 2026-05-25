//
//  NotificationPoller.swift
//  Polling do /api/push/history pra detectar notificações novas no bridge e
//  re-disparar como Local Notifications nativas no iPhone.
//
//  Por que não Web Push? WKWebView no iOS NÃO suporta Web Push API — só
//  Safari real e PWA standalone (Add to Home Screen). Solução é o app
//  nativo escutar o bridge e gerar notif local.
//
//  Limitações: em foreground, polling roda a cada 30s. Em background, iOS
//  decide quando deixar o BGTask rodar (geralmente espaçado, 15-30 min).
//  Pra notif crítica (recarga começou agora), o melhor é o app estar em
//  uso ou foreground recente.
//
import Foundation
import UserNotifications

@MainActor
final class NotificationPoller: ObservableObject {

    @Published var lastError: String?
    private var pollingTask: Task<Void, Never>?
    private let pollInterval: TimeInterval = 30
    private let lastSeenKey = "notif_last_seen_ts"

    private var lastSeenTs: Double {
        get { UserDefaults.standard.double(forKey: lastSeenKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastSeenKey) }
    }

    func requestPermission() async {
        let center = UNUserNotificationCenter.current()
        do {
            try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            lastError = "Permissão negada: \(error.localizedDescription)"
        }
    }

    func start() {
        stop()
        // Primeira execução imediata + loop
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(nanoseconds: UInt64(30 * 1_000_000_000))
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func pollOnce() async {
        guard Settings.isConfigured else { return }
        guard let url = URL(string: Settings.bridgeURL + "/api/push/history") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
            // arr vem ordenado por ts DESC. Pega só os mais novos que lastSeenTs.
            let currentLastSeen = lastSeenTs
            var newMaxTs = currentLastSeen
            var toFire: [(ts: Double, title: String, body: String, type: String)] = []
            for entry in arr {
                let ts = (entry["ts"] as? Double) ?? 0
                if ts <= currentLastSeen { break }   // resto é mais antigo
                let title = (entry["title"] as? String) ?? "EcoTrip"
                let body  = (entry["body"]  as? String) ?? ""
                let type  = (entry["type"]  as? String) ?? "generic"
                toFire.append((ts, title, body, type))
                if ts > newMaxTs { newMaxTs = ts }
            }
            // Dispara na ordem cronológica (mais antigo primeiro)
            for n in toFire.reversed() {
                await fireLocalNotification(title: n.title, body: n.body, type: n.type, ts: n.ts)
            }
            if newMaxTs > currentLastSeen { lastSeenTs = newMaxTs }
        } catch {
            // silencioso — offline etc.
        }
    }

    private func fireLocalNotification(title: String, body: String, type: String, ts: Double) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body  = body
        content.sound = .default
        // Usa tag por type pra notifs do mesmo tipo se substituírem (charge-live etc).
        // Categoria identifier pode ser usado pra agrupar.
        if type == "charge_live" { content.interruptionLevel = .passive }
        let req = UNNotificationRequest(
            identifier: "\(type)-\(Int(ts))",
            content: content,
            trigger: nil   // imediato
        )
        do {
            try await UNUserNotificationCenter.current().add(req)
        } catch {
            lastError = "Falha notif: \(error.localizedDescription)"
        }
    }
}
