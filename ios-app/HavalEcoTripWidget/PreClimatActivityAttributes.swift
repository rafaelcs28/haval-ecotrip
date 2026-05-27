//
//  PreClimatActivityAttributes.swift
//  Live Activity da pré-climatização agendada. Com a conta Apple paga, é o
//  BRIDGE que cria a LA via APNs push-to-start (~5 min antes) e atualiza cada
//  passo (ligar motor → AC → restaurar → encerrar), mesmo com o app fechado.
//
//  ⚠ Target Membership: este arquivo está nos DOIS targets (app + widget) via
//    project.yml — o app referencia o tipo (LiveActivityPush registra os tokens)
//    e o widget renderiza a LA. O nome do struct e os campos do ContentState
//    precisam casar com o attributes-type/content-state enviados pelo bridge.
//
import ActivityKit
import Foundation

struct PreClimatActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var phase:       String   // scheduled|starting|engine_on|cooling|restoring|ended|failed
        var detail:      String   // linha de texto pronta do bridge (ex: "Climatizando…")
        var temp:        Double    // °C alvo do AC
        var fan:         Int       // 1..7
        var tempIn:      Double    // °C interna do carro (0 = sem leitura)
        var tempOut:     Double    // °C externa (0 = sem leitura)
        var endsAtMs:    Double    // epoch ms do fim previsto (0 = sem contagem)
        var updatedAtMs: Double    // epoch ms

        var endsAt: Date? { endsAtMs > 0 ? Date(timeIntervalSince1970: endsAtMs / 1000.0) : nil }
        var updatedAt: Date { Date(timeIntervalSince1970: updatedAtMs / 1000.0) }
        var isFinal: Bool { phase == "ended" || phase == "failed" }
    }

    var scheduledTime: String   // "HH:MM" — imutável durante a sessão
    var carName: String
}
