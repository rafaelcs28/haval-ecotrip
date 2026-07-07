//
//  ParkingActivityAttributes.swift
//  Live Activity "voltar ao carro": distância + direção até o Haval estacionado,
//  criada/atualizada pelo bridge via APNs quando o dono se afasta >100m do carro.
//
//  ⚠ Target Membership: app + widget (via project.yml). Nome do struct e campos
//    do ContentState precisam casar com o que o bridge envia (_parkingContentState).
//
import ActivityKit
import Foundation

struct ParkingActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var distM:      Int      // distância do celular até o carro (metros)
        var bearingDeg: Int      // rumo do celular → carro (0=N, 90=L) — gira a seta
        var carLat:     Double   // posição do carro estacionado
        var carLng:     Double
        var parkedAtMs: Double   // quando estacionou (epoch ms) — "estacionado há X"
        var updatedAtMs: Double
        var note: String = ""    // nota do local salva pelo dono ("vaga 214")

        var parkedAt:  Date { Date(timeIntervalSince1970: parkedAtMs / 1000) }
        var updatedAt: Date { Date(timeIntervalSince1970: updatedAtMs / 1000) }

        // "120 m" / "1.4 km"
        var distLabel: String {
            distM >= 1000 ? String(format: "%.1f km", Double(distM) / 1000) : "\(distM) m"
        }
        // URL de rota a pé no Apple Maps até o carro (abre ao tocar na LA).
        var mapsURL: URL {
            URL(string: "http://maps.apple.com/?daddr=\(carLat),\(carLng)&dirflg=w")!
        }
    }

    var carName: String
}
