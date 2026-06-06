//
//  SongProTripActivityAttributes.swift
//  Live Activity de deslocamento do BYD Song Pro (BYD da Grasi) — mostra o
//  trajeto ao vivo (tempo · km · SOC) na tela bloqueada. Cor azul clarinho,
//  igual à LA de recarga. Criada/atualizada/encerrada pelo bridge via APNs
//  conforme a telemetria de movimento do BYD.
//
//  ⚠ Target membership: app BydRecarga + BydRecargaWidget (via project.yml).
//    Campos do ContentState precisam casar com _songProTripContentState() no bridge.
//
import ActivityKit
import Foundation

struct SongProTripActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var distKm:      Double   // km percorridos no deslocamento
        var timeSec:     Int      // duração em segundos
        var socPct:      Double   // SOC % atual
        var avgSpeedKmh: Double   // velocidade média (km/h)
        var active:      Bool     // false quando o deslocamento encerra
        var updatedAtMs: Double
        // Distância e tempo de CARRO (menor caminho) do carro até o celular do monitor.
        // Calculados no bridge (OSRM). nil/0 quando indisponível (sem localização recente).
        var distToPhoneKm: Double?
        var etaToPhoneMin: Int?
        var updatedAt: Date { Date(timeIntervalSince1970: updatedAtMs / 1000.0) }
    }

    var carName: String   // "BYD Song Pro"
}
