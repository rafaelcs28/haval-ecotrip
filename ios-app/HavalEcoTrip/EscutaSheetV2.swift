//
//  EscutaSheetV2.swift
//  Escuta do carro v2 (design-v2/HANDOFF-escuta.md, Rodada 10 — 10a/10b):
//    10a parado  — tile "Ouvir cabine" + card "Ligar pro carro" + gravações + diag
//    10b ouvindo — timer hero + waveform + Silenciar/Encerrar + promover a chamada
//  Teal é a cor da escuta; green fica reservado pra ação de chamada.
//
import SwiftUI

struct EscutaSheetV2: View {
    @StateObject private var audio = CarAudioSession()
    @StateObject private var diag = MicTestStore()
    @ObservedObject private var store = CarStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var callMessage = "Preciso falar com você."
    @State private var sessionStart = Date()
    @State private var showRecordings = false
    @State private var showDiag = false
    @State private var diagSec = 3

    private var listening: Bool { audio.state == .listening && !audio.callMode }
    private var connecting: Bool { audio.state == .connecting }

    var body: some View {
        sheetV2Presentation(content)
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 16) {
                SheetV2Header(title: "Escuta do carro") {
                    headerChip
                } extra: {
                    EmptyView()
                } onClose: { dismiss() }

                if !store.engineOn && !listening && !audio.callMode {
                    Text("Comandos vão acordar o carro")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(DS.blue)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(DS.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                }

                if audio.callMode {
                    callBody
                } else if listening {
                    listeningBody
                } else {
                    idleBody
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .sheet(isPresented: $showRecordings) { GravacoesV2View() }
        .onAppear {
            #if DEBUG
            let d = UserDefaults.standard
            if d.string(forKey: "escuta_sheet") == "rec" {
                d.removeObject(forKey: "escuta_sheet")
                Task {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    showRecordings = true
                }
            }
            #endif
        }
        .onChange(of: listening) { if listening { sessionStart = Date() } }
        .onDisappear { Task { audio.callMode ? await audio.endCall() : await audio.stop() } }
    }

    @ViewBuilder private var headerChip: some View {
        if audio.callMode {
            StateChip(text: audio.inCall ? "EM CHAMADA" : "CHAMANDO", color: DS.green, icon: "phone.fill")
        } else if listening {
            StateChip(text: audio.reconnecting ? "RECONECTANDO" : "OUVINDO", color: DS.teal, icon: "dot.radiowaves.left.and.right")
        } else if connecting {
            StateChip(text: "Conectando…", color: DS.yellow)
        } else {
            StateChip(text: "Parado", color: DS.muted)
        }
    }

    // MARK: - 10a · Parado

    private var idleBody: some View {
        VStack(spacing: 12) {
            ouvirTile
            ligarCard
            gravacoesLine
            diagLine
        }
    }

    // Tile primário: teal parado, amarelo conectando, red falhou (toque = retry).
    private var ouvirTile: some View {
        let failed: String? = { if case .error(let m) = audio.state { return m }; return nil }()
        let tint: Color = failed != nil ? DS.red : connecting ? DS.yellow : DS.teal
        return Button {
            Task { await audio.start() }
        } label: {
            HStack(spacing: 12) {
                if connecting {
                    ProgressView().tint(DS.yellow).frame(width: 20)
                } else {
                    Image(systemName: failed != nil ? "arrow.clockwise" : "mic.fill")
                        .font(.system(size: 20)).foregroundStyle(tint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(failed != nil ? "Falhou — tentar de novo" : connecting ? "Conectando…" : "Ouvir cabine")
                        .font(.system(size: 13.5, weight: .bold)).foregroundStyle(tint)
                    Text(failed ?? "áudio ao vivo do mic do carro · só você ouve")
                        .font(.system(size: 9.5)).foregroundStyle(DS.text2)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 6)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(tint.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(connecting)
    }

    private var ligarCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "phone.arrow.up.right.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.green)
                    .frame(width: 26, height: 26)
                    .background(DS.green.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Ligar pro carro").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(DS.text)
                    Text("mostra a mensagem na tela e atende sozinho em 10 s")
                        .font(.system(size: 9.5)).foregroundStyle(DS.text2)
                }
                Spacer(minLength: 6)
            }
            HStack(spacing: 8) {
                TextField("Mensagem na tela", text: $callMessage, axis: .vertical)
                    .lineLimit(1...3)
                    .font(.system(size: 12.5)).foregroundStyle(DS.text)
                Image(systemName: "pencil").font(.system(size: 11)).foregroundStyle(DS.muted)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(DS.bg, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.08), lineWidth: 1))
            HStack(spacing: 6) {
                suggestionChip("Me liga quando parar")
                suggestionChip("Tô chegando")
            }
            Button {
                Task { await audio.startCall(message: callMessage.trimmingCharacters(in: .whitespacesAndNewlines)) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "phone.fill").font(.system(size: 12, weight: .bold))
                    Text("Chamar").font(.system(size: 13, weight: .bold))
                }
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(DS.green, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(callMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || connecting)
            if !audio.callStatus.isEmpty && !audio.callMode {
                Text(audio.callStatus).font(.system(size: 10.5)).foregroundStyle(DS.orange)
            }
        }
        .padding(12)
        .background(DS.panel2, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private func suggestionChip(_ text: String) -> some View {
        Button { callMessage = text } label: {
            Text(text)
                .font(.system(size: 10)).foregroundStyle(DS.text2)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(DS.bg, in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.10), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var gravacoesLine: some View {
        Button { showRecordings = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.teal)
                    .frame(width: 26, height: 26)
                    .background(DS.teal.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Gravações da viagem").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(DS.text)
                    Text("grava a cabine localmente · baixa pela LAN")
                        .font(.system(size: 9.5)).foregroundStyle(DS.text2)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(DS.muted)
            }
            .padding(12)
            .background(DS.panel2, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // Linha silenciosa: diagnóstico de captura (expande o teste de nível inline).
    private var diagLine: some View {
        VStack(spacing: 10) {
            Button { withAnimation { showDiag.toggle() } } label: {
                HStack(spacing: 8) {
                    Text("Diagnóstico de captura").font(.system(size: 11)).foregroundStyle(DS.muted)
                    Spacer(minLength: 6)
                    Text("PCM16 mono · 8 kHz").font(.system(size: 10.5)).monospacedDigit().foregroundStyle(DS.text2)
                    Image(systemName: showDiag ? "chevron.up" : "chevron.right")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(DS.muted)
                }
            }
            .buttonStyle(.plain)
            if showDiag {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Grava ~\(diagSec)s por fonte e reporta o nível — confirma se a central liberou o mic.")
                        .font(.system(size: 10.5)).foregroundStyle(DS.muted)
                    Stepper(value: $diagSec, in: 1...10) {
                        HStack {
                            Text("Duração").font(.system(size: 12.5)).foregroundStyle(DS.text)
                            Spacer()
                            Text("\(diagSec)s").font(.system(size: 13, weight: .bold)).monospacedDigit().foregroundStyle(DS.teal)
                        }
                    }
                    Button {
                        Task { await diag.run(sec: diagSec) }
                    } label: {
                        HStack(spacing: 6) {
                            if diag.loading { ProgressView().tint(DS.text2) }
                            else { Image(systemName: "waveform").font(.system(size: 11, weight: .semibold)) }
                            Text("Testar nível").font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(DS.text)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(DS.bg, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.10), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(diag.loading)
                    if let res = diag.result {
                        Text(res).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(DS.text)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let e = diag.error { Text(e).font(.system(size: 10.5)).foregroundStyle(DS.orange) }
                }
                .padding(12)
                .background(DS.panel2, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
        }
    }

    // MARK: - 10b · Ouvindo

    private var listeningBody: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text(sessionStart, style: .timer)
                    .font(.system(size: 64, weight: .ultraLight)).monospacedDigit()
                    .foregroundStyle(DS.text)
                Text(audio.reconnecting ? "reconectando ao mic do carro…" : "conectado ao mic do carro")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(audio.reconnecting ? DS.yellow : DS.teal)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 6)

            waveform

            HStack(spacing: 8) {
                Button {
                    audio.setMuted(!audio.muted)
                } label: {
                    controlTile(audio.muted ? "Silenciado" : "Silenciar",
                                icon: "speaker.slash.fill",
                                tint: audio.muted ? DS.teal : DS.text2,
                                filled: audio.muted)
                }
                .buttonStyle(.plain)
                Button {
                    Task { await audio.stop() }
                } label: {
                    controlTile("Encerrar escuta", icon: "stop.fill", tint: DS.red, filled: true)
                }
                .buttonStyle(.plain)
            }

            talkTile

            Button {
                Task {
                    await audio.stop()
                    await audio.startCall(message: callMessage.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "phone.arrow.up.right.fill")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.green)
                        .frame(width: 26, height: 26)
                        .background(DS.green.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Ligar pro carro").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(DS.text)
                        Text("vira chamada em viva-voz · atende em 10 s")
                            .font(.system(size: 9.5)).foregroundStyle(DS.text2)
                    }
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(DS.muted)
                }
                .padding(12)
                .background(DS.panel2, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
            .buttonStyle(.plain)

            HStack(spacing: 5) {
                Image(systemName: "lock.fill").font(.system(size: 10))
                Text("só você ouve · esta escuta não fica gravada").font(.system(size: 10.5))
            }
            .foregroundStyle(DS.muted)
            .frame(maxWidth: .infinity)
        }
    }

    private func controlTile(_ label: String, icon: String, tint: Color, filled: Bool) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold))
            Text(label).font(.system(size: 11, weight: .bold)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity, minHeight: 56)
        .background(filled ? tint.opacity(0.10) : DS.panel2,
                    in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
            .stroke(filled ? tint.opacity(0.4) : .white.opacity(0.08), lineWidth: 1))
    }

    // Push-to-talk (half-duplex): segura pra abrir o mic do iPhone pro carro.
    private var talkTile: some View {
        VStack(spacing: 4) {
            Image(systemName: audio.talking ? "mic.fill" : "mic")
                .font(.system(size: 18)).foregroundStyle(audio.talking ? DS.orange : DS.muted)
            Text(audio.talking ? "Falando…" : "Segure pra falar")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(audio.talking ? DS.orange : DS.text2)
        }
        .frame(maxWidth: .infinity, minHeight: 56)
        .background(audio.talking ? DS.orange.opacity(0.10) : DS.panel2,
                    in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
            .stroke(audio.talking ? DS.orange.opacity(0.4) : .white.opacity(0.08), lineWidth: 1))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in if !audio.talking { audio.setTalking(true) } }
            .onEnded { _ in audio.setTalking(false) })
    }

    // Waveform h52: barras teal moduladas pelo RMS real (level). Com Reduzir
    // animações: barras estáticas em 3 alturas.
    private var waveform: some View {
        let bars = 26
        return Group {
            if reduceMotion {
                HStack(spacing: 3) {
                    ForEach(0..<bars, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2).fill(DS.teal.opacity(0.6))
                            .frame(width: 3, height: [14, 30, 22][i % 3])
                    }
                }
                .frame(height: 52)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { tl in
                    let t = tl.date.timeIntervalSinceReferenceDate
                    HStack(spacing: 3) {
                        ForEach(0..<bars, id: \.self) { i in
                            let phase = sin(t * 7 + Double(i) * 1.7) * 0.5 + 0.5
                            let h = 6 + (44 * audio.level * (0.35 + 0.65 * phase))
                            RoundedRectangle(cornerRadius: 2)
                                .fill(DS.teal.opacity(0.4 + 0.6 * phase * min(1, audio.level * 3)))
                                .frame(width: 3, height: max(6, h))
                        }
                    }
                    .frame(height: 52)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Chamada ativa

    private var callBody: some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                Image(systemName: audio.inCall ? "phone.fill" : "phone.arrow.up.right.fill")
                    .font(.system(size: 30)).foregroundStyle(audio.inCall ? DS.green : DS.orange)
                Text(audio.callStatus.isEmpty ? "Chamando…" : audio.callStatus)
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.text)
                if audio.inCall {
                    Text("viva-voz aberto nos dois lados")
                        .font(.system(size: 10.5)).foregroundStyle(DS.text2)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)

            if audio.inCall { waveform }

            Button {
                Task { await audio.endCall() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "phone.down.fill").font(.system(size: 12, weight: .bold))
                    Text("Encerrar").font(.system(size: 13, weight: .bold))
                }
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(DS.red, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}
