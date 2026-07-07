//
//  InfraActivityAttributes.swift
//  Live Activity persistente de "infra/monitoramento com problema". Criada/
//  atualizada pelo bridge via APNs quando o HA da empresa reporta (via
//  /api/ha-status) um serviço caído ou um guard disparado; encerra quando
//  tudo volta ao normal.
//
//  ⚠ Target Membership: app + widget (via project.yml). Nome do struct e campos
//    do ContentState precisam casar com o que o bridge envia.
//
import ActivityKit
import Foundation

struct InfraActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var downCount:   Int      // serviços fora do ar agora
        var totalCount:  Int      // total de serviços monitorados
        var issuesText:  String   // nomes juntos (guards primeiro), ex: "Bridge cego (LAN) · Mosquitto"
        var active:      Bool     // false quando tudo volta ao normal
        var updatedAtMs: Double
    }

    var title: String
}
