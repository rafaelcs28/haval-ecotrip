//
//  MotorActivityAttributes.swift
//  Live Activity de "motor ligado remotamente". Criada/atualizada pelo bridge
//  via APNs quando o motor é ligado pelo app (fora da pré-climatização).
//
//  ⚠ Target Membership: app + widget (via project.yml). Nome do struct e campos
//    do ContentState precisam casar com o que o bridge envia.
//
import ActivityKit
import Foundation

struct MotorActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var startedAtMs: Double   // quando o motor ligou (epoch ms) — base do contador "há X min"
        var cabinTemp:   Double   // temperatura interna (°C)
        var outsideTemp: Double   // temperatura externa (°C)
        var acOn:        Bool     // ar/ventilação ligados
        var active:      Bool     // false quando o motor desliga
        var updatedAtMs: Double

        var startedAt: Date { Date(timeIntervalSince1970: startedAtMs / 1000) }
        var updatedAt: Date { Date(timeIntervalSince1970: updatedAtMs / 1000) }
    }

    var carName: String
}
