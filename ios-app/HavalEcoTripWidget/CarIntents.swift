//  CarIntents.swift
//  App Intents (Siri / Atalhos / botões interativos no widget / Central de Controle).
//  Compartilhado entre o app e a Widget Extension. Fala direto com o bridge usando
//  o App Group (Settings.bridgeURL/token), então funciona dos dois processos.

import AppIntents
import WidgetKit
import Foundation

enum CarIntentAPI {
    private static var base: String {
        let u = Settings.bridgeURL
        return u.hasSuffix("/") ? String(u.dropLast()) : u
    }

    /// Dispara uma ação remota (lock_close, lock_open, engine_on, engine_off…).
    @discardableResult static func action(_ name: String) async -> Bool {
        guard !base.isEmpty, let url = URL(string: "\(base)/api/action/\(name)") else { return false }
        var r = URLRequest(url: url); r.httpMethod = "POST"; r.timeoutInterval = 12
        r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        r.addValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = "{}".data(using: .utf8)
        if let (_, resp) = try? await URLSession.shared.data(for: r) {
            return (resp as? HTTPURLResponse)?.statusCode == 200
        }
        return false
    }

    /// Lê o SOC atual (e autonomia EV) do estado do carro.
    static func socNow() async -> (soc: Int, evKm: Int)? {
        guard !base.isEmpty, let url = URL(string: "\(base)/api/state") else { return nil }
        var r = URLRequest(url: url); r.timeoutInterval = 8
        r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        guard let (d, resp) = try? await URLSession.shared.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        let soc = Int(((j["soc_pct"] as? Double) ?? 0).rounded())
        let ev = Int(((j["autonomy_ev_km"] as? Double) ?? 0).rounded())
        return (soc, ev)
    }
}

@available(iOS 16.0, *)
struct LockCarIntent: AppIntent {
    static var title: LocalizedStringResource = "Trancar o carro"
    static var description = IntentDescription("Tranca o Haval remotamente.")
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let ok = await CarIntentAPI.action("lock_close")
        WidgetCenter.shared.reloadAllTimelines()
        return .result(dialog: ok ? "Carro trancado." : "Não consegui trancar agora.")
    }
}

@available(iOS 16.0, *)
struct UnlockCarIntent: AppIntent {
    static var title: LocalizedStringResource = "Destrancar o carro"
    static var description = IntentDescription("Destranca o Haval remotamente.")
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let ok = await CarIntentAPI.action("lock_open")
        WidgetCenter.shared.reloadAllTimelines()
        return .result(dialog: ok ? "Carro destrancado." : "Não consegui destrancar agora.")
    }
}

@available(iOS 16.0, *)
struct EngineOnIntent: AppIntent {
    static var title: LocalizedStringResource = "Ligar o motor"
    static var description = IntentDescription("Liga o motor do Haval remotamente (climatiza a cabine).")
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let ok = await CarIntentAPI.action("engine_on")
        return .result(dialog: ok ? "Motor ligado." : "Não consegui ligar o motor.")
    }
}

@available(iOS 16.0, *)
struct EngineOffIntent: AppIntent {
    static var title: LocalizedStringResource = "Desligar o motor"
    static var description = IntentDescription("Desliga o motor do Haval remotamente.")
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let ok = await CarIntentAPI.action("engine_off")
        return .result(dialog: ok ? "Motor desligado." : "Não consegui desligar o motor.")
    }
}

@available(iOS 16.0, *)
struct PreclimaIntent: AppIntent {
    static var title: LocalizedStringResource = "Pré-climatizar"
    static var description = IntentDescription("Liga o ar-condicionado do Haval pra climatizar a cabine.")
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let ok = await CarIntentAPI.action("ac_on")
        WidgetCenter.shared.reloadAllTimelines()
        return .result(dialog: ok ? "Pré-climatização ligada." : "Não consegui ligar o ar agora.")
    }
}

@available(iOS 16.0, *)
struct SocQueryIntent: AppIntent {
    static var title: LocalizedStringResource = "Bateria do carro"
    static var description = IntentDescription("Diz quanto de bateria e autonomia EV o Haval tem agora.")
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let s = await CarIntentAPI.socNow() else {
            return .result(dialog: "Não consegui falar com o carro agora.")
        }
        return .result(dialog: "O Haval está com \(s.soc)% de bateria, \(s.evKm) km de autonomia elétrica.")
    }
}

@available(iOS 16.0, *)
struct EcotripShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: LockCarIntent(), phrases: [
            "Trancar o carro no \(.applicationName)",
            "Trancar o \(.applicationName)",
        ], shortTitle: "Trancar", systemImageName: "lock.fill")
        AppShortcut(intent: UnlockCarIntent(), phrases: [
            "Destrancar o carro no \(.applicationName)",
            "Destrancar o \(.applicationName)",
        ], shortTitle: "Destrancar", systemImageName: "lock.open.fill")
        AppShortcut(intent: EngineOnIntent(), phrases: [
            "Ligar o motor no \(.applicationName)",
            "Ligar o carro no \(.applicationName)",
        ], shortTitle: "Ligar motor", systemImageName: "power")
        AppShortcut(intent: SocQueryIntent(), phrases: [
            "Quanto de bateria no \(.applicationName)",
            "Bateria do carro no \(.applicationName)",
        ], shortTitle: "Bateria", systemImageName: "bolt.fill")
    }
}
