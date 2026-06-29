//
//  ChargeActivityAttributes.swift
//  Define os dados que viajam dentro da Live Activity.
//  ⚠ IMPORTANTE no Xcode: marque este arquivo com Target Membership tanto do
//  app principal QUANTO da Widget Extension (checkboxes no painel de arquivo).
//
//  - `attributes` = imutáveis (carName).
//  - `ContentState` = dinâmicos, atualizam a cada push.
//
import ActivityKit
import Foundation

struct ChargeActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var soc:          Double   // 0..100 — SOC %
        var powerKw:      Double   // potência instantânea
        var sessionKwh:   Double   // energia já transferida na sessão
        var remainingMin: Int      // minutos restantes (0 = sem estimativa)
        var charging:     Bool     // false quando termina (estado final)
        var targetPct:    Double   // meta de SOC (limite de carga) — 100 se desconhecido
        var locked:       Bool?    // estado real da trava: true=trancado · nil/false=destrancado
        var updatedAtMs:  Double   // ms epoch — bridge envia como número
        var updatedAt: Date {       // computed pra usar nas views
            Date(timeIntervalSince1970: updatedAtMs / 1000.0)
        }
    }

    var carName: String
}
