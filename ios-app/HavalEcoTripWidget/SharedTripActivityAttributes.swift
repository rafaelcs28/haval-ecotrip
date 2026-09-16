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
        var from:         String     // (compat) nome do remetente — LA não mostra mais
        var destName:     String     // destino atual do carro (ex.: "Casa da Tia") — "" se nenhum
        var etaToDestMin: Int        // minutos até o destino (se houver)
        var distToDestKm: Double     // km até o destino (se houver)
        var socPct:       Int        // (compat) SOC % — LA não mostra mais
        var moving:       Bool       // carro andando agora
        var active:       Bool       // false quando share expira/revoga
        // Delay em min vs baseline histórico do mesmo dia da semana. Positivo =
        // trânsito acima do normal; ≤0 = normal ou melhor. nil = sem cálculo
        // disponível → LA esconde a pill.
        var delayMin:     Int?
        // Endereço reverso da posição atual do carro (curto, ex.: "R. das
        // Palmeiras, 245 · Setor Bueno"). "" quando bridge ainda não geocodou
        // ou fora de área com dados.
        var currentAddress: String?
        // Progresso 0..1 baseado em 1 − distToDest/startDistKm. Bridge grava
        // startDistKm no token na 1a tick com dist>0. Opcional pra compat.
        var progress:     Double?
        var updatedAtMs:  Double
        var updatedAt: Date { Date(timeIntervalSince1970: updatedAtMs / 1000.0) }
    }

    // Identidade imutável da atividade.
    var shareToken: String
    var from:       String
    // URL pública do trajeto (bridge/public/shared-trip.html). Widget usa como
    // widgetURL — toque na LA abre no Safari, não no deep link do BydRecarga.
    // Opcional pra compat com LAs criadas antes da mudança.
    var shareURL:   String?
}
