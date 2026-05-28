//
//  SongProActivityAttributes.swift
//  Live Activity da recarga do BYD Song Pro (carro da esposa) — cor azul clarinho
//  pra diferenciar visualmente da LA de recarga do Haval (verde).
//  Mesmo shape de ContentState do ChargeActivityAttributes pra reuso do código
//  da view; só muda o ActivityAttributes type pra o iOS tratar como LA distinta.
//
import ActivityKit
import Foundation

struct SongProActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var soc:          Double   // 0..100 — SOC %
        var powerKw:      Double   // potência instantânea
        var sessionKwh:   Double   // energia já transferida na sessão (integrada do power × tempo)
        var remainingMin: Int      // minutos pra 100% (0 = sem estimativa). Calculado: (100−soc)·18/power·60
        var charging:     Bool     // false quando termina (estado final)
        var updatedAtMs:  Double
        var updatedAt: Date {
            Date(timeIntervalSince1970: updatedAtMs / 1000.0)
        }
    }

    var carName: String   // "BYD Song Pro" por padrão
}
