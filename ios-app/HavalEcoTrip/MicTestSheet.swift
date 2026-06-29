//  MicTestSheet.swift
//  Escuta do carro: ouvir a cabine ao vivo (carro→fone) e push-to-talk (fone→carro)
//  via relay WS. Abaixo, um diagnóstico de captura (nível RMS por audio source) que
//  também revela se RECORD_AUDIO está concedida na central.

import SwiftUI

@MainActor
final class MicTestStore: ObservableObject {
    @Published var loading = false
    @Published var result: String?
    @Published var error: String?

    private var base: String {
        let u = Settings.bridgeURL.isEmpty ? AuthConfig.bridgeURL : Settings.bridgeURL
        return u.hasSuffix("/") ? String(u.dropLast()) : u
    }

    func run(sec: Int) async {
        guard !base.isEmpty, let u = URL(string: "\(base)/api/mic-test") else { error = "Bridge não configurado."; return }
        loading = true; error = nil; result = nil; defer { loading = false }
        var r = URLRequest(url: u); r.httpMethod = "POST"; r.timeoutInterval = 25
        r.addValue("application/json", forHTTPHeaderField: "Content-Type")
        r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["sec": sec])
        do {
            let (d, resp) = try await URLSession.shared.data(for: r)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { error = "Falha (HTTP)."; return }
            let j = try JSONSerialization.jsonObject(with: d) as? [String: Any]
            if let res = j?["result"] as? String { result = res }
            else { result = (j?["note"] as? String) ?? "Sem resposta do carro." }
        } catch { self.error = "Erro de rede: \(error.localizedDescription)" }
    }
}

struct MicTestSheet: View {
    @StateObject private var audio = CarAudioSession()
    @StateObject private var store = MicTestStore()
    @Environment(\.dismiss) private var dismiss
    @State private var sec = 3
    @State private var showDiag = false
    @State private var callMessage = "Preciso falar com você."

