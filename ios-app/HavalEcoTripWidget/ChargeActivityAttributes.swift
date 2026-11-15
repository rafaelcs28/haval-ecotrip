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

struct ChargePowerComparison: Equatable {
    let chargerPowerKw: Double
    let vehiclePowerKw: Double
    let lossPercent: Double

    init?(chargerPowerKw: Double, vehiclePowerKw: Double) {
        guard chargerPowerKw.isFinite, vehiclePowerKw.isFinite, chargerPowerKw > 0, vehiclePowerKw >= 0 else { return nil }
        self.chargerPowerKw = chargerPowerKw
        self.vehiclePowerKw = vehiclePowerKw
        lossPercent = max(0, (chargerPowerKw - vehiclePowerKw) / chargerPowerKw * 100)
    }
}

struct ChargeActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var soc:          Double   // 0..100 — SOC %
        var powerKw:      Double   // potência instantânea
        var chargerPowerKw: Double? = nil // potência medida pelo carregador
        var sessionKwh:   Double   // energia já transferida na sessão
        var remainingMin: Int      // minutos restantes (0 = sem estimativa)
        var charging:     Bool     // false quando termina (estado final)
        var targetPct:    Double   // meta de SOC (limite de carga) — 100 se desconhecido
        var locked:       Bool?    // estado real da trava: true=trancado · nil/false=destrancado
        var costBrl:      Double?  // custo R$ da sessão (kWh × preço corrente)
        var updatedAtMs:  Double   // ms epoch — bridge envia como número
        var updatedAt: Date {       // computed pra usar nas views
            Date(timeIntervalSince1970: updatedAtMs / 1000.0)
        }
    }

    var carName: String
}
