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
    @Published var grasiPaired: Bool = false   // se a Grasi já pareou pelo Grasi Recarga
    @Published var grasiName: String = "Grasi"
    @Published var deliveredViaLA: Bool = false   // último share caiu direto na LA dela

    private var base: String {
        let u = BridgeRouter.shared.currentURL
        return u.hasSuffix("/") ? String(u.dropLast()) : u
    }

    func create(ttlMin: Int, recipientName: String?, recipientRole: String?) async {
        guard !base.isEmpty, let u = URL(string: "\(base)/api/share/create") else { error = "Bridge não configurado."; return }
        loading = true; error = nil; defer { loading = false }
        var r = URLRequest(url: u); r.httpMethod = "POST"; r.timeoutInterval = 12
        r.addValue("application/json", forHTTPHeaderField: "Content-Type")
        r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        var body: [String: Any] = ["ttlMin": ttlMin]
        if let n = recipientName, !n.isEmpty { body["recipientName"] = n }
        if let role = recipientRole, !role.isEmpty { body["recipientRole"] = role }
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await URLSession.shared.data(for: r)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let url = j["url"] as? String else { error = "Falha ao gerar o link."; return }
            self.url = url
            self.token = j["token"] as? String
            self.expiresMs = (j["expiresMs"] as? Double) ?? 0
            self.destName = (j["destName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            self.deliveredViaLA = (j["paired"] as? Bool) ?? false   // share caiu direto na LA dela?
        } catch { self.error = "Erro de rede: \(error.localizedDescription)" }
    }

    /// Consulta no bridge quem já pareou um device do Grasi Recarga. A UI usa
    /// isso pra mostrar "Grasi vai receber direto no iPhone (sem precisar de link)".
    func loadPaired() async {
        guard !base.isEmpty, let u = URL(string: "\(base)/api/byd/paired-recipients") else { return }
        var r = URLRequest(url: u); r.timeoutInterval = 8
        r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: r),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["recipients"] as? [[String: Any]] else { return }
        let grasi = arr.first { ($0["role"] as? String) == "grasi" }
        grasiPaired = (grasi != nil)
        if let n = grasi?["name"] as? String, !n.isEmpty { grasiName = n }
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
    @State private var recipientKind: RecipientKind = .other
    @State private var otherName = ""
    @State private var includeSoc = true
    @State private var pulse = false

    enum RecipientKind: String, CaseIterable, Identifiable {
        case grasi = "Grasi"
        case other = "Outra pessoa"
        var id: String { rawValue }
        var role: String { self == .grasi ? "grasi" : "other" }
    }

    private let options: [(String, Int)] = [
        ("30 min", 30), ("1 h", 60), ("2 h", 120), ("3 h", 180), ("4 h", 240),
        ("5 h", 300), ("8 h", 480), ("12 h", 720), ("24 h", 1440),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    // Preview: o que a pessoa vê ao abrir o link.
                    DSCard(title: "O que a pessoa vê") {
                        HStack(spacing: 12) {
                            Image(systemName: "car.fill").font(.system(size: 22)).foregroundStyle(DS.teal)
                                .frame(width: 34)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Carro ao vivo no mapa").font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.text)
                                Text("distância + tempo de carro até você")
                                    .font(.system(size: 10)).foregroundStyle(DS.muted)
                                if includeSoc {
                                    Text("SOC e autonomia").font(.system(size: 10)).foregroundStyle(DS.green)
                                }
                            }
                            Spacer()
                        }
                    }

                    DSCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Quem abrir o link vê o carro ao vivo no mapa (velocidade, marcha, SOC, autonomia, temperaturas) e a distância + tempo de carro até onde a pessoa está.")
                                .font(.callout).foregroundStyle(DS.muted)
                            // Destinatário: Grasi → link pareia o iPhone dela com o app Grasi
                            // Recarga (vira o destino das LAs "indo até você"). Outra pessoa →
                            // só nome registrado pra auditoria.
                            Text("Pra quem?").font(.caption).foregroundStyle(DS.muted)
                            HStack(spacing: 8) {
                                ForEach(RecipientKind.allCases) { k in
                                    Button { recipientKind = k } label: {
                                        Text(k.rawValue).font(.subheadline.weight(.semibold))
                                            .frame(maxWidth: .infinity).padding(.vertical, 11)
                                            .background(recipientKind == k ? DS.teal.opacity(0.22) : DS.panel2)
                                            .foregroundStyle(recipientKind == k ? DS.teal : DS.text)
                                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    }.buttonStyle(.plain)
                                }
                            }
                            if recipientKind == .other {
                                TextField("Nome (ex.: João)", text: $otherName)
                                    .padding(10).background(DS.panel2)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .foregroundStyle(DS.text).autocorrectionDisabled()
                            } else if store.grasiPaired {
                                // Já pareada: share vai direto pra LA dela — sem precisar mandar link.
                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark.seal.fill").foregroundStyle(DS.green)
                                    Text("\(store.grasiName) já está pareada — vai cair direto no iPhone dela como Live Activity. Sem precisar mandar link.")
                                        .font(.caption).foregroundStyle(DS.green)
                                }
                            } else {
                                Text("Quando ela abrir no iPhone, o link pareia o app Grasi Recarga — vira o destino das notificações de chegada. Da próxima vez não precisa mais mandar link.")
                                    .font(.caption).foregroundStyle(DS.muted)
                            }
                            Text("Duração do link").font(.caption).foregroundStyle(DS.muted)
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                                ForEach(options, id: \.1) { opt in
                                    let on = ttlMin == opt.1
                                    Button { ttlMin = opt.1 } label: {
                                        Text(opt.0).font(.system(size: 13, weight: .semibold))
                                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                                            .foregroundStyle(on ? Color.black : DS.text2)
                                            .background(on ? DS.teal : DS.panel2)
                                            .clipShape(Capsule())
                                    }.buttonStyle(.plain)
                                }
                            }

                            // Toggle: incluir SOC e autonomia na tela da pessoa.
                            Toggle(isOn: $includeSoc) {
                                Text("Incluir SOC e autonomia").font(.system(size: 13)).foregroundStyle(DS.text)
                            }
                            .tint(DS.green)
                            .padding(.top, 2)
                        }
                    }

                    if let url = store.url, URL(string: url) != nil {
                        DSCard {
                            VStack(alignment: .leading, spacing: 12) {
                                // Chip "ativo · <nome>" com respiração.
                                HStack(spacing: 6) {
                                    Circle().fill(DS.green).frame(width: 8, height: 8)
                                        .opacity(pulse ? 0.35 : 1)
                                        .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)
                                    Text("ativo\(activeName.isEmpty ? "" : " · \(activeName)")")
                                        .font(.system(size: 12, weight: .bold)).foregroundStyle(DS.green)
                                    Spacer()
                                }
                                .onAppear { pulse = true }
                                // Quando o share foi entregue direto na LA da Grasi (paired),
                                // a UI muda: chama destaque do delivery; link fica como
                                // fallback opcional ("se ela perder a LA, manda este link").
                                if store.deliveredViaLA {
                                    HStack(spacing: 6) {
                                        Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                                            .foregroundStyle(DS.green)
                                        Text("Caiu direto no iPhone da \(store.grasiName) ✓")
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(DS.green)
                                    }
                                    Text("A Live Activity já apareceu na tela bloqueada dela. Se ela tocar, abre o trajeto no Grasi Recarga. Você nem precisa mandar nada.")
                                        .font(.caption).foregroundStyle(DS.muted)
                                    Text("Se preferir mandar o link mesmo assim:").font(.caption).foregroundStyle(DS.muted)
                                }
                                HStack(spacing: 6) {
                                    Image(systemName: "link").foregroundStyle(DS.teal)
                                    Text(url).font(.footnote).foregroundStyle(DS.text).lineLimit(1).truncationMode(.middle)
                                }
                                Text(expiryText).font(.caption).foregroundStyle(DS.muted)
                                // Compartilha como TEXTO (não só URL): o destinatário recebe
                                // "Acompanhe meu trajeto[ para <destino>]. <link>" — apps tipo
                                // WhatsApp/Messages auto-linkificam a URL no fim da frase.
                                // Copiar link (pill verde) — primária.
                                Button {
                                    UIPasteboard.general.string = shareText(url: url)
                                } label: {
                                    Label("Copiar link", systemImage: "doc.on.doc")
                                        .font(.system(size: 15, weight: .bold)).frame(maxWidth: .infinity).frame(height: 42)
                                        .foregroundStyle(Color.black)
                                        .background(DS.green)
                                        .clipShape(Capsule())
                                }.buttonStyle(.plain)
                                // Compartilhar via share sheet (secundária).
                                ShareLink(item: shareText(url: url),
                                          subject: Text("Trajeto Haval")) {
                                    Label(store.deliveredViaLA ? "Mandar link mesmo assim" : "Compartilhar",
                                          systemImage: "square.and.arrow.up")
                                        .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 11)
                                        .background(DS.teal.opacity(0.22)).foregroundStyle(DS.teal)
                                        .clipShape(Capsule())
                                }
                                // Parar (destrutiva).
                                Button(role: .destructive) { Task { await store.revoke() } } label: {
                                    Label("Parar", systemImage: "stop.circle")
                                        .font(.system(size: 15, weight: .bold)).frame(maxWidth: .infinity).frame(height: 42)
                                        .foregroundStyle(DS.red)
                                        .background(DS.red.opacity(0.12))
                                        .clipShape(Capsule())
                                }.buttonStyle(.plain)
                            }
                        }
                    } else {
                        DSActionButton(icon: "link.badge.plus", title: "Gerar link", color: DS.green, busy: store.loading) {
                            let name: String? = recipientKind == .grasi ? "Grasi" :
                                otherName.trimmingCharacters(in: .whitespaces).isEmpty ? nil : otherName.trimmingCharacters(in: .whitespaces)
                            Task { await store.create(ttlMin: ttlMin, recipientName: name, recipientRole: recipientKind.role) }
                        }
                    }

                    if let e = store.error {
                        Text(e).font(.callout).foregroundStyle(DS.orange).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .task { await store.loadPaired() }
            .navigationTitle("Compartilhar status")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fechar") { dismiss() } } }
        }
    }

    /// Nome pra chip "ativo · <nome>": destino resolvido, senão o destinatário escolhido.
    private var activeName: String {
        if let n = store.destName?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { return n }
        if recipientKind == .grasi { return store.grasiName }
        return otherName.trimmingCharacters(in: .whitespaces)
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
