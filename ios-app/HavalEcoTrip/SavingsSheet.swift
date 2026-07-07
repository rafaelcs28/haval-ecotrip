//  SavingsSheet.swift
//  Economia vitalícia vs carro a gasolina: R$ poupados, litros-equivalentes
//  evitados e km elétricos. Gera um cartão (imagem) compartilhável.

import SwiftUI

struct SavingsData: Decodable {
    struct Cost: Decodable { let electricity, fuel, actual, iceBaseline: Double }
    struct Assumptions: Decodable { let iceBaselineKmL, gasPricePerL, kwhPerLitre: Double }
    let distanceKm, electricKm, fuelL, netKwh, savedBrl, litersSaved, baselineLiters: Double
    let electricShare: Double
    let cost: Cost
    let assumptions: Assumptions
}

@MainActor
final class SavingsStore: ObservableObject {
    @Published var data: SavingsData?
    @Published var loading = false
    @Published var error: String?

    private var base: String {
        let u = BridgeRouter.shared.currentURL
        return u.hasSuffix("/") ? String(u.dropLast()) : u
    }

    func load() async {
        guard !base.isEmpty, let u = URL(string: "\(base)/api/stats/savings") else { error = "Bridge não configurado."; return }
        loading = true; error = nil; defer { loading = false }
        var r = URLRequest(url: u); r.timeoutInterval = 12
        r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        do {
            let (d, resp) = try await URLSession.shared.data(for: r)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { error = "Falha ao carregar."; return }
            data = try JSONDecoder().decode(SavingsData.self, from: d)
        } catch { self.error = "Erro de rede: \(error.localizedDescription)" }
    }
}

struct SavingsSheet: View {
    @StateObject private var store = SavingsStore()
    @Environment(\.dismiss) private var dismiss
    @State private var cardURL: URL?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if let d = store.data {
                        heroCard(d)
                        breakdownCard(d)
                        DSActionButton(icon: "square.and.arrow.up", title: "Compartilhar cartão", color: DS.green) { renderCard(d) }
                        if let u = cardURL {
                            ShareLink(item: u, preview: SharePreview("Economia Haval", image: Image(systemName: "leaf.fill"))) {
                                Label("Cartão (imagem)", systemImage: "photo")
                                    .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 10)
                                    .background(DS.panel2).foregroundStyle(DS.text)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        }
                        Text("Baseline: SUV gasolina a \(Fmt.dec1(d.assumptions.iceBaselineKmL)) km/L (gasolina \(Fmt.brl(d.assumptions.gasPricePerL))/L). Eletricidade convertida a \(Fmt.dec1(d.assumptions.kwhPerLitre)) kWh/L.")
                            .font(.caption2).foregroundStyle(DS.muted)
                    } else if store.loading {
                        ProgressView().tint(DS.green).frame(maxWidth: .infinity).padding(.vertical, 40)
                    } else if let e = store.error {
                        DSCard { Text(e).font(.callout).foregroundStyle(DS.orange).frame(maxWidth: .infinity, alignment: .leading) }
                    }
                }
                .padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Economia total")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fechar") { dismiss() } } }
            .task { await store.load() }
        }
    }

    private func heroCard(_ d: SavingsData) -> some View {
        DSCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "leaf.fill").foregroundStyle(DS.green)
                    Text("Economizado vs gasolina").font(.caption.weight(.semibold)).foregroundStyle(DS.muted).tracking(0.5)
                }
                Text(Fmt.brl(max(0, d.savedBrl)))
                    .font(.system(size: 44, weight: .bold, design: .rounded)).foregroundStyle(DS.green)
                    .lineLimit(1).minimumScaleFactor(0.5)
                Text("≈ \(Fmt.dec1(max(0, d.litersSaved))) L de gasolina poupados em \(Fmt.km(d.distanceKm)) km")
                    .font(.callout).foregroundStyle(DS.text)
            }
        }
    }

    private func breakdownCard(_ d: SavingsData) -> some View {
        DSCard {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    DSMetric(value: Fmt.km(d.electricKm), unit: "km", label: "Rodados elétrico", color: DS.green, compact: true)
                    DSMetric(value: "\(Int(d.electricShare))", unit: "%", label: "Energia da tomada", color: DS.teal, compact: true)
                    DSMetric(value: Fmt.dec1(d.netKwh), unit: "kWh", label: "Eletricidade", color: DS.blue, compact: true)
                }
                Divider().overlay(DS.border)
                HStack(spacing: 10) {
                    DSMetric(value: Fmt.brl(d.cost.actual), label: "Gasto real", color: DS.text, compact: true)
                    DSMetric(value: Fmt.brl(d.cost.iceBaseline), label: "Custaria a gasolina", color: DS.orange, compact: true)
                }
                HStack(spacing: 10) {
                    DSMetric(value: Fmt.brl(d.cost.electricity), label: "Eletricidade", color: DS.green, compact: true)
                    DSMetric(value: Fmt.brl(d.cost.fuel), label: "Combustível", color: DS.orange, compact: true)
                    DSMetric(value: Fmt.dec1(d.fuelL), unit: "L", label: "Gasolina usada", color: DS.muted, compact: true)
                }
            }
        }
    }

    @MainActor
    private func renderCard(_ d: SavingsData) {
        let card = ShareCard(d: d).frame(width: 1080, height: 1080)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 1
        guard let img = renderer.uiImage else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("haval-economia.png")
        try? img.pngData()?.write(to: url)
        cardURL = url
    }
}

private struct ShareCard: View {
    let d: SavingsData
    var body: some View {
        ZStack {
            Color.black
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 14) {
                    Image(systemName: "leaf.fill").font(.system(size: 52)).foregroundStyle(DS.green)
                    Text("Minha economia Haval").font(.system(size: 52, weight: .bold)).foregroundStyle(.white)
                }
                Spacer()
                Text("Economizei vs gasolina").font(.system(size: 40, weight: .medium)).foregroundStyle(Color(white: 0.6))
                Text(Fmt.brl(max(0, d.savedBrl))).font(.system(size: 150, weight: .heavy, design: .rounded)).foregroundStyle(DS.green)
                    .lineLimit(1).minimumScaleFactor(0.4)
                Text("≈ \(Fmt.dec1(max(0, d.litersSaved))) L de gasolina poupados").font(.system(size: 44, weight: .semibold)).foregroundStyle(.white)
                Spacer()
                HStack(spacing: 0) {
                    stat(Fmt.km(d.distanceKm), "km rodados")
                    stat(Fmt.km(d.electricKm), "km elétrico")
                    stat("\(Int(d.electricShare))%", "da tomada")
                }
                Text("Haval Hub").font(.system(size: 34, weight: .medium)).foregroundStyle(Color(white: 0.4))
            }
            .padding(72)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
    private func stat(_ v: String, _ l: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(v).font(.system(size: 56, weight: .bold, design: .rounded)).foregroundStyle(DS.teal)
            Text(l).font(.system(size: 30)).foregroundStyle(Color(white: 0.6))
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
