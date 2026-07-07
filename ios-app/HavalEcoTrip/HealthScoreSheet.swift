//  HealthScoreSheet.swift
//  Índice consolidado de saúde do carro (0-100): junta bateria 12V, pneus,
//  tendência de consumo de combustão e manutenção num só número + breakdown.

import SwiftUI

struct HealthScoreData: Decodable {
    struct Sub: Decodable { let key, label: String; let score: Int; let detail: String }
    let total: Int?
    let label: String
    let subs: [Sub]
    let issues: [String]
}

@MainActor
final class HealthScoreStore: ObservableObject {
    @Published var data: HealthScoreData?
    @Published var loading = false
    @Published var error: String?

    private var base: String {
        let u = BridgeRouter.shared.currentURL
        return u.hasSuffix("/") ? String(u.dropLast()) : u
    }

    func load() async {
        guard !base.isEmpty, let u = URL(string: "\(base)/api/health-score") else { error = "Bridge não configurado."; return }
        loading = true; error = nil; defer { loading = false }
        var r = URLRequest(url: u); r.timeoutInterval = 12
        r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        do {
            let (d, resp) = try await URLSession.shared.data(for: r)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { error = "Falha ao carregar."; return }
            data = try JSONDecoder().decode(HealthScoreData.self, from: d)
        } catch { self.error = "Erro de rede: \(error.localizedDescription)" }
    }
}

struct HealthScoreSheet: View {
    @StateObject private var store = HealthScoreStore()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let d = store.data {
                        header(d)
                        hero(d)
                        if !d.subs.isEmpty { breakdownList(d) }
                        if !d.issues.isEmpty { issuesList(d) }
                        Text("Nota combina manutenção, bateria de 12V, pneus e tendência de consumo. Itens sem dados ficam de fora.")
                            .font(.system(size: 10.5)).foregroundStyle(DS.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if store.loading {
                        ProgressView().tint(DS.green).frame(maxWidth: .infinity).padding(.vertical, 40)
                    } else if let e = store.error {
                        Text(e).font(.system(size: 12)).foregroundStyle(DS.orange).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Saúde do carro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(DS.muted) }
                }
            }
            .task { await store.load() }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func tint(_ score: Int) -> Color {
        score >= 85 ? DS.green : score >= 70 ? DS.teal : score >= 50 ? DS.yellow : DS.red
    }

    private func header(_ d: HealthScoreData) -> some View {
        HStack {
            Text("Diagnóstico").font(.system(size: 15, weight: .bold)).foregroundStyle(DS.text)
            Spacer()
            if let t = d.total { DSChip(text: "\(t)/100", color: tint(t)) }
        }
    }

    // Hero: anel 92px com "96/100" + veredito em palavras.
    private func hero(_ d: HealthScoreData) -> some View {
        let color = d.total.map(tint) ?? DS.muted
        let frac = CGFloat(d.total ?? 0) / 100
        return VStack(spacing: 12) {
            ZStack {
                Circle().stroke(DS.panel3, lineWidth: 8).frame(width: 92, height: 92)
                Circle().trim(from: 0, to: frac)
                    .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90)).frame(width: 92, height: 92)
                VStack(spacing: 0) {
                    Text(d.total.map { "\($0)" } ?? "—")
                        .font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(DS.text)
                    Text("/100").font(.system(size: 10)).foregroundStyle(DS.muted)
                }
            }
            Text(d.label).font(.system(size: 14, weight: .semibold)).foregroundStyle(color)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 4)
    }

    // Lista de subsistemas com valor semântico (detail já vem legível do bridge).
    private func breakdownList(_ d: HealthScoreData) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(d.subs.enumerated()), id: \.element.key) { i, s in
                HStack(spacing: 10) {
                    Circle().fill(tint(s.score)).frame(width: 8, height: 8)
                    Text(s.label).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.text)
                    Spacer()
                    Text(s.detail).font(.system(size: 9.5)).foregroundStyle(s.score < 70 ? DS.yellow : DS.muted)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                .padding(.vertical, 11)
                if i != d.subs.count - 1 { Rectangle().fill(DS.divider).frame(height: 1) }
            }
        }
        .padding(.horizontal, 12)
        .background(DS.panel2).clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private func issuesList(_ d: HealthScoreData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Pontos de atenção", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.orange).tracking(0.5)
            ForEach(d.issues, id: \.self) { issue in
                HStack(spacing: 6) {
                    Circle().fill(DS.orange).frame(width: 5, height: 5)
                    Text(issue).font(.system(size: 12)).foregroundStyle(DS.text)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12).background(DS.panel2).clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
    }
}
