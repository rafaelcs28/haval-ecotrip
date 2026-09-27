//
//  ShareContatosSheet.swift
//  Cartões de compartilhamento: um nome na tela de compartilhar, e por trás dele
//  quantos destinos o dono quiser — contato ou grupo, no WhatsApp pessoal ou no
//  da empresa, misturados no mesmo cartão.
//
//  Antes eram dois nomes escritos no código (Grasi e Ivone) e um número fixo em
//  variável de ambiente: pessoa nova exigia deploy. Quem entrega continua sendo
//  o recados, que já tem as duas sessões de WhatsApp de pé; o app só monta a
//  lista e o bridge reenvia.
//

import SwiftUI

// MARK: - modelo

struct ShareAlvo: Identifiable, Hashable {
    var instancia: String   // "pessoal" | "empresa"
    var tipo: String        // "contato" | "grupo"
    var alvo: String        // número (contato) ou id "...@g.us" (grupo)
    var rotulo: String
    var id: String { "\(instancia)|\(tipo)|\(alvo)" }

    var icone: String { tipo == "grupo" ? "person.3.fill" : "person.fill" }
    var instanciaCurta: String { instancia == "empresa" ? "Empresa" : "Pessoal" }

    var dict: [String: Any] { ["instancia": instancia, "tipo": tipo, "alvo": alvo, "rotulo": rotulo] }

    init(instancia: String, tipo: String, alvo: String, rotulo: String) {
        self.instancia = instancia; self.tipo = tipo; self.alvo = alvo; self.rotulo = rotulo
    }
    init?(_ d: [String: Any]) {
        guard let a = d["alvo"] as? String, !a.isEmpty else { return nil }
        instancia = (d["instancia"] as? String) ?? "pessoal"
        tipo      = (d["tipo"] as? String) ?? "contato"
        alvo      = a
        rotulo    = (d["rotulo"] as? String) ?? a
    }
}

struct ShareCartao: Identifiable, Hashable {
    var id: String
    var nome: String
    var alvos: [ShareAlvo]
    /// "grasi" amarra o cartão a quem já recebe Live Activity. A LA vive na tela
    /// de bloqueio e some; o link no WhatsApp fica — com o papel marcado, vão os
    /// dois. Só um cartão pode ter.
    var role: String

    init(id: String = "", nome: String = "", alvos: [ShareAlvo] = [], role: String = "") {
        self.id = id; self.nome = nome; self.alvos = alvos; self.role = role
    }
    init?(_ d: [String: Any]) {
        guard let i = d["id"] as? String, let n = d["nome"] as? String else { return nil }
        id = i; nome = n
        role = (d["role"] as? String) ?? ""
        alvos = ((d["alvos"] as? [[String: Any]]) ?? []).compactMap(ShareAlvo.init)
    }
    /// Uma linha dizendo pra onde vai. É o que separa "mandei" de "mandei pra quem".
    var resumo: String {
        if alvos.isEmpty { return "sem destino" }
        if alvos.count == 1 { return alvos[0].rotulo }
        return "\(alvos[0].rotulo) +\(alvos.count - 1)"
    }
}

@MainActor
final class ShareCartoesStore: ObservableObject {
    static let shared = ShareCartoesStore()
    @Published var cartoes: [ShareCartao] = []
    @Published var carregando = false
    @Published var erro: String?

    private var base: String {
        let u = BridgeRouter.shared.currentURL
        return u.hasSuffix("/") ? String(u.dropLast()) : u
    }
    private func req(_ caminho: String, _ metodo: String = "GET") -> URLRequest? {
        guard !base.isEmpty, let u = URL(string: base + caminho) else { return nil }
        var r = URLRequest(url: u); r.httpMethod = metodo; r.timeoutInterval = 25
        r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        r.addValue("application/json", forHTTPHeaderField: "Content-Type")
        return r
    }

    func carrega() async {
        guard let r = req("/api/share/contacts") else { return }
        carregando = cartoes.isEmpty; defer { carregando = false }
        guard let (d, _) = try? await URLSession.shared.data(for: r),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let arr = o["contacts"] as? [[String: Any]] else { return }
        cartoes = arr.compactMap(ShareCartao.init)
    }

