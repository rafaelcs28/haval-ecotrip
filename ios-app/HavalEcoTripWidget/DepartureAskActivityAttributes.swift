//
//  DepartureAskActivityAttributes.swift
//  Live Activity "Indo pra <dest>? Compartilhar com <subject>?" — aparece no
//  iPhone do Rafael toda vez que ele liga o carro dentro de uma origem
//  monitorada (Saídas monitoradas) na janela configurada.
//
//  3 botões (LiveActivityIntent, iOS 17+): Sim / Adiar 5min / Não.
//    Sim   → POST /api/departure/accept → seta destino no carro + share pra Grasi
//    Adiar → só encerra a LA localmente e marca snooze até now+5min
//    Não   → POST /api/departure/dismiss + encerra localmente
//
//  ⚠ Target membership: HavalEcoTrip + HavalEcoTripWidget (via project.yml).
//
import ActivityKit
import Foundation

struct DepartureAskActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        // Timestamp de criação (auto-dismiss após 5min sem ação — evita LA presa
        // se o usuário sair da tela sem clicar).
        var startedMs: Double
        // "asking" enquanto aguarda resposta; "acted" após tap (LA dá isFinal).
        var status: String   // "asking" | "acted_accept" | "acted_dismiss" | "acted_snooze"
        // Mensagem curta após tap (ex.: "Destino setado + share criado").
        var resultText: String?
    }

    // Identidade imutável: qual config disparou + labels pra render.
    var configId: String
    var sourceName: String
    var destName: String
    var subject: String       // destinatário do share (ex.: "Grasi")
}
