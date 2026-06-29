//  CarIntents.swift
//  App Intents (Siri / Atalhos / botões interativos no widget / Central de Controle).
//  Compartilhado entre o app e a Widget Extension. Fala direto com o bridge usando
//  o App Group (Settings.bridgeURL/token), então funciona dos dois processos.

import AppIntents
import WidgetKit
import Foundation
#if canImport(UIKit)
import UIKit
#endif

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

    /// Cria um link de acompanhamento ao vivo (POST /api/auto-share) e devolve a
    /// mensagem pronta + URL. ttlMin = validade do link em minutos.
    static func shareLive(ttlMin: Int) async -> (message: String, url: String)? {
        guard !base.isEmpty, let url = URL(string: "\(base)/api/auto-share") else { return nil }
        var r = URLRequest(url: url); r.httpMethod = "POST"; r.timeoutInterval = 12
        r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        r.addValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["ttlMin": ttlMin]
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (d, resp) = try? await URLSession.shared.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              (j["send"] as? Bool) == true else { return nil }
        let msg = (j["message"] as? String) ?? ""
        let link = (j["url"] as? String) ?? ""
        return (msg, link)
    }

    /// Avança o limite de carga um preset (botão % da LA). O bridge faz o cycle e
    /// serializa taps em rajada (50→60→70→80), devolvendo o alvo escolhido. Não
    /// faz read-modify-write no iOS — senão taps rápidos leriam o state defasado.
    static func cycleChargeLimit() async -> Int? {
        guard !base.isEmpty, let url = URL(string: "\(base)/api/charge-limit/cycle") else { return nil }
        var r = URLRequest(url: url); r.httpMethod = "POST"; r.timeoutInterval = 12
        r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        r.addValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = "{}".data(using: .utf8)
        guard let (d, resp) = try? await URLSession.shared.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return Int(((j["target"] as? Double) ?? 0).rounded())
    }

    /// Cancela a pré-climatização em andamento ou agendada (POST /api/preclimat/cancel).
    @discardableResult static func cancelPreclimat() async -> Bool {
        guard !base.isEmpty, let url = URL(string: "\(base)/api/preclimat/cancel") else { return false }
        var r = URLRequest(url: url); r.httpMethod = "POST"; r.timeoutInterval = 12
        r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        r.addValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = "{}".data(using: .utf8)
        guard let (d, resp) = try? await URLSession.shared.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return false }
        return (j["ok"] as? Bool) == true
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
struct CancelPreclimatIntent: AppIntent {
    static var title: LocalizedStringResource = "Cancelar pré-climatização"
    static var description = IntentDescription("Cancela a pré-climatização agendada ou em andamento (restaura o AC e desliga o motor).")
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let ok = await CarIntentAPI.cancelPreclimat()
        WidgetCenter.shared.reloadAllTimelines()
        return .result(dialog: ok ? "Pré-climatização cancelada." : "Não consegui cancelar agora.")
    }
}

@available(iOS 16.0, *)
struct CycleChargeLimitIntent: AppIntent {
    static var title: LocalizedStringResource = "Mudar limite de carga"
    static var description = IntentDescription("Avança o limite de carga pro próximo preset (…→70→80→90→100→70…).")
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let next = await CarIntentAPI.cycleChargeLimit()
        WidgetCenter.shared.reloadAllTimelines()
        if let n = next { return .result(dialog: "Limite de carga: \(n)%.") }
        return .result(dialog: "Não consegui mudar o limite agora.")
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
struct ShareLiveIntent: AppIntent {
    static var title: LocalizedStringResource = "Compartilhar ao vivo"
    static var description = IntentDescription("Cria um link de acompanhamento ao vivo do trajeto e copia a mensagem pronta.")

    @Parameter(title: "Minutos", description: "Por quanto tempo o link fica válido.", default: 120)
    var minutes: Int

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let ttl = max(5, min(1440, minutes))
        guard let s = await CarIntentAPI.shareLive(ttlMin: ttl) else {
            return .result(value: "", dialog: "Não consegui criar o link agora.")
        }
        #if canImport(UIKit)
        await MainActor.run { UIPasteboard.general.string = s.message }
        #endif
        return .result(value: s.message, dialog: "Link criado e copiado. \(s.message)")
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
        AppShortcut(intent: ShareLiveIntent(), phrases: [
            "Compartilhar ao vivo no \(.applicationName)",
            "Compartilhar meu trajeto no \(.applicationName)",
        ], shortTitle: "Compartilhar ao vivo", systemImageName: "location.fill.viewfinder")
    }
}
