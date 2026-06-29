//
//  CompanionInboundActivityAttributes.swift
//  Live Activity da feature "companion indo até a Grasi" — aparece SÓ no
//  iPhone da Grasi quando outro device (Rafael, etc.) está se aproximando
//  dela. Disparada/atualizada/encerrada pelo bridge via APNs com base na
//  diferença de localização e na rota de carro (OSRM).
//
//  ⚠ Target membership: app BydRecarga + BydRecargaWidget (via project.yml).
//    Campos do ContentState precisam casar com o cs montado em
//    _evalCompanionInbound() no bridge.
//
import ActivityKit
import Foundation

struct CompanionInboundActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var name:        String   // nome de exibição do companion (ex.: "Rafael")
        var etaMin:      Int      // minutos de carro até a Grasi (OSRM)
        var distKm:      Double   // distância de carro
        var active:      Bool     // false quando o companion chegou perto / desistiu
        var updatedAtMs: Double
        var updatedAt: Date { Date(timeIntervalSince1970: updatedAtMs / 1000.0) }
    }

    var name: String   // mesmo nome do ContentState, preservado pra atributos imutáveis
}
