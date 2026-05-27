//
//  SecurityActivityAttributes.swift
//  Live Activity persistente de "veículo desprotegido". Criada/atualizada pelo
//  bridge via APNs enquanto o carro estacionado estiver destrancado e/ou com
//  algo aberto; encerra quando tudo for trancado/fechado.
//
//  ⚠ Target Membership: app + widget (via project.yml). Nome do struct e campos
//    do ContentState precisam casar com o que o bridge envia.
//
import ActivityKit
import Foundation

struct SecurityActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var unlocked: Bool                          // carro destrancado
        var doorFL, doorFR, doorRL, doorRR: Bool    // portas (vista de cima)
        var winFL, winFR, winRL, winRR: Bool        // vidros
        var trunk:    Bool                          // porta-malas
        var sunroof:  Bool                          // teto solar
        var summary:  String                        // resumo textual (fallback)
        var active:   Bool                          // false quando tudo for resolvido
        var updatedAtMs: Double

        // Derivados de conveniência pro layout.
        var anyDoor:   Bool { doorFL || doorFR || doorRL || doorRR || trunk }
        var anyWindow: Bool { winFL || winFR || winRL || winRR }
        var openCount: Int {
            [unlocked, doorFL, doorFR, doorRL, doorRR, winFL, winFR, winRL, winRR, trunk, sunroof]
                .filter { $0 }.count
        }
    }

    var carName: String
}
