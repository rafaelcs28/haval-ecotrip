//
//  PreClimatManager.swift
//  Sem APNs (conta Apple gratuita), a Live Activity da pré-climatização é
//  iniciada e atualizada LOCALMENTE pelo app. Este manager faz polling de
//  /api/preclimat, calcula a janela (T-5min … T+duração+5min) e mantém a
//  Live Activity em sincronia com a fase reportada pelo bridge.
//
//  Confiável com o app em foreground; em background é best-effort — depende do
//  keep-alive de localização manter o processo vivo no horário.
//
//  Gate: a LA só aparece se a pré-climatização foi agendada POR ESTE app
//  (preclimat.device_id == Settings.notifDeviceId). Agendamento via PWA no
//  Safari tem device_id diferente → só notificação, sem LA.
//
import Foundation
import ActivityKit

@MainActor
final class PreClimatManager {
    static let shared = PreClimatManager()
    private init() {}

    private let carName = "Haval H6 PHEV"
    private let activePhases: Set<String> = ["starting", "engine_on", "cooling", "restoring"]

    private struct Desired {
        let phase: String
        let detail: String
        let temp: Double
        let fan: Int
        let endsAtMs: Double
        let scheduledTime: String
    }

    /// Chamado periodicamente (foreground e, best-effort, pelo keep-alive).
    func tick() async {
        guard Settings.isConfigured else { return }
        guard let data = await fetch() else { return }

        // Gate por dispositivo: só mostra LA se ESTE app agendou.
        let owner = (data["device_id"] as? String) ?? ""
        let mine  = !owner.isEmpty && owner == Settings.notifDeviceId

        let desired = mine ? computeDesired(data) : nil
        await reconcile(desired)
    }

    // ── Fetch ────────────────────────────────────────────────────────────────
    private func fetch() async -> [String: Any]? {
        guard let url = URL(string: Settings.bridgeURL + "/api/preclimat") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 6)
        req.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        guard let (d, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return json
    }

    // ── Decide o que a LA deve mostrar agora (ou nil = encerrar) ───────────────
    private func computeDesired(_ data: [String: Any]) -> Desired? {
        let nowMs = Date().timeIntervalSince1970 * 1000
        let enabled = (data["enabled"] as? Bool) ?? false
        let time    = (data["time"] as? String) ?? ""
        let rec     = (data["recurrence"] as? String) ?? "daily"
        let cfgTemp = numD(data["temp"]) ?? 22
        let cfgFan  = numI(data["fan"]) ?? 3

        let st       = (data["status"] as? [String: Any]) ?? [:]
        let phase    = (st["phase"] as? String) ?? "idle"
        let detail   = (st["detail"] as? String) ?? ""
        let stTemp   = numD(st["temp"]) ?? cfgTemp
        let stFan    = numI(st["fan"]) ?? cfgFan
        let stEnds   = numD(st["endsAtMs"]) ?? 0
        let stUpd    = numD(st["updatedAtMs"]) ?? 0

        // 1) Fase ativa reportada pelo bridge (e recente — evita estado velho).
        let recentMs: Double = 3 * 60 * 60 * 1000   // 3h
        if activePhases.contains(phase), (nowMs - stUpd) < recentMs {
            return Desired(phase: phase, detail: detail, temp: stTemp, fan: stFan,
                           endsAtMs: stEnds, scheduledTime: time)
        }

        // 2) Final (encerrada/falhou) — mantém visível até endsAtMs (≈5 min).
        if (phase == "ended" || phase == "failed"), stEnds > nowMs {
            return Desired(phase: phase, detail: detail, temp: stTemp, fan: stFan,
                           endsAtMs: 0, scheduledTime: time)
        }

        // 3) Janela "agendada": de T-5min até T (+3min de folga p/ o bridge disparar).
        if enabled, eligibleToday(rec), let fireMs = fireMsToday(time) {
            if nowMs >= fireMs - 5 * 60_000, nowMs < fireMs + 3 * 60_000 {
                if nowMs < fireMs {
                    return Desired(phase: "scheduled", detail: "Agendada para \(time)",
                                   temp: cfgTemp, fan: cfgFan, endsAtMs: fireMs, scheduledTime: time)
                } else {
                    return Desired(phase: "scheduled", detail: "Aguardando o carro…",
                                   temp: cfgTemp, fan: cfgFan, endsAtMs: 0, scheduledTime: time)
                }
            }
        }
        return nil
    }

    // ── Reconcilia a Activity com o estado desejado ────────────────────────────
    private func reconcile(_ desired: Desired?) async {
        let existing = Activity<PreClimatActivityAttributes>.activities
            .first { $0.activityState == .active }

        guard let d = desired else {
            if let e = existing {
                let final = PreClimatActivityAttributes.ContentState(
                    phase: "ended", detail: "Encerrada", temp: 0, fan: 0,
                    endsAtMs: 0, updatedAtMs: Date().timeIntervalSince1970 * 1000)
                await e.end(ActivityContent(state: final, staleDate: nil), dismissalPolicy: .immediate)
            }
            return
        }

        let state = PreClimatActivityAttributes.ContentState(
            phase: d.phase, detail: d.detail, temp: d.temp, fan: d.fan,
            endsAtMs: d.endsAtMs, updatedAtMs: Date().timeIntervalSince1970 * 1000)
        let staleMs = d.endsAtMs > 0 ? d.endsAtMs : Date().addingTimeInterval(600).timeIntervalSince1970 * 1000
        let content = ActivityContent(state: state,
                                      staleDate: Date(timeIntervalSince1970: staleMs / 1000))

        if let e = existing {
            await e.update(content)
        } else {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            let attrs = PreClimatActivityAttributes(scheduledTime: d.scheduledTime, carName: carName)
            _ = try? Activity<PreClimatActivityAttributes>.request(attributes: attrs, content: content)
        }
    }

    // ── Helpers ────────────────────────────────────────────────────────────────
    private func fireMsToday(_ hhmm: String) -> Double? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        var comp = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comp.hour = h; comp.minute = m; comp.second = 0
        guard let date = Calendar.current.date(from: comp) else { return nil }
        return date.timeIntervalSince1970 * 1000
    }

    private func eligibleToday(_ rec: String) -> Bool {
        let dow = Calendar.current.component(.weekday, from: Date())   // 1=Dom … 7=Sáb
        switch rec {
        case "weekdays": return dow != 1 && dow != 7
        case "weekends": return dow == 1 || dow == 7
        default:         return true   // once, daily
        }
    }

    private func numD(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) }
        return nil
    }
    private func numI(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) }
        return nil
    }
}
