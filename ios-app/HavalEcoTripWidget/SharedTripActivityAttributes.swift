//
//  SharedTripActivityAttributes.swift
//  Live Activity "trajeto compartilhado contigo" — aparece SÓ no iPhone da
//  Grasi (ou de qualquer device com role=grasi pareado) quando o Rafael
//  cria um share do Haval Hub direcionado a ela. Sem precisar mandar link:
//  a LA já carrega o token e ao tocar abre a página da viagem dentro do
//  próprio Grasi Recarga.
//
//  Disparada/atualizada/encerrada pelo bridge via APNs conforme o share token
//  permanece válido e o carro publica novos updates.
//
//  ⚠ Target membership: app BydRecarga + BydRecargaWidget (via project.yml).
//    Campos do ContentState precisam casar com o cs montado em
//    _evalSharedTripLA() no bridge.
//
import ActivityKit
import Foundation

struct SharedTripActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var from:         String     // nome do remetente (ex.: "Rafael")
        var destName:     String     // destino atual do carro (ex.: "Casa da Tia") — "" se nenhum
        var etaToDestMin: Int        // minutos até o destino (se houver)
        var distToDestKm: Double     // km até o destino (se houver)
        var socPct:       Int        // SOC % do carro
        var moving:       Bool       // carro andando agora
        var active:       Bool       // false quando share expira/revoga
        // Delay em min vs baseline histórico do mesmo dia da semana. Positivo =
        // trânsito acima do normal; ≤0 = normal ou melhor. nil = sem cálculo
        // disponível (rota desconhecida ou fora de horário) → LA esconde a pill.
        // Optional em Codable = apps velhos ignoram o campo, sem regressão.
        var delayMin:     Int?
        var updatedAtMs:  Double
        var updatedAt: Date { Date(timeIntervalSince1970: updatedAtMs / 1000.0) }
    }

    // Identidade imutável da atividade — token do share + nome do remetente.
    var shareToken: String
    var from:       String
}
