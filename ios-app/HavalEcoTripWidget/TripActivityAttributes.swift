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

        var isEV: Bool { fuelL <= 0.05 }
    }

    var carName: String
}