    @discardableResult
    func salva(_ c: ShareCartao) async -> Bool {
        guard var r = req("/api/share/contacts", "POST") else { return false }
        var body: [String: Any] = ["nome": c.nome, "alvos": c.alvos.map { $0.dict }, "role": c.role]
        if !c.id.isEmpty { body["id"] = c.id }
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (_, resp) = try? await URLSession.shared.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { erro = "Não consegui salvar."; return false }
        await carrega()
        return true
    }

    /// Grava a ordem atual. A ordem é a da tela de compartilhar, então é
    /// conteúdo: quem manda pra mesma pessoa todo dia quer ela em primeiro.
    func salvaOrdem() async {
        guard var r = req("/api/share/contacts/order", "POST") else { return }
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["ids": cartoes.map { $0.id }])
        _ = try? await URLSession.shared.data(for: r)
    }

    func apaga(_ c: ShareCartao) async {
        guard let r = req("/api/share/contacts/\(c.id)", "DELETE") else { return }
        _ = try? await URLSession.shared.data(for: r)
        await carrega()
    }

    /// Busca na agenda do WhatsApp da instância escolhida (proxy do bridge).
    func buscaContatos(_ q: String, instancia: String) async -> [ShareAlvo] {
        let termo = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let r = req("/api/share/wa/contatos?instancia=\(instancia)&q=\(termo)") else { return [] }
        guard let (d, _) = try? await URLSession.shared.data(for: r),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let arr = o["contatos"] as? [[String: Any]] else { return [] }
        return arr.compactMap { c in
            guard let num = c["numero"] as? String else { return nil }
            return ShareAlvo(instancia: instancia, tipo: "contato", alvo: num,
                             rotulo: (c["nome"] as? String) ?? num)
        }
    }

    func buscaGrupos(instancia: String) async -> [ShareAlvo] {
        guard let r = req("/api/share/wa/grupos?instancia=\(instancia)") else { return [] }
        guard let (d, _) = try? await URLSession.shared.data(for: r),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let arr = o["grupos"] as? [[String: Any]] else { return [] }
        return arr.compactMap { g in
            guard let id = g["id"] as? String else { return nil }
            return ShareAlvo(instancia: instancia, tipo: "grupo", alvo: id,
                             rotulo: (g["nome"] as? String) ?? id)
        }
    }
}

// MARK: - lista de cartões

struct ShareContatosSheet: View {
    @ObservedObject private var store = ShareCartoesStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var editando: ShareCartao?

    var body: some View {
        NavigationStack {
            // List (e não o ScrollView de antes) porque é o que traz o arrastar
            // pra reordenar de graça. O visual escuro se mantém escondendo o
            // fundo e os separadores.
            List {
                Section {
                    ForEach(store.cartoes) { c in
                        Button { editando = c } label: { linha(c) }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    }
                    .onMove { origem, destino in
                        store.cartoes.move(fromOffsets: origem, toOffset: destino)
                        Task { await store.salvaOrdem() }
                    }
                } header: {
                    Text("Cada cartão vira um botão na tela de compartilhar. Ao tocar, o link sai no WhatsApp pra todos os destinos do cartão. Arraste pra mudar a ordem.")
                        .font(.system(size: 12.5)).foregroundStyle(DS.muted)
                        .textCase(nil).padding(.bottom, 4)
                }

                Button { editando = ShareCartao() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "plus.circle.fill")
                        Text("Novo cartão").font(.system(size: 13.5, weight: .semibold))
                    }
                    .foregroundStyle(DS.green)
                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background(DS.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 13))
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))

                if store.cartoes.isEmpty && !store.carregando {
                    Text("Nenhum cartão ainda.").font(.system(size: 12.5))
                        .foregroundStyle(DS.muted)
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Compartilhar com")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if store.cartoes.count > 1 { EditButton().foregroundStyle(DS.green) }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Concluído") { dismiss() } }
            }
            .task { await store.carrega() }
            .sheet(item: $editando) { c in ShareCartaoEditor(cartao: c) }
        }
    }

    private func linha(_ c: ShareCartao) -> some View {
        HStack(spacing: 11) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(c.nome).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(DS.text)
                    if c.role == "grasi" {
                        Image(systemName: "bell.badge.fill").font(.system(size: 10)).foregroundStyle(DS.teal)
                    }
                }
                Text(c.resumo).font(.system(size: 11.5)).foregroundStyle(DS.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            // Uma pessoa pode estar em dois WhatsApps diferentes; o cartão diz de
            // qual sai, senão "por que ela não recebeu" vira adivinhação.
            ForEach(Array(Set(c.alvos.map { $0.instanciaCurta })).sorted(), id: \.self) { i in
                Text(i).font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DS.text2)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(DS.panel2, in: Capsule())
            }
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.muted)
        }
        .padding(14)
        .background(DS.panel, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(DS.border, lineWidth: 1))
    }
}

