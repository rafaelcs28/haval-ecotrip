//
//  PreClimatActivityAttributes.swift
//  Live Activity da pré-climatização agendada. Como a conta Apple é gratuita
//  (sem APNs), NÃO há push-to-start — a LA é iniciada e atualizada LOCALMENTE
//  pelo PreClimatManager, que faz polling de /api/preclimat e reflete a fase
//  reportada pelo bridge (ligar motor → AC → restaurar → encerrar).
//  Funciona com o app vivo (foreground; background best-effort via keep-alive).
//
//  ⚠ Target Membership: este arquivo está nos DOIS targets (app + widget) via
//    project.yml — o PreClimatManager (app) usa o tipo e o widget renderiza a LA.
//
import ActivityKit
import Foundation

struct PreClimatActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var phase:       String   // scheduled|starting|engine_on|cooling|restoring|ended|failed
        var detail:      String   // linha de texto pronta do bridge (ex: "Climatizando…")
        var temp:        Double    // °C alvo do AC
        var fan:         Int       // 1..7
        var endsAtMs:    Double    // epoch ms do fim previsto (0 = sem contagem)
        var updatedAtMs: Double    // epoch ms

        var endsAt: Date? { endsAtMs > 0 ? Date(timeIntervalSince1970: endsAtMs / 1000.0) : nil }
        var isFinal: Bool { phase == "ended" || phase == "failed" }
    }

    var scheduledTime: String   // "HH:MM" — imutável durante a sessão
    var carName: String
}
