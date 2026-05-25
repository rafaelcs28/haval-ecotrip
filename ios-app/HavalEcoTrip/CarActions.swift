//
//  CarActions.swift
//  Disparo de ações remotas (lock/unlock, engine on/off, etc.) via o endpoint
//  POST /api/action/<name> do bridge. Cada ação:
//    1. Mostra notif "⏳ Enviando..." imediato pro user saber que recebeu
//    2. Chama o backend
//    3. Substitui pela notif "✓ ..." ou "✗ ..." com sound default
//
//  Usado pelas Quick Actions (Home Screen Shortcuts) — user segura ícone,
//  escolhe atalho, app abre via URL scheme havalecotrip://action/<name>,
//  ContentView chama CarActions.run.
//
import Foundation
import UserNotifications

enum CarActions {

    private static let labels: [String: (sending: String, success: String, fail: String)] = [
        "lock_close":  ("🔒 Trancando carro…",      "✓ Carro trancado",      "✗ Falha ao trancar"),
        "lock_open":   ("🔓 Destrancando carro…",   "✓ Carro destrancado",   "✗ Falha ao destrancar"),
        "engine_on":   ("🔥 Ligando motor…",        "✓ Motor ligado",        "✗ Falha ao ligar motor"),
        "engine_off":  ("💤 Desligando motor…",     "✓ Motor desligado",     "✗ Falha ao desligar motor"),
        "windows_open":  ("🪟 Abrindo vidros…",     "✓ Vidros abertos",      "✗ Falha ao abrir vidros"),
        "windows_close": ("🪟 Fechando vidros…",    "✓ Vidros fechados",     "✗ Falha ao fechar vidros"),
        "trunk_open":  ("📦 Abrindo porta-malas…",  "✓ Porta-malas aberto",  "✗ Falha"),
        "trunk_close": ("📦 Fechando porta-malas…", "✓ Porta-malas fechado", "✗ Falha"),
    ]

    @MainActor
    static func run(_ action: String) async {
        let lbl = labels[action] ?? ("⏳ \(action)…", "✓ \(action) ok", "✗ \(action) falhou")
        // 1. Notif imediata (silenciosa, marca o início)
        await fireNotif(title: lbl.sending, body: "Aguardando resposta do carro…", tag: "action-\(action)", silent: true)

        guard Settings.isConfigured else {
            await fireNotif(title: "✗ App não configurado", body: "Abra o app e cole URL e token.", tag: "action-\(action)", silent: false)
            return
        }
        guard let url = URL(string: Settings.bridgeURL + "/api/action/" + action) else {
            await fireNotif(title: lbl.fail, body: "URL inválida", tag: "action-\(action)", silent: false)
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 {
                await fireNotif(title: lbl.success, body: "Comando aceito pelo carro.", tag: "action-\(action)", silent: false)
            } else {
                let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                await fireNotif(title: lbl.fail, body: body ?? "HTTP \(status)", tag: "action-\(action)", silent: false)
            }
        } catch {
            await fireNotif(title: lbl.fail, body: error.localizedDescription, tag: "action-\(action)", silent: false)
        }
    }

    private static func fireNotif(title: String, body: String, tag: String, silent: Bool) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = silent ? nil : .default
        if silent { content.interruptionLevel = .passive }
        let req = UNNotificationRequest(
            identifier: tag,           // mesmo tag → substitui notif anterior
            content: content,
            trigger: nil               // imediato
        )
        try? await UNUserNotificationCenter.current().add(req)
    }
}
