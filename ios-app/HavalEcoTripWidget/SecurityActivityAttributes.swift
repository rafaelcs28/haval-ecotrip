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
        // Rodada 9b (opcionais p/ compat com payloads antigos):
        var sinceMs:       Double?   // quando o problema começou (timestamp ms)
        var userDistKm:    Double?   // distância do usuário até o carro (km)
        var locationShort: String?   // "Estac. Flamboyant G2" (onde o carro está)
        var confirmSec:    Double?   // latência da confirmação do travar (s)

        var updatedAt: Date { Date(timeIntervalSince1970: updatedAtMs / 1000.0) }
        var since: Date? { sinceMs.map { Date(timeIntervalSince1970: $0 / 1000.0) } }

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