// MARK: - editor de um cartão

struct ShareCartaoEditor: View {
    @ObservedObject private var store = ShareCartoesStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var nome: String
    @State private var alvos: [ShareAlvo]
    @State private var ehGrasi: Bool
    @State private var escolhendo = false
    private let idOriginal: String

    init(cartao: ShareCartao) {
        idOriginal = cartao.id
        _nome    = State(initialValue: cartao.nome)
        _alvos   = State(initialValue: cartao.alvos)
        _ehGrasi = State(initialValue: cartao.role == "grasi")
    }

    private var podeSalvar: Bool {
        !nome.trimmingCharacters(in: .whitespaces).isEmpty && !alvos.isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("NOME NO BOTÃO").font(.system(size: 10.5, weight: .bold)).foregroundStyle(DS.muted)
                    TextField("Ex.: Ivone", text: $nome)
                        .padding(11).background(DS.panel2, in: RoundedRectangle(cornerRadius: 11))
                        .foregroundStyle(DS.text).autocorrectionDisabled()

                    Text("DESTINOS").font(.system(size: 10.5, weight: .bold)).foregroundStyle(DS.muted)
                    ForEach(alvos) { a in
                        HStack(spacing: 10) {
                            Image(systemName: a.icone).font(.system(size: 12)).foregroundStyle(DS.teal).frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.rotulo).font(.system(size: 13.5)).foregroundStyle(DS.text).lineLimit(1)
                                Text("\(a.instanciaCurta) · \(a.tipo == "grupo" ? "grupo" : a.alvo)")
                                    .font(.system(size: 10.5)).foregroundStyle(DS.muted).lineLimit(1)
                            }
                            Spacer(minLength: 6)
                            Button { alvos.removeAll { $0.id == a.id } } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(DS.orange)
                            }.buttonStyle(.plain)
                        }
                        .padding(12)
                        .background(DS.panel2, in: RoundedRectangle(cornerRadius: 11))
                    }

                    Button { escolhendo = true } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "plus.circle.fill")
                            Text("Adicionar contato ou grupo").font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(DS.green)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(DS.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
                    }.buttonStyle(.plain)

                    Toggle(isOn: $ehGrasi) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("É a Grasi").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(DS.text)
                            Text("Escolher \"Grasi\" na tela de compartilhar manda a Live Activity e também este WhatsApp.")
                                .font(.system(size: 11)).foregroundStyle(DS.muted)
                        }
                    }
                    .tint(DS.green)
                    .padding(12)
                    .background(DS.panel2, in: RoundedRectangle(cornerRadius: 11))

                    if !idOriginal.isEmpty {
                        Button(role: .destructive) {
                            Task { await store.apaga(ShareCartao(id: idOriginal, nome: nome, alvos: alvos, role: "")); dismiss() }
                        } label: {
                            Text("Apagar cartão").font(.system(size: 13, weight: .semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                                .foregroundStyle(.red)
                                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
                        }.buttonStyle(.plain).padding(.top, 6)
                    }
                }
                .padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle(idOriginal.isEmpty ? "Novo cartão" : "Editar cartão")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar") {
                        Task {
                            let c = ShareCartao(id: idOriginal, nome: nome.trimmingCharacters(in: .whitespaces),
                                                alvos: alvos, role: ehGrasi ? "grasi" : "")
                            if await store.salva(c) { dismiss() }
                        }
                    }.disabled(!podeSalvar)
                }
            }
            .sheet(isPresented: $escolhendo) {
                ShareAlvoPicker { novo in
                    // Mesmo destino duas vezes mandaria a mensagem duplicada.
                    if !alvos.contains(where: { $0.id == novo.id }) { alvos.append(novo) }
                }
            }
        }
    }
}

