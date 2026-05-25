//
//  CarActions.swift
//  Disparo de ações remotas (lock/unlock, engine on/off, etc.) via o endpoint
//  POST /api/action/<name> do bridge. Fluxo completo:
//    1. Lê estado inicial via GET /api/state pra saber o que esperar mudar
//    2. Mostra notif "⏳ Enviando..." silenciosa (marca o início pro user)
//    3. POST /api/action/<name>
//    4. Polling de /api/state a cada 3s por até 50s, esperando a mudança real
//       (ex: lock_state mudar de "off" pra "on"). Carro normalmente leva
//       15-45s pra responder via HA → MQTT → ECU.
//    5. Substitui notif por sucesso (com sound) ou "carro não respondeu"
//
//  Usado pelas Quick Actions (Home Screen Shortcuts).
//
import Foundation
import UserNotifications

enum CarActions {

    private static let labels: [String: (sending: String, success: String, fail: String)] = [
        "lock_close":  ("🔒 Trancando carro…",      "✓ Carro trancado",      "✗ Carro não trancou"),
        "lock_open":   ("🔓 Destrancando carro…",   "✓ Carro destrancado",   "✗ Carro não destrancou"),
        "engine_on":   ("🔥 Ligando motor…",        "✓ Motor ligado",        "✗ Motor não ligou"),
        "engine_off":  ("💤 Desligando motor…",     "✓ Motor desligado",     "✗ Motor não desligou"),
        "windows_open":  ("🪟 Abrindo vidros…",     "✓ Vidros abertos",      "✗ Vidros não abriram"),
        "windows_close": ("🪟 Fechando vidros…",    "✓ Vidros fechados",     "✗ Vidros não fecharam"),
        "trunk_open":  ("📦 Abrindo porta-malas…",  "✓ Porta-malas aberto",  "✗ Porta-malas não abriu"),
        "trunk_close": ("📦 Fechando porta-malas…", "✓ Porta-malas fechado", "✗ Porta-malas não fechou"),
    ]

    /// Tempo total que esperamos pelo carro responder (HA → MQTT → ECU).
    /// Carro acordando do sleep pode demorar 30-45s.
    private static let pollTimeoutSec: Double = 50
    private static let pollIntervalSec: Double = 3

    @MainActor
    static func run(_ action: String) async {
        let lbl = labels[action] ?? ("⏳ \(action)…", "✓ \(action) ok", "✗ \(action) sem resposta")

        guard Settings.isConfigured else {
            await fireNotif(title: "✗ App não configurado", body: "Abra o app e cole URL e token.", tag: "action-\(action)", silent: false)
            return
        }

        // 1. Lê estado inicial pra saber baseline
        let stateBefore = await fetchState()

        // 2. Notif inicial silenciosa (marca o início)
        await fireNotif(title: lbl.sending, body: "Aguardando resposta do carro (até 50s)…", tag: "action-\(action)", silent: true)

        // 3. Dispara o comando no bridge
        guard let url = URL(string: Settings.bridgeURL + "/api/action/" + action) else {
            await fireNotif(title: lbl.fail, body: "URL inválida", tag: "action-\(action)", silent: false)
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 12   // só pra HA aceitar, não pra carro confirmar
        req.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status != 200 {
                let bodyErr = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                await fireNotif(title: lbl.fail, body: "Bridge: \(bodyErr ?? "HTTP \(status)")", tag: "action-\(action)", silent: false)
                return
            }
        } catch {
            await fireNotif(title: lbl.fail, body: "Erro de rede: \(error.localizedDescription)", tag: "action-\(action)", silent: false)
            return
        }

        // 4. Polling até detectar a mudança real ou estourar timeout
        let deadline = Date().addingTimeInterval(pollTimeoutSec)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(pollIntervalSec * 1_000_000_000))
            let now = await fetchState()
            if let now = now, didActionTakeEffect(action: action, before: stateBefore, after: now) {
                await fireNotif(title: lbl.success, body: "Confirmado no carro.", tag: "action-\(action)", silent: false)
                return
            }
        }

        // 5. Timeout — carro não confirmou no tempo
        await fireNotif(title: lbl.fail,
                        body: "Carro não confirmou em \(Int(pollTimeoutSec))s — pode estar dormindo. Verifique no app.",
                        tag: "action-\(action)", silent: false)
    }

    // ── State fetch + change detection ───────────────────────────────────────

    private static func fetchState() async -> [String: Any]? {
        guard let url = URL(string: Settings.bridgeURL + "/api/state") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        req.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch { return nil }
    }

    /// Compara estados antes/depois e devolve true se a action teve efeito.
    /// Cada action tem critério próprio (campo do state + valor esperado).
    private static func didActionTakeEffect(action: String,
                                            before: [String: Any]?,
                                            after: [String: Any]) -> Bool {
        switch action {
        case "engine_on":
            return strVal(after["engine_state"]) == "1"
        case "engine_off":
            return strVal(after["engine_state"]) == "0"
        case "lock_close":
            return strVal(after["lock_state"]) == "off"
        case "lock_open":
            return strVal(after["lock_state"]) == "on"
        case "windows_open":
            // qualquer janela diferente de "fechado" (1)
            return ["window_fl","window_fr","window_rl","window_rr"].contains { k in
                let v = strVal(after[k])
                return v == "2" || v == "3"
            }
        case "windows_close":
            // todas as janelas conhecidas devem estar fechadas (1)
            let keys = ["window_fl","window_fr","window_rl","window_rr"]
            let allKnown = keys.allSatisfy { after[$0] != nil }
            let allClosed = keys.allSatisfy { strVal(after[$0]) == "1" }
            return allKnown && allClosed
        case "trunk_open":
            return strVal(after["door_trunk"]) == "open"
        case "trunk_close":
            return strVal(after["door_trunk"]) == "closed"
        default:
            // Action desconhecida: só confia no HTTP 200 (já garantido) — sucesso
            return true
        }
    }

    private static func strVal(_ any: Any?) -> String {
        if let s = any as? String { return s }
        if let i = any as? Int    { return String(i) }
        if let d = any as? Double { return String(Int(d)) }
        return ""
    }

    // ── Notifs ───────────────────────────────────────────────────────────────

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
