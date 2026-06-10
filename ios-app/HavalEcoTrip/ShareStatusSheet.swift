//  ShareStatusSheet.swift
//  Compartilhar status do carro por link temporário: escolhe a duração, gera o
//  link encurtado no bridge e abre o share sheet. Mostra o link ativo + revogar.

import SwiftUI

@MainActor
final class ShareStatusStore: ObservableObject {
    @Published var url: String?
    @Published var token: String?
    @Published var expiresMs: Double = 0
    @Published var destName: String?
    @Published var loading = false
    @Published var error: String?

    private var base: String {
        let u = Settings.bridgeURL.isEmpty ? AuthConfig.bridgeURL : Settings.bridgeURL
        return u.hasSuffix("/") ? String(u.dropLast()) : u
    }

    func create(ttlMin: Int) async {
        guard !base.isEmpty, let u = URL(string: "\(base)/api/share/create") else { error = "Bridge não configurado."; return }
        loading = true; error = nil; defer { loading = false }
        var r = URLRequest(url: u); r.httpMethod = "POST"; r.timeoutInterval = 12
        r.addValue("application/json", forHTTPHeaderField: "Content-Type")
        r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["ttlMin": ttlMin])
        do {
            let (data, resp) = try await URLSession.shared.data(for: r)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let url = j["url"] as? String else { error = "Falha ao gerar o link."; return }
            self.url = url
            self.token = j["token"] as? String
            self.expiresMs = (j["expiresMs"] as? Double) ?? 0
            self.destName = (j["destName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        } catch { self.error = "Erro de rede: \(error.localizedDescription)" }
    }

    func revoke() async {
        guard let t = token, !base.isEmpty, let u = URL(string: "\(base)/api/share/revoke") else { return }
        var r = URLRequest(url: u); r.httpMethod = "POST"; r.timeoutInterval = 10
        r.addValue("application/json", forHTTPHeaderField: "Content-Type")
        r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["token": t])
        _ = try? await URLSession.shared.data(for: r)
        url = nil; token = nil; expiresMs = 0; destName = nil
    }
}

struct ShareStatusSheet: View {
    @StateObject private var store = ShareStatusStore()
    @Environment(\.dismiss) private var dismiss
    @State private var ttlMin = 120

    private let options: [(String, Int)] = [
        ("30 min", 30), ("1 h", 60), ("2 h", 120), ("3 h", 180), ("4 h", 240),
        ("5 h", 300), ("8 h", 480), ("12 h", 720), ("24 h", 1440),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    DSCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Quem abrir o link vê o carro ao vivo no mapa (velocidade, marcha, SOC, autonomia, temperaturas) e a distância + tempo de carro até onde a pessoa está.")
                                .font(.callout).foregroundStyle(DS.muted)
                            Text("Duração do link").font(.caption).foregroundStyle(DS.muted)
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                                ForEach(options, id: \.1) { opt in
                                    Button { ttlMin = opt.1 } label: {
                                        Text(opt.0).font(.subheadline.weight(.semibold))
                                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                                            .background(ttlMin == opt.1 ? DS.teal.opacity(0.22) : DS.panel2)
                                            .foregroundStyle(ttlMin == opt.1 ? DS.teal : DS.text)
                                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    if let url = store.url, URL(string: url) != nil {
                        DSCard {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 6) {
                                    Image(systemName: "link").foregroundStyle(DS.teal)
                                    Text(url).font(.footnote).foregroundStyle(DS.text).lineLimit(1).truncationMode(.middle)
                                }
                                Text(expiryText).font(.caption).foregroundStyle(DS.muted)
                                // Compartilha como TEXTO (não só URL): o destinatário recebe
                                // "Acompanhe meu trajeto[ para <destino>]. <link>" — apps tipo
                                // WhatsApp/Messages auto-linkificam a URL no fim da frase.
                                ShareLink(item: shareText(url: url),
                                          subject: Text("Trajeto Haval")) {
                                    Label("Compartilhar link", systemImage: "square.and.arrow.up")
                                        .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 12)
                                        .background(DS.teal.opacity(0.22)).foregroundStyle(DS.teal)
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                Button(role: .destructive) { Task { await store.revoke() } } label: {
                                    Label("Revogar link", systemImage: "xmark.circle")
                                        .font(.subheadline).frame(maxWidth: .infinity).padding(.vertical, 10)
                                        .foregroundStyle(DS.red)
                                }
                            }
                        }
                    } else {
                        DSActionButton(icon: "link.badge.plus", title: "Gerar link", color: DS.green, busy: store.loading) {
                            Task { await store.create(ttlMin: ttlMin) }
                        }
                    }

                    if let e = store.error {
                        Text(e).font(.callout).foregroundStyle(DS.orange).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Compartilhar status")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fechar") { dismiss() } } }
        }
    }

    private var expiryText: String {
        guard store.expiresMs > 0 else { return "" }
        let f = RelativeDateTimeFormatter(); f.locale = Locale(identifier: "pt_BR"); f.unitsStyle = .full
        return "Expira " + f.localizedString(for: Date(timeIntervalSince1970: store.expiresMs / 1000), relativeTo: Date())
    }

    private func shareText(url: String) -> String {
        if let n = store.destName?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
            return "Acompanhe meu trajeto para \(n). \(url)"
        }
        return "Acompanhe meu trajeto. \(url)"
    }
}
