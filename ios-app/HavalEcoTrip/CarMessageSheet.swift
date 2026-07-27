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
import AVFoundation

/// Gravador do recado de voz. AAC/m4a — o MediaPlayer do carro toca nativamente,
/// então não há conversão em nenhuma ponta. Mono 22kHz é suficiente pra fala e
/// mantém o arquivo pequeno (o bridge recusa acima de 2MB).
@MainActor
final class VoiceRecorder: NSObject, ObservableObject {
    @Published var recording = false
    @Published var seconds = 0
    @Published var hasClip = false
    /// Teto igual ao da página web — recado é curto.
    let maxSeconds = 30

    private var rec: AVAudioRecorder?
    private var timer: Timer?
    private(set) var fileURL: URL?

    func toggle() { if recording { stop() } else { start() } }

    func start() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("recado-\(Int(Date().timeIntervalSince1970)).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 22050,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.record, mode: .default)
            try s.setActive(true)
            rec = try AVAudioRecorder(url: url, settings: settings)
            rec?.record()
            fileURL = url; hasClip = false; seconds = 0; recording = true
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.seconds += 1
                    if self.seconds >= self.maxSeconds { self.stop() }
                }
            }
        } catch {
            recording = false
        }
    }

    func stop() {
        rec?.stop(); rec = nil
        timer?.invalidate(); timer = nil
        recording = false
        hasClip = (fileURL.flatMap { FileManager.default.fileExists(atPath: $0.path) } ?? false)
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    /// Apaga o arquivo e zera — usado após enviar ou ao regravar.
    func reset() {
        stop()
        if let u = fileURL { try? FileManager.default.removeItem(at: u) }
        fileURL = nil; hasClip = false; seconds = 0
    }
}

struct CarMessageSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var car = CarStore.shared
    @State private var text = ""
    @State private var sending = false
    @State private var sent = false
    @State private var errMsg = ""
    @FocusState private var focused: Bool
    @StateObject private var voice = VoiceRecorder()

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
                    voiceCard
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

    /// Recado de voz: no painel o motorista só aperta OUVIR, sem ler nada.
    /// Quando há gravação ela tem prioridade sobre o texto no envio.
    private var voiceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("OU MANDE SUA VOZ").font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(DS.muted).tracking(1)
                Spacer()
                if voice.recording || voice.hasClip {
                    Text("\(voice.seconds)s / \(voice.maxSeconds)s")
                        .font(.system(size: 10.5)).monospacedDigit()
                        .foregroundStyle(voice.recording ? DS.red : DS.teal)
                }
            }
            HStack(spacing: 10) {
                Button { voice.toggle() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: voice.recording ? "stop.fill"
                              : (voice.hasClip ? "arrow.counterclockwise" : "mic.fill"))
                            .font(.system(size: 14, weight: .bold))
                        Text(voice.recording ? "Parar" : (voice.hasClip ? "Regravar" : "Gravar áudio"))
                            .font(.system(size: 14, weight: .bold))
                    }
                    .foregroundStyle(voice.recording ? DS.red : (voice.hasClip ? DS.teal : DS.text))
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(voice.recording ? DS.red.opacity(0.14)
                                : (voice.hasClip ? DS.teal.opacity(0.12) : DS.panel2),
                                in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(
                        voice.recording ? DS.red.opacity(0.45)
                        : (voice.hasClip ? DS.teal.opacity(0.45) : .clear), lineWidth: 1))
                }.buttonStyle(.plain)
                if voice.hasClip && !voice.recording {
                    Button { voice.reset() } label: {
                        Image(systemName: "trash").font(.system(size: 15))
                            .foregroundStyle(DS.muted)
                            .frame(width: 46, height: 46)
                            .background(DS.panel2, in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain)
                }
            }
            if voice.hasClip && !voice.recording {
                Text("O áudio vai no lugar do texto.")
                    .font(.system(size: 10.5)).foregroundStyle(DS.muted)
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
        guard !sending, carAwake, !voice.recording else { return false }
        return voice.hasClip || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() async {
        sending = true; errMsg = ""
        let ok: Bool
        if voice.hasClip, let url = voice.fileURL {
            ok = await sendAudio(url)
        } else {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { sending = false; return }
            ok = await car.command("/api/message", body: ["text": t, "from": "Rafael"])
        }
        sending = false
        if ok {
            sent = true
            focused = false
            voice.reset()
            // Fecha depois de mostrar o "Enviado" — feedback antes de sair.
            try? await Task.sleep(nanoseconds: 900_000_000)
            dismiss()
        } else {
            errMsg = "Não foi possível enviar. O carro pode ter dormido."
        }
    }

    /// POST do m4a cru — mesmo contrato da página do trajeto compartilhado
    /// (corpo binário + ?dur=). Multipart seria peso extra pra um arquivo só.
    private func sendAudio(_ file: URL) async -> Bool {
        guard let data = try? Data(contentsOf: file) else { return false }
        let base = BridgeRouter.shared.currentURL.hasSuffix("/")
            ? String(BridgeRouter.shared.currentURL.dropLast())
            : BridgeRouter.shared.currentURL
        guard let url = URL(string: "\(base)/api/message-audio?dur=\(voice.seconds)&from=Rafael")
        else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 25          // upload em 4G pode demorar
        req.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        req.addValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        do {
            let (_, resp) = try await URLSession.shared.upload(for: req, from: data)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch { return false }
    }
}