// MARK: - escolher contato ou grupo

struct ShareAlvoPicker: View {
    @ObservedObject private var store = ShareCartoesStore.shared
    @Environment(\.dismiss) private var dismiss
    let escolheu: (ShareAlvo) -> Void

    @State private var instancia = "pessoal"
    @State private var modo = 0            // 0 = contato, 1 = grupo
    @State private var busca = ""
    @State private var resultados: [ShareAlvo] = []
    @State private var grupos: [ShareAlvo] = []
    @State private var carregando = false

    private var lista: [ShareAlvo] {
        if modo == 0 { return resultados }
        let q = busca.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? grupos : grupos.filter { $0.rotulo.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Picker("WhatsApp", selection: $instancia) {
                    Text("Pessoal").tag("pessoal")
                    Text("Empresa").tag("empresa")
                }.pickerStyle(.segmented)

                Picker("Tipo", selection: $modo) {
                    Text("Contato").tag(0)
                    Text("Grupo").tag(1)
                }.pickerStyle(.segmented)

                TextField(modo == 0 ? "Buscar na agenda…" : "Filtrar grupos…", text: $busca)
                    .padding(10).background(DS.panel2, in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(DS.text).autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                if carregando { ProgressView().tint(DS.green) }

                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(lista) { a in
                            Button { escolheu(a); dismiss() } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: a.icone).font(.system(size: 12)).foregroundStyle(DS.teal).frame(width: 18)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(a.rotulo).font(.system(size: 13.5)).foregroundStyle(DS.text).lineLimit(1)
                                        if a.tipo == "contato" {
                                            Text(a.alvo).font(.system(size: 10.5)).foregroundStyle(DS.muted)
                                        }
                                    }
                                    Spacer(minLength: 4)
                                }
                                .padding(11)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(DS.panel2, in: RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.plain)
                        }
                        if lista.isEmpty && !carregando {
                            Text(modo == 0 && busca.count < 2
                                 ? "Digite pelo menos 2 letras."
                                 : "Nada encontrado.")
                                .font(.system(size: 12.5)).foregroundStyle(DS.muted).padding(.top, 20)
                        }
                    }
                }
            }
            .padding(16)
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Adicionar destino")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() } } }
            .task(id: "\(instancia)|\(modo)") { await recarrega() }
            // A agenda tem milhares de contatos: busca no servidor, com respiro
            // pra não disparar um request por tecla.
            .task(id: "\(busca)|\(instancia)|\(modo)") {
                guard modo == 0 else { return }
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                let q = busca.trimmingCharacters(in: .whitespaces)
                guard q.count >= 2 else { resultados = []; return }
                carregando = true
                resultados = await store.buscaContatos(q, instancia: instancia)
                carregando = false
            }
        }
    }

    private func recarrega() async {
        resultados = []
        guard modo == 1 else { return }
        carregando = true
        grupos = await store.buscaGrupos(instancia: instancia)
        carregando = false
    }
}

// MARK: - layout auxiliar

/// Chips que quebram linha. A barra de período do app rola na horizontal e por
/// isso esconde opção — aqui a lista de destinatários cresce com o tempo (é o
/// ponto da funcionalidade), então quebrar linha é o certo.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let largura = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, alturaLinha: CGFloat = 0
        for v in subviews {
            let t = v.sizeThatFits(.unspecified)
            if x > 0, x + t.width > largura { x = 0; y += alturaLinha + spacing; alturaLinha = 0 }
            x += t.width + spacing
            alturaLinha = max(alturaLinha, t.height)
        }
        return CGSize(width: largura == .infinity ? x : largura, height: y + alturaLinha)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, alturaLinha: CGFloat = 0
        for v in subviews {
            let t = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + t.width > bounds.maxX {
                x = bounds.minX; y += alturaLinha + spacing; alturaLinha = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(t))
            x += t.width + spacing
            alturaLinha = max(alturaLinha, t.height)
        }
    }
}
