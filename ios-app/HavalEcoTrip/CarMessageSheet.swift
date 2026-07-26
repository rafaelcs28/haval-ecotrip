//
//  CarMessageSheet.swift
//  Recado curto (até 100 caracteres) exibido em TELA CHEIA no painel do carro.
//  O APK usa full-screen-intent — mesmo mecanismo da chamada recebida — então o
//  recado aparece por cima do app que estiver em uso na central.
//
//  Espelha o botão equivalente da página do trajeto compartilhado, pra quem
//  recebe o link poder mandar recado também.
//

import SwiftUI

struct CarMessageSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var car = CarStore.shared
    @State private var text = ""
    @State private var sending = false
    @State private var sent = false
    @State private var errMsg = ""
    @FocusState private var focused: Bool

    private let maxChars = 100
    /// Sugestões do que mais se manda dirigindo — evita digitar em movimento.
    private let quick = ["Chego em 10 min", "Pode ir na frente", "Estou no trânsito",
                         "Já saí", "Passa no mercado", "Me liga quando puder"]

    /// O recado só aparece se a central está acordada (o comando não chega num
    /// APK fora do MQTT) — mesmo critério do botão na página compartilhada.
    private var carAwake: Bool { car.carOnline }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !carAwake { asleepCard }
                    editorCard
                    quickCard
                    if !errMsg.isEmpty {
                        Text(errMsg).font(.system(size: 12.5)).foregroundStyle(DS.red)
                    }
                    sendButton
                }
                .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 20)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Recado no carro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fechar") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private var asleepCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "moon.zzz.fill").foregroundStyle(DS.orange)
            Text("A central está dormindo — o recado não apareceria agora.")
                .font(.system(size: 12.5)).foregroundStyle(DS.text2)
        }
        .padding(12)
        .background(DS.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DS.orange.opacity(0.35), lineWidth: 1))
    }

    private var editorCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("APARECE EM TELA CHEIA NO PAINEL")
                .font(.system(size: 8.5, weight: .bold)).foregroundStyle(DS.muted).tracking(1)
            TextField("Ex.: passa no mercado na volta", text: $text, axis: .vertical)
                .lineLimit(3, reservesSpace: true)
                .font(.system(size: 15))
                .foregroundStyle(DS.text)
                .focused($focused)
                .onChange(of: text) { _, v in
                    if v.count > maxChars { text = String(v.prefix(maxChars)) }
                }
            HStack {
                Spacer()
                Text("\(maxChars - text.count) restantes")
                    .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(DS.muted)
            }
        }
        .padding(14)
        .background(DS.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(DS.border, lineWidth: 1))
    }

    private var quickCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RÁPIDOS").font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(DS.muted).tracking(1)
            // FlowLayout simples: 2 colunas fixas cabem no iPhone sem truncar.
            let cols = [GridItem(.flexible()), GridItem(.flexible())]
            LazyVGrid(columns: cols, spacing: 8) {
                ForEach(quick, id: \.self) { q in
                    Button { text = q } label: {
                        Text(q)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(text == q ? DS.green : DS.text2)
                            .lineLimit(1).minimumScaleFactor(0.75)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10).padding(.horizontal, 8)
                            .background(text == q ? DS.green.opacity(0.12) : DS.panel2,
                                        in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .stroke(text == q ? DS.green.opacity(0.45) : .clear, lineWidth: 1))
                    }.buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(DS.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(DS.border, lineWidth: 1))
    }

    private var sendButton: some View {
        Button {
            Task { await send() }
        } label: {
            HStack(spacing: 7) {
                if sending { ProgressView().tint(.black) }
                else { Image(systemName: sent ? "checkmark" : "paperplane.fill").font(.system(size: 14, weight: .bold)) }
                Text(sent ? "Enviado" : "Enviar pro painel")
                    .font(.system(size: 15, weight: .bold))
            }
            .frame(maxWidth: .infinity).frame(height: 50)
            .foregroundStyle(.black)
            .background(canSend ? DS.green : DS.panel2, in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(canSend ? .black : DS.muted)
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
    }

    private var canSend: Bool {
        !sending && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && carAwake
    }

    private func send() async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        sending = true; errMsg = ""
        let ok = await car.command("/api/message", body: ["text": t, "from": "Rafael"])
        sending = false
        if ok {
            sent = true
            focused = false
            // Fecha depois de mostrar o "Enviado" — feedback antes de sair.
            try? await Task.sleep(nanoseconds: 900_000_000)
            dismiss()
        } else {
            errMsg = "Não foi possível enviar. O carro pode ter dormido."
        }
    }
}
