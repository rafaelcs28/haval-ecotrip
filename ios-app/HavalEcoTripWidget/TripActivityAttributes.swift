//
//  TripActivityAttributes.swift
//  Live Activity de "viagem ao vivo". Criada/atualizada pelo bridge via APNs
//  conforme o APK publica o snapshot da viagem atual (current_trip).
//
//  ⚠ Target Membership: app + widget (via project.yml). Nome do struct e campos
//    do ContentState precisam casar com o que o bridge envia.
//
import ActivityKit
import Foundation

struct TripActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var distKm:      Double   // km rodados na viagem
        var netKwh:      Double   // energia líquida consumida (kWh, valor positivo)
        var effKwh100:   Double   // eficiência kWh/100km (0 = sem dado)
        var timeSec:     Int      // duração em segundos
        var avgSpeedKmh: Double   // velocidade média
        var fuelL:       Double   // combustível usado (L); 0 = viagem 100% elétrica
        var active:      Bool     // false quando a viagem encerra
        var updatedAtMs: Double
        // Enriquecimento ao vivo (opcionais p/ compat com payloads antigos):
        var socPct:     Double?   // SOC % atual
        var rangeKm:    Double?   // autonomia EV restante (km)
        var tyreMinPsi: Double?   // menor pressão dos 4 pneus (PSI)
        var tyreAlert:  Bool?     // pneu baixo (<30) ou assimétrico (≥5 PSI)
        var costBrl:    Double?   // custo R$ acumulado (energia + combustível)
        // Navegação (frame 2a — opcionais, bridge envia quando há destino):
        var speedKmh:   Double?   // velocidade atual
        var destName:   String?   // destino do nav do carro
        var destEtaMin: Double?   // minutos até chegar
        var destKm:     Double?   // km restantes até o destino

        var isEV: Bool { fuelL <= 0.05 }
        var updatedAt: Date { Date(timeIntervalSince1970: updatedAtMs / 1000.0) }
    }

    var carName: String
}
