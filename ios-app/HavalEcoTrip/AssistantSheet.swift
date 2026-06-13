//
//  AssistantSheet.swift
//  Chat com o assistente de IA do bridge (POST /api/ai/ask, multi-turn). O bridge
//  antepõe um system prompt com a telemetria atual do carro (SOC, viagens, recargas)
//  e responde via Ollama. Aqui mandamos a thread inteira (user/assistant alternados)
//  e mostramos as bolhas. Sem persistência: a conversa vive só enquanto o sheet abre.
//

import SwiftUI

struct ChatMsg: Identifiable, Equatable {
    let id = UUID()
    let role: String          // "user" | "assistant"
    var content: String
    var pending = false       // bolha "pensando…" do assistente
}

@MainActor
final class AssistantStore: ObservableObject {
    @Published var messages: [ChatMsg] = []
    @Published var sending = false
    @Published var errorText: String?

    private var base: String {
        let u = Settings.apiBase.isEmpty ? AuthConfig.bridgeURL : Settings.apiBase
        return u.hasSuffix("/") ? String(u.dropLast()) : u
    }

    func send(_ raw: String) {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !sending else { return }
        errorText = nil
        messages.append(ChatMsg(role: "user", content: q))
        messages.append(ChatMsg(role: "assistant", content: "", pending: true))
        sending = true
        Task { await call() }
    }

    private func call() async {
        // Monta o payload com a thread já enviada (sem a bolha pending).
        let thread = messages
            .filter { !$0.pending }
            .map { ["role": $0.role, "content": $0.content] }
        defer { sending = false }
        guard let url = URL(string: base + "/api/ai/ask") else { fail("URL inválida"); return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        req.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["messages": thread])
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if code == 200, let ans = obj?["answer"] as? String {
                replacePending(with: ans)
            } else {
                let msg = (obj?["error"] as? String) ?? "Erro \(code)"
                fail(msg)
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func replacePending(with text: String) {
        if let i = messages.lastIndex(where: { $0.pending }) {
            messages[i].content = text
            messages[i].pending = false
        }
    }

    private func fail(_ msg: String) {
        // Remove a bolha pending e mostra o erro acima do input.
        messages.removeAll { $0.pending }
        errorText = msg
    }

    func reset() { messages = []; errorText = nil }
}

struct AssistantSheet: View {
    @StateObject private var store = AssistantStore()
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @FocusState private var focused: Bool

    private let suggestions = [
        "Como está a bateria agora?",
        "Quanto economizei esse mês?",
        "Qual foi minha última recarga?",
        "Resuma minhas viagens recentes.",
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            if store.messages.isEmpty { emptyState }
                            ForEach(store.messages) { m in bubble(m).id(m.id) }
                            if let e = store.errorText { errorRow(e) }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(14)
                    }
                    .onChange(of: store.messages) { _, _ in
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
                inputBar
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Assistente IA")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { store.reset() } label: { Image(systemName: "square.and.pencil") }
                        .foregroundStyle(DS.text)
                        .disabled(store.messages.isEmpty || store.sending)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fechar") { dismiss() }
                }
            }
        }
    }

    // MARK: subviews
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(DS.teal)
                Text("Pergunte sobre a telemetria do carro")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.text)
            }
            Text("O assistente vê o estado atual do carro, viagens e recargas.")
                .font(.system(size: 13)).foregroundStyle(DS.muted)
            ForEach(suggestions, id: \.self) { s in
                Button { store.send(s) } label: {
                    HStack {
                        Text(s).font(.system(size: 14)).foregroundStyle(DS.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "arrow.up.right").font(.system(size: 11)).foregroundStyle(DS.muted)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 11)
                    .background(DS.panel).clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(DS.border, lineWidth: 1))
                }
            }
        }
        .padding(.top, 30)
    }

    @ViewBuilder
    private func bubble(_ m: ChatMsg) -> some View {
        let isUser = m.role == "user"
        HStack {
            if isUser { Spacer(minLength: 40) }
            Group {
                if m.pending {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small).tint(DS.muted)
                        Text("pensando…").font(.system(size: 13)).foregroundStyle(DS.muted)
                    }
                } else {
                    Text(m.content)
                        .font(.system(size: 15))
                        .foregroundStyle(isUser ? .black : DS.text)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 13).padding(.vertical, 9)
            .background(isUser ? DS.green : DS.panel)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isUser ? Color.clear : DS.border, lineWidth: 1))
            if !isUser { Spacer(minLength: 40) }
        }
    }

    private func errorRow(_ e: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.red)
            Text(e).font(.system(size: 13)).foregroundStyle(DS.red)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(DS.red.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Pergunte…", text: $input, axis: .vertical)
                .lineLimit(1...4)
                .font(.system(size: 15)).foregroundStyle(DS.text)
                .focused($focused)
                .padding(.horizontal, 13).padding(.vertical, 10)
                .background(DS.panel2).clipShape(RoundedRectangle(cornerRadius: 14))
                .onSubmit(sendInput)
            Button(action: sendInput) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(canSend ? DS.green : DS.muted)
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(DS.bg)
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !store.sending
    }

    private func sendInput() {
        guard canSend else { return }
        store.send(input)
        input = ""
    }
}