    private var listening: Bool { audio.state == .listening }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if audio.callMode {
                        callCard
                    } else {
                        liveCard
                        if listening { talkButton }
                        callLaunchCard
                    }
                    recordingsLink
                    diagSection
                }
                .padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Escuta do carro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fechar") { dismiss() } } }
            .onDisappear { Task { audio.callMode ? await audio.endCall() : await audio.stop() } }
        }
    }

    private var liveCard: some View {
        DSCard {
            VStack(spacing: 12) {
                statusRow
                Button {
                    Task { listening ? await audio.stop() : await audio.start() }
                } label: {
                    HStack(spacing: 8) {
                        if audio.state == .connecting { ProgressView().tint(.white) }
                        else { Image(systemName: listening ? "stop.fill" : "ear.fill") }
                        Text(listening ? "Parar" : "Ouvir cabine").font(.headline)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(listening ? DS.red : DS.teal)
                    .foregroundStyle(.white).clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(audio.state == .connecting)
                if listening { levelMeter }
            }
        }
    }

    // VU meter ao vivo: distingue "mudo" de "cabine quieta". Verde→laranja→vermelho.
    private var levelMeter: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(DS.muted.opacity(0.25))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(audio.level > 0.85 ? DS.red : (audio.level > 0.5 ? DS.orange : DS.green))
                        .frame(width: max(2, geo.size.width * CGFloat(min(audio.level, 1))))
                }
            }
            .frame(height: 8)
            .animation(.linear(duration: 0.1), value: audio.level)
            Text(audio.level < 0.02 ? "Sem som — cabine quieta ou mic mudo (tente aumentar o ganho)" : "Nível do som da cabine")
                .font(.caption2).foregroundStyle(DS.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Circle().fill(listening ? DS.green : DS.muted).frame(width: 8, height: 8)
            Text(statusText).font(.callout).foregroundStyle(DS.text)
            Spacer()
        }
    }

    private var statusText: String {
        switch audio.state {
        case .idle: return "Parado"
        case .connecting: return "Conectando…"
        case .listening:
            if audio.reconnecting { return "Reconectando…" }
            return audio.talking ? "Falando…" : "Ouvindo a cabine"
        case .error(let m): return m
        }
    }

    private var talkButton: some View {
        DSCard {
            VStack(spacing: 8) {
                Image(systemName: audio.talking ? "mic.fill" : "mic")
                    .font(.system(size: 28)).foregroundStyle(audio.talking ? DS.orange : DS.muted)
                Text("Segure pra falar").font(.callout).foregroundStyle(DS.text)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 18)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !audio.talking { audio.setTalking(true) } }
                .onEnded { _ in audio.setTalking(false) })
        }
    }

    // Disparar a chamada: mensagem que aparece na tela do carro + botão. O carro
    // toca a tela e auto-aceita em 10s; daí vira full-duplex.
    private var callLaunchCard: some View {
        DSCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "phone.arrow.up.right.fill")
                        .font(.title2).foregroundStyle(DS.teal)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ligar pro carro").font(.callout.weight(.semibold)).foregroundStyle(DS.text)
                        Text("Mostra a mensagem na tela e atende sozinho em 10s").font(.caption).foregroundStyle(DS.muted)
                    }
                    Spacer()
                }
                TextField("Mensagem na tela", text: $callMessage, axis: .vertical)
                    .lineLimit(1...3)
                    .padding(10)
                    .background(DS.muted.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(DS.text)
                Button {
                    Task { await audio.startCall(message: callMessage.trimmingCharacters(in: .whitespacesAndNewlines)) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "phone.fill")
                        Text("Chamar").font(.headline)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(DS.green).foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(callMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    // Chamada em curso: status (Chamando…/Em chamada) + VU meter + encerrar.
    private var callCard: some View {
        DSCard {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: audio.inCall ? "phone.fill" : "phone.arrow.up.right.fill")
                        .font(.title2).foregroundStyle(audio.inCall ? DS.green : DS.orange)
                    Text(audio.callStatus.isEmpty ? "Chamando…" : audio.callStatus)
                        .font(.callout.weight(.semibold)).foregroundStyle(DS.text)
                    Spacer()
                }
                if audio.inCall { levelMeter }
                Button {
                    Task { await audio.endCall() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "phone.down.fill")
                        Text("Encerrar").font(.headline)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(DS.red).foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
        }
    }

    private var recordingsLink: some View {
        DSCard {
            NavigationLink {
                RecordingsView()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.title2).foregroundStyle(DS.teal)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Gravações da viagem").font(.callout.weight(.semibold)).foregroundStyle(DS.text)
                        Text("Grava a cabine localmente · baixa pela LAN").font(.caption).foregroundStyle(DS.muted)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(DS.muted)
                }
            }
        }
    }

    private var diagSection: some View {
        DSCard {
            VStack(alignment: .leading, spacing: 12) {
                Button { withAnimation { showDiag.toggle() } } label: {
                    HStack {
                        Text("Diagnóstico de captura").font(.callout.weight(.semibold)).foregroundStyle(DS.text)
                        Spacer()
                        Image(systemName: showDiag ? "chevron.up" : "chevron.down").foregroundStyle(DS.muted)
                    }
                }
                if showDiag {
                    Text("Grava ~\(sec)s por fonte e reporta o nível — confirma se a central liberou o mic.")
                        .font(.caption).foregroundStyle(DS.muted)
                    Stepper(value: $sec, in: 1...10) {
                        HStack { Text("Duração").foregroundStyle(DS.text); Spacer(); Text("\(sec)s").font(.headline).foregroundStyle(DS.teal) }
                    }
                    DSActionButton(icon: "waveform", title: "Testar nível", color: DS.muted, busy: store.loading) {
                        Task { await store.run(sec: sec) }
                    }
                    if let res = store.result {
                        Text(res).font(.system(.caption, design: .monospaced)).foregroundStyle(DS.text)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let e = store.error { Text(e).font(.caption).foregroundStyle(DS.orange) }
                }
            }
        }
    }
}
