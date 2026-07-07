//
//  GravacoesV2View.swift
//  Gravações v2 — HANDOFF-gravacoes-preclima.md, frames 11a (parado) / 11b (gravando).
//  Reusa RecordingsStore (controle via bridge→MQTT, download LAN c/ fallback bridge).
//  V1 (RecordingsView) permanece intacta; troca via flag ui_v2.
//

import SwiftUI

struct GravacoesV2View: View {
    @StateObject private var store = RecordingsStore()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 16) {
                    if let e = store.error {
                        Text(e).font(.system(size: 11)).foregroundStyle(DS.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if store.recording { recordingBody } else { idleBody }
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
            }
            .scrollIndicators(.hidden)
            .refreshable { await store.refresh() }
        }
        .background(DS.bg.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear { store.onAppear() }
        .onDisappear { store.onDisappear() }
        .sheet(item: $store.shareFile) { sf in ActivityView(items: [sf.url]) }
    }

    // MARK: header — back ‹ Escuta + chip

    private var header: some View {
        HStack(spacing: 8) {
            Button { dismiss() } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .bold))
                    Text("Escuta").font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(DS.teal)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
            Text("Gravações").font(.system(size: 16, weight: .bold)).foregroundStyle(DS.text)
            Spacer(minLength: 8)
            if store.recording {
                StateChip(text: "GRAVANDO", color: DS.teal, icon: "record.circle")
            } else {
                StateChip(text: "Parada", color: DS.muted)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
    }

    // MARK: - 11a · parado

    private var idleBody: some View {
        VStack(spacing: 14) {
            gravarTile
            sessoes
            gravacaoGroup
            Text(store.lanReady
                 ? "na rede do carro — download rápido pela LAN"
                 : "fora da rede do carro, o download vai pelo bridge · pode levar ~1 min")
                .font(.system(size: 10.5)).foregroundStyle(DS.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    private var gravarTile: some View {
        let tint: Color = store.busy ? DS.yellow : DS.teal
        return Button {
            Task { await store.toggleRecording() }
        } label: {
            HStack(spacing: 12) {
                if store.busy {
                    ProgressView().tint(DS.yellow).frame(width: 20)
                } else {
                    Image(systemName: "record.circle").font(.system(size: 20)).foregroundStyle(tint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.busy ? "Iniciando…" : "Gravar viagem")
                        .font(.system(size: 13.5, weight: .bold)).foregroundStyle(tint)
                    Text("o áudio fica no carro · baixa pela LAN depois")
                        .font(.system(size: 9.5)).foregroundStyle(DS.text2)
                }
                Spacer(minLength: 6)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(tint.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(store.busy)
    }

    // MARK: sessões

    private var totalMB: String { fmtMB(store.sessions.reduce(0) { $0 + $1.bytes }) }

    private var sessoes: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SESSÕES")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(DS.muted).tracking(1.2)
                Spacer()
                if !store.sessions.isEmpty {
                    Text("\(store.sessions.count) no carro · \(totalMB)")
                        .font(.system(size: 10)).monospacedDigit().foregroundStyle(DS.text2)
                }
            }
            if store.sessions.isEmpty {
                Text("Nenhuma gravação ainda.")
                    .font(.system(size: 11.5)).foregroundStyle(DS.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(13)
                    .background(DS.panel2, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    ForEach(store.sessions) { s in
                        sessionRow(s)
                        if s.id != store.sessions.last?.id { Divider().overlay(DS.divider) }
                    }
                }
                .background(DS.panel2, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
        }
    }

    private func sessionRow(_ s: RecSession) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.teal)
                    .frame(width: 26, height: 26)
                    .background(DS.teal.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(dayLabel(s.date)).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(DS.text)
                    Text("\(fmtDur(s.durationMs)) · \(fmtMB(s.bytes))")
                        .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(DS.text2)
                }
                Spacer(minLength: 6)
                if store.downloadingId == s.id || store.sharingId == s.id {
                    downloadChip
                } else {
                    Button { Task { await store.share(s) } } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 14)).foregroundStyle(DS.text2)
                            .frame(width: 30, height: 30).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if store.playingId == s.id {
                        Image(systemName: "speaker.wave.2.fill").font(.system(size: 14)).foregroundStyle(DS.teal)
                            .frame(width: 30, height: 30)
                    } else {
                        Button { Task { await store.play(s) } } label: {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 20)).foregroundStyle(DS.teal)
                                .frame(width: 30, height: 30).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if store.playingId == s.id { playerPanel }
        }
        .padding(.horizontal, 13).padding(.vertical, 10)
    }

    private var downloadChip: some View {
        HStack(spacing: 5) {
            ProgressView().controlSize(.mini).tint(DS.yellow)
            Text(store.downloadProgress >= 0
                 ? "baixando · \(Int((store.downloadProgress * 100).rounded()))%"
                 : "baixando…")
                .font(.system(size: 10, weight: .bold)).monospacedDigit().foregroundStyle(DS.yellow)
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(DS.yellow.opacity(0.12), in: Capsule())
    }

    // Tocador: scrubber + ±15s + play/pause + stop.
    private var playerPanel: some View {
        VStack(spacing: 5) {
            Slider(value: Binding(get: { store.playTime }, set: { store.seek(to: $0) }),
                   in: 0...max(store.playDuration, 0.1))
                .tint(DS.teal)
            HStack {
                Text(fmtTime(store.playTime)).font(.system(size: 9.5)).monospacedDigit().foregroundStyle(DS.muted)
                Spacer()
                Text(fmtTime(store.playDuration)).font(.system(size: 9.5)).monospacedDigit().foregroundStyle(DS.muted)
            }
            HStack(spacing: 26) {
                Button { store.skip(-15) } label: {
                    Image(systemName: "gobackward.15").font(.system(size: 17)).foregroundStyle(DS.text)
                }
                Button { store.togglePause() } label: {
                    Image(systemName: store.paused ? "play.circle.fill" : "pause.circle.fill")
                        .font(.system(size: 30)).foregroundStyle(DS.teal)
                }
                Button { store.skip(15) } label: {
                    Image(systemName: "goforward.15").font(.system(size: 17)).foregroundStyle(DS.text)
                }
                Button { store.stopPlayback() } label: {
                    Image(systemName: "stop.circle.fill").font(.system(size: 20)).foregroundStyle(DS.red)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 2)
    }

    // MARK: grupo GRAVAÇÃO

    private static let gainSteps: [Double] = [0.5, 1, 1.5, 2, 3, 4, 6, 8, 12, 16]

    private func stepGain(_ dir: Int) {
        let idx = Self.gainSteps.firstIndex { $0 >= store.gain - 0.001 } ?? 1
        let next = max(0, min(Self.gainSteps.count - 1, idx + dir))
        Task { await store.setGain(Self.gainSteps[next]) }
    }

    private var gravacaoGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("GRAVAÇÃO")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(DS.muted).tracking(1.2)
                Spacer()
                if store.settingsBusy || store.gainBusy { ProgressView().controlSize(.mini) }
            }
            VStack(spacing: 0) {
                settingRow("Gravação automática", "grava sozinha toda vez que o carro liga") {
                    Toggle("", isOn: Binding(get: { store.autoRecord },
                                             set: { v in Task { await store.setAutoRecord(v) } }))
                        .labelsHidden().tint(DS.teal)
                }
                Divider().overlay(DS.divider)
                settingRow("Minutos por arquivo", "grava em blocos; ao atingir, abre um novo") {
                    StepperPillV2(value: "\(store.segMin) min",
                                  dec: { Task { await store.setSegMin(store.segMin - 1) } },
                                  inc: { Task { await store.setSegMin(store.segMin + 1) } })
                }
                Divider().overlay(DS.divider)
                settingRow("Ganho automático (AGC)", "nivela o volume sozinho · pode \"respirar\" em silêncio") {
                    Toggle("", isOn: Binding(get: { store.agc },
                                             set: { v in Task { await store.setAgc(v) } }))
                        .labelsHidden().tint(DS.teal)
                }
                Divider().overlay(DS.divider)
                settingRow("Ganho do microfone", "multiplica o sinal captado · ×1 = neutro") {
                    StepperPillV2(value: String(format: "×%g", store.gain),
                                  dec: { stepGain(-1) }, inc: { stepGain(1) })
                }
            }
            .background(DS.panel2, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
    }

    private func settingRow(_ title: String, _ sub: String, @ViewBuilder control: () -> some View) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(DS.text)
                Text(sub).font(.system(size: 9.5)).foregroundStyle(DS.text2)
                    .lineLimit(2).minimumScaleFactor(0.85)
            }
            Spacer(minLength: 8)
            control()
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
    }

    // MARK: - 11b · gravando

    private var currentSession: RecSession? {
        store.currentId.flatMap { id in store.sessions.first { $0.id == id } }
    }

    private var recordingBody: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                if let cur = currentSession {
                    Text(cur.date, style: .timer)
                        .font(.system(size: 64, weight: .ultraLight)).monospacedDigit()
                        .foregroundStyle(DS.text)
                } else {
                    Text("gravando")
                        .font(.system(size: 40, weight: .ultraLight)).foregroundStyle(DS.text)
                }
                Text("gravando · o áudio fica no carro")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(DS.teal)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 6)

            recWaveform

            HStack(spacing: 8) {
                miniMetric("SESSÕES", "\(store.sessions.count)")
                miniMetric("NO CARRO", totalMB)
                miniMetric("REDE", store.lanReady ? "LAN" : "bridge")
            }

            Button {
                Task { await store.toggleRecording() }
            } label: {
                HStack(spacing: 6) {
                    if store.busy { ProgressView().tint(DS.red) }
                    else { Image(systemName: "stop.fill").font(.system(size: 13, weight: .bold)) }
                    Text("Parar gravação").font(.system(size: 13, weight: .bold))
                }
                .foregroundStyle(DS.red)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(DS.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(DS.red.opacity(0.4), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(store.busy)

            Text("ao parar, a sessão entra na lista · baixa pela LAN")
                .font(.system(size: 10.5)).foregroundStyle(DS.muted)
                .frame(maxWidth: .infinity)
            HStack(spacing: 5) {
                Image(systemName: "person.2.fill").font(.system(size: 10))
                Text("gravação avisada aos ocupantes no head-unit").font(.system(size: 10.5))
            }
            .foregroundStyle(DS.muted)
            .frame(maxWidth: .infinity)
        }
    }

    private func miniMetric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 8.5, weight: .bold)).foregroundStyle(DS.muted).tracking(0.8)
            Text(value).font(.system(size: 15, weight: .bold, design: .rounded))
                .monospacedDigit().foregroundStyle(DS.text)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(DS.panel2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // Sem nível remoto do mic durante a gravação — animação suave fixa.
    private var recWaveform: some View {
        let bars = 26
        return Group {
            if reduceMotion {
                HStack(spacing: 3) {
                    ForEach(0..<bars, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2).fill(DS.teal.opacity(0.6))
                            .frame(width: 3, height: [14, 30, 22][i % 3])
                    }
                }
                .frame(height: 46)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { tl in
                    let t = tl.date.timeIntervalSinceReferenceDate
                    HStack(spacing: 3) {
                        ForEach(0..<bars, id: \.self) { i in
                            let phase = sin(t * 4 + Double(i) * 1.7) * 0.5 + 0.5
                            RoundedRectangle(cornerRadius: 2)
                                .fill(DS.teal.opacity(0.35 + 0.55 * phase))
                                .frame(width: 3, height: 8 + 30 * phase)
                        }
                    }
                    .frame(height: 46)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: fmt

    private func dayLabel(_ d: Date) -> String {
        let c = Calendar.current
        let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR")
        if c.isDateInToday(d) { f.dateFormat = "HH:mm"; return "Hoje " + f.string(from: d) }
        if c.isDateInYesterday(d) { f.dateFormat = "HH:mm"; return "Ontem " + f.string(from: d) }
        f.dateFormat = "dd/MM HH:mm"; return f.string(from: d)
    }
    private func fmtDur(_ ms: Double) -> String {
        let s = Int(ms / 1000); return s >= 60 ? "\(s / 60) min" : "\(s)s"
    }
    private func fmtTime(_ secs: Double) -> String {
        let s = Int(secs.rounded()); return String(format: "%d:%02d", s / 60, s % 60)
    }
    private func fmtMB(_ b: Double) -> String {
        b >= 1_048_576 ? String(format: "%.0f MB", b / 1_048_576) : String(format: "%.0f KB", b / 1024)
    }
}
