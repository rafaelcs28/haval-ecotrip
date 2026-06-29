//
//  ModeEconomySheet.swift
//  Ranking de economia por combinação de modos de condução (one-pedal /
//  regeneração / estilo / powertrain). Os dados vêm do bridge em
//  /api/stats/by-mode, que agrega os segmentos por modo de cada viagem.
//  Em HEV a métrica é km/L (o motor recarrega a bateria, então o kWh não
//  conta como custo); fora de HEV é km/L equivalente.
//

import SwiftUI

struct ModeCombo: Decodable, Identifiable {
    struct Label: Decodable { let onePedal, regenLevel, driveMode, powertrain: String }
    let key: String
    let onePedal, regenLevel, driveMode, powertrain: Int
    let isHev: Bool
    let label: Label
    let distKm: Double
    let timeMin: Int
    let netKwh: Double
    let fuelL: Double
    let kwh100: Double?
    let kmL: Double?
    let kmLeq: Double?
    let rPerKm: Double?
    let segCount: Int
    let tripCount: Int
    let lowSample: Bool
    var id: String { key }
}

struct ModeStatsResponse: Decodable {
    let tripsConsidered: Int
    let ranking: [ModeCombo]
}

struct ModeEconomySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var ranking: [ModeCombo] = []
    @State private var tripsConsidered = 0
    @State private var loading = true
    @State private var failed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if loading {
                        ProgressView().tint(DS.green).frame(maxWidth: .infinity).padding(.top, 40)
                    } else if ranking.isEmpty {
                        emptyState
                    } else {
                        Text("\(tripsConsidered) viagem\(tripsConsidered == 1 ? "" : "s") com dados de modo")
                            .font(.system(size: 11)).foregroundStyle(DS.muted)
                        ForEach(Array(ranking.enumerated()), id: \.element.id) { idx, c in
                            comboCard(c, top: idx == 0)
                        }
                        footnote
                    }
                }
                .padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Economia por modo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fechar") { dismiss() } } }
            .task { await load() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3").font(.largeTitle).foregroundStyle(DS.muted)
            Text(failed ? "Não foi possível carregar." : "Sem dados de modo ainda.")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.text)
            Text("As viagens passam a registrar one-pedal, regeneração, estilo e powertrain por trecho a partir da v6.69 do carro.")
                .font(.system(size: 11)).foregroundStyle(DS.muted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.top, 40)
    }

    private func comboCard(_ c: ModeCombo, top: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                FlowChips(chips: [
                    ("Pedal \(c.label.onePedal)", c.onePedal == 1),
                    c.onePedal == 1 ? nil : ("Regen \(c.label.regenLevel)", c.regenLevel == 1),
                    (c.label.driveMode, c.driveMode == 2),
                    (c.label.powertrain, !c.isHev),
                ].compactMap { $0 })
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    if top { Text("🏆").font(.system(size: 12)) }
                    Text(mainMetric(c)).font(.system(size: 16, weight: .bold))
                        .foregroundStyle(top ? DS.green : DS.text)
                    if !c.isHev, let k = c.kwh100 {
                        Text(String(format: "%.1f kWh/100", k))
                            .font(.system(size: 11)).foregroundStyle(DS.muted)
                    }
                }
            }
            Text(subline(c)).font(.system(size: 10)).foregroundStyle(DS.muted)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(top ? DS.green.opacity(0.10) : DS.panel)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(top ? DS.green.opacity(0.4) : DS.border, lineWidth: 1))
    }

    private func mainMetric(_ c: ModeCombo) -> String {
        if let eq = c.kmLeq { return String(format: "%.1f km/L%@", eq, c.isHev ? "" : "eq") }
        if let k = c.kwh100 { return String(format: "%.1f kWh/100", k) }
        return "—"
    }

    private func subline(_ c: ModeCombo) -> String {
        var parts = [String(format: "%.0f km", c.distKm)]
        if let r = c.rPerKm { parts.append(String(format: "R$ %.2f/km", r)) }
        if c.isHev, let k = c.kmL { parts.append(String(format: "%.1f km/L motor", k)) }
        return parts.joined(separator: " · ")
    }

    private var footnote: some View {
        Text("Comparação por km/L equivalente (kWh convertido pelo preço). HEV usa km/L do motor — em HEV a bateria é recarregada pelo motor, então o kWh não conta.")
            .font(.system(size: 10)).foregroundStyle(DS.muted).padding(.top, 4)
    }

    private func load() async {
        guard Settings.isConfigured, let url = URL(string: "\(Settings.apiBase)/api/stats/by-mode") else {
            loading = false; failed = true; return
        }
        var req = URLRequest(url: url); req.timeoutInterval = 15
        req.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
            let decoded = try JSONDecoder().decode(ModeStatsResponse.self, from: data)
            ranking = decoded.ranking.filter { !$0.lowSample }
            tripsConsidered = decoded.tripsConsidered
        } catch {
            failed = true
        }
        loading = false
    }
}

/// Linha de chips que quebra em múltiplas linhas se faltar largura.
private struct FlowChips: View {
    let chips: [(String, Bool)]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(rows(), id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(row, id: \.self) { i in chip(chips[i]) }
                }
            }
        }
    }
    private func chip(_ c: (String, Bool)) -> some View {
        Text(c.0).font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(c.1 ? DS.green.opacity(0.18) : DS.panel2)
            .foregroundStyle(c.1 ? DS.green : DS.muted)
            .clipShape(Capsule())
    }
    private func rows() -> [[Int]] {
        stride(from: 0, to: chips.count, by: 2).map { i in
            i + 1 < chips.count ? [i, i + 1] : [i]
        }
    }
}
