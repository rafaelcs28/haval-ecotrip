//  RecordingsView.swift
//  Gravações de cabine por viagem. Controle manual: liga/desliga a gravação na
//  central (via bridge → MQTT). O áudio fica LOCAL no carro; o download é sob
//  demanda — LAN direto (APK /api/rec/file/<id>) com fallback de listagem pelo
//  bridge. Toca o WAV baixado com AVAudioPlayer.

import SwiftUI
import AVFoundation
import UIKit

// Reporta progresso de download (didWriteData). O método async download(for:delegate:)
// move o arquivo sozinho; só usamos o delegate pra acompanhar o %.
final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    private let onProgress: (Double) -> Void
    init(_ cb: @escaping (Double) -> Void) { onProgress = cb }
    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let p = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : -1
        onProgress(p)
    }
    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}

// Share sheet do sistema (e-mail, WhatsApp, AirDrop, Salvar em Arquivos…).
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct RecSession: Identifiable {
    let id: String
    let startMs: Double
    let durationMs: Double
    let bytes: Double
    var date: Date { Date(timeIntervalSince1970: startMs / 1000) }
}

// Arquivo pronto pra compartilhar (share sheet). Identifiable p/ .sheet(item:).
struct ShareFile: Identifiable {
    let id = UUID()
    let url: URL
}

@MainActor
final class RecordingsStore: NSObject, ObservableObject {
    @Published var sessions: [RecSession] = []
    @Published var recording = false
    @Published var currentId: String?
    @Published var busy = false
    @Published var error: String?
    @Published var lanReady = false
    @Published var playingId: String?
    @Published var downloadingId: String?
    @Published var sharingId: String?
    @Published var shareFile: ShareFile?
    @Published var downloadProgress: Double = -1   // 0…1; -1 = indeterminado (sem Content-Length)
    @Published var gain: Double = 1.0
    @Published var gainBusy = false
    @Published var autoRecord = false
    @Published var agc = false
    @Published var segMin: Int = 5
    @Published var settingsBusy = false
    // Estado do tocador (estilo player de música)
    @Published var paused = false
    @Published var playTime: Double = 0      // segundos decorridos
    @Published var playDuration: Double = 0  // segundos totais

    private let lan = LANDiscovery()
    private var lanHostPort: (String, Int)?
    private var player: AVAudioPlayer?
    private var ticker: Task<Void, Never>?

    private var base: String {
        let u = Settings.bridgeURL.isEmpty ? AuthConfig.bridgeURL : Settings.bridgeURL
        return u.hasSuffix("/") ? String(u.dropLast()) : u
    }

    func onAppear() {
        lan.onResolve = { [weak self] hp in
            Task { @MainActor in
                self?.lanHostPort = hp
                self?.lanReady = hp != nil
            }
        }
        lan.start()
        Task { await refresh() }
        Task { await loadGain() }
        Task { await loadSettings() }
    }

    // ── Config da gravação (auto-record, AGC, minutos/arquivo) via bridge ──────
    private func getResult(_ path: String) async -> String? {
        guard let u = URL(string: base + path) else { return nil }
        var r = URLRequest(url: u); r.timeoutInterval = 8
        r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        guard let (d, resp) = try? await URLSession.shared.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return j["result"] as? String
    }

    private func postResult(_ path: String, _ body: [String: Any]) async -> String? {
        guard let u = URL(string: base + path) else { return nil }
        var r = URLRequest(url: u); r.httpMethod = "POST"; r.timeoutInterval = 10
        r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        r.addValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (d, resp) = try? await URLSession.shared.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return j["result"] as? String
    }

    func loadSettings() async {
        if let s = await getResult("/api/rec/auto") { autoRecord = s.hasSuffix("true") }
        if let s = await getResult("/api/rec/agc")  { agc = s.hasSuffix("true") }
        if let s = await getResult("/api/rec/segment"), let n = Int(s.dropFirst(3).trimmingCharacters(in: .whitespaces)) { segMin = n }
    }

    func setAutoRecord(_ on: Bool) async {
        settingsBusy = true; defer { settingsBusy = false }
        autoRecord = on
        if let s = await postResult("/api/rec/auto", ["enabled": on]) { autoRecord = s.hasSuffix("true") }
        else { error = "Falha ao mudar gravação automática." }
    }

    func setAgc(_ on: Bool) async {
        settingsBusy = true; defer { settingsBusy = false }
        agc = on
        if let s = await postResult("/api/rec/agc", ["enabled": on]) { agc = s.hasSuffix("true") }
        else { error = "Falha ao mudar AGC." }
    }

    func setSegMin(_ m: Int) async {
        settingsBusy = true; defer { settingsBusy = false }
        let clamped = max(1, min(60, m))
        segMin = clamped
        if let s = await postResult("/api/rec/segment", ["min": clamped]),
           let n = Int(s.dropFirst(3).trimmingCharacters(in: .whitespaces)) { segMin = n }
        else { error = "Falha ao mudar a duração." }
    }

    // ── Ganho do mic (via bridge → MQTT). Resultado vem como "ok:<float>". ─────
    private func parseGain(_ res: String) -> Double? {
        guard res.hasPrefix("ok:") else { return nil }
        return Double(res.dropFirst(3).trimmingCharacters(in: .whitespaces))
    }

    func loadGain() async {
        guard let u = URL(string: base + "/api/rec/gain") else { return }
        var r = URLRequest(url: u); r.timeoutInterval = 8
        r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        do {
            let (d, resp) = try await URLSession.shared.data(for: r)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
            let j = try JSONSerialization.jsonObject(with: d) as? [String: Any]
            if let g = parseGain((j?["result"] as? String) ?? "") { gain = g }
        } catch {}
    }

    func setGain(_ g: Double) async {
        gainBusy = true; defer { gainBusy = false }
        gain = g   // otimista
        guard let u = URL(string: base + "/api/rec/gain") else { return }
        var r = URLRequest(url: u); r.httpMethod = "POST"; r.timeoutInterval = 10
        r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        r.addValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["gain": g])
        do {
            let (d, resp) = try await URLSession.shared.data(for: r)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { self.error = "Falha ao ajustar ganho."; return }
            let j = try JSONSerialization.jsonObject(with: d) as? [String: Any]
            if let eff = parseGain((j?["result"] as? String) ?? "") { gain = eff }   // valor efetivo (clampado no carro)
        } catch { self.error = "Erro de rede: \(error.localizedDescription)" }
    }

    func onDisappear() { lan.stop(); stopPlayback() }

    // ── Controle da gravação (sempre via bridge → MQTT) ───────────────────────
    func toggleRecording() async {
        busy = true; error = nil; defer { busy = false }
        let path = recording ? "/api/rec/stop" : "/api/rec/start"
        guard let u = URL(string: base + path) else { error = "Bridge não configurado."; return }
        var r = URLRequest(url: u); r.httpMethod = "POST"; r.timeoutInterval = 12
        r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        do {
            let (d, resp) = try await URLSession.shared.data(for: r)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { error = "Falha (HTTP)."; return }
            let j = try JSONSerialization.jsonObject(with: d) as? [String: Any]
            let res = (j?["result"] as? String) ?? ""
            let note = (j?["note"] as? String) ?? ""
            if res.hasPrefix("error") { error = res; return }
            if res == "" {
                error = note.contains("offline") ? "Carro offline — app do carro sem conexão MQTT." : "Sem resposta do carro (timeout)."
                return
            }
            recording.toggle()
            try? await Task.sleep(nanoseconds: 400_000_000)
            await refresh()
        } catch { self.error = "Erro de rede: \(error.localizedDescription)" }
    }

    // ── Listagem: LAN direto se disponível, senão bridge ──────────────────────
    func refresh() async {
        error = nil
        if let (host, port) = lanHostPort,
           let u = URL(string: "http://\(host):\(port)/api/rec/list") {
            if await load(from: u, viaBridge: false) { return }
        }
        guard let u = URL(string: base + "/api/rec/list") else { return }
        _ = await load(from: u, viaBridge: true)
    }

    private func load(from url: URL, viaBridge: Bool) async -> Bool {
        var r = URLRequest(url: url); r.timeoutInterval = 8
        if viaBridge { r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization") }
        do {
            let (d, resp) = try await URLSession.shared.data(for: r)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return false }
            // bridge embrulha em {result:"<json>"}; LAN devolve o JSON direto.
            var payload: [String: Any]?
            if viaBridge,
               let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let s = j["result"] as? String,
               let inner = s.data(using: .utf8) {
                payload = try? JSONSerialization.jsonObject(with: inner) as? [String: Any]
            } else {
                payload = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
            }
            guard let p = payload else { return false }
            recording = (p["recording"] as? Bool) ?? false
            currentId = p["currentId"] as? String
            let arr = (p["sessions"] as? [[String: Any]]) ?? []
            sessions = arr.compactMap { o in
                guard let id = o["id"] as? String else { return nil }
                return RecSession(
                    id: id,
                    startMs: (o["startMs"] as? Double) ?? 0,
                    durationMs: (o["durationMs"] as? Double) ?? 0,
                    bytes: (o["bytes"] as? Double) ?? 0)
            }
            return true
        } catch { return false }
    }

    // ── Download (LAN direto → fallback bridge). Retorna o arquivo local. ─────
    // filename: nome amigável p/ o destino (usado no share). Sem auth na LAN.
    private func fetchToFile(_ s: RecSession, filename: String) async -> URL? {
        downloadProgress = 0; defer { downloadProgress = -1 }
        if let (host, port) = lanHostPort,
           let u = URL(string: "http://\(host):\(port)/api/rec/file/\(s.id)") {
            if let f = await download(u, viaBridge: false, filename: filename) { return f }
        }
        guard let u = URL(string: base + "/api/rec/file/\(s.id)") else {
            error = "Bridge não configurado."; return nil
        }
        return await download(u, viaBridge: true, filename: filename)
    }

    private func download(_ url: URL, viaBridge: Bool, filename: String) async -> URL? {
        var r = URLRequest(url: url)
        r.timeoutInterval = viaBridge ? 100 : 20
        if viaBridge { r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization") }
        let del = DownloadProgressDelegate { p in
            Task { @MainActor [weak self] in self?.downloadProgress = p }
        }
        do {
            let (tmp, resp) = try await URLSession.shared.download(for: r, delegate: del)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                if viaBridge { error = "Carro offline — não enviou o arquivo." }
                return nil
            }
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            return dest
        } catch {
            if viaBridge { self.error = "Falha no download: \(error.localizedDescription)" }
            return nil
        }
    }

    // ── Play: baixa e toca ────────────────────────────────────────────────────
    func play(_ s: RecSession) async {
        error = nil
        downloadingId = s.id; defer { downloadingId = nil }
        guard let dest = await fetchToFile(s, filename: "\(s.id).wav") else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(contentsOf: dest)
            p.delegate = self
            player = p
            playingId = s.id
            paused = false
            playDuration = p.duration
            playTime = 0
            p.play()
            startTicker()
        } catch { self.error = "Não consegui tocar: \(error.localizedDescription)" }
    }

    // ── Share: baixa, comprime pra m4a (AAC) e abre o share sheet ─────────────
    func share(_ s: RecSession) async {
        error = nil
        sharingId = s.id; defer { sharingId = nil }
        let base = "Cabine_" + Self.fileDF.string(from: s.date)
        guard let wav = await fetchToFile(s, filename: base + ".wav") else { return }
        // m4a é ~10x menor e abre em qualquer app/e-mail/WhatsApp. Fallback: WAV.
        if let m4a = await compressToM4A(wav, name: base + ".m4a") {
            shareFile = ShareFile(url: m4a)
        } else {
            shareFile = ShareFile(url: wav)
        }
    }

    private func compressToM4A(_ wav: URL, name: String) async -> URL? {
        let asset = AVURLAsset(url: wav)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: out)
        export.outputURL = out
        export.outputFileType = .m4a
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { cont.resume() }
        }
        return export.status == .completed ? out : nil
    }

    private static let fileDF: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "dd-MM-yyyy_HH'h'mm"; return f
    }()

    // ── Controles do tocador ──────────────────────────────────────────────────
    func togglePause() {
        guard let p = player else { return }
        if p.isPlaying { p.pause(); paused = true }
        else { p.play(); paused = false; startTicker() }
    }

    func seek(to t: Double) {
        guard let p = player else { return }
        p.currentTime = max(0, min(t, p.duration))
        playTime = p.currentTime
    }

    func skip(_ delta: Double) {
        guard let p = player else { return }
        seek(to: p.currentTime + delta)
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self, let p = self.player, p.isPlaying else { continue }
                self.playTime = p.currentTime
            }
        }
    }

    func stopPlayback() {
        ticker?.cancel(); ticker = nil
        player?.stop(); player = nil
        playingId = nil; paused = false; playTime = 0; playDuration = 0
    }
}

extension RecordingsStore: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stopPlayback() }
    }
}

struct RecordingsView: View {
    @StateObject private var store = RecordingsStore()

    private static let df: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "dd/MM HH:mm"; return f
    }()

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                recordCard
                settingsCard
                gainCard
                if let e = store.error {
                    Text(e).font(.caption).foregroundStyle(DS.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                listCard
            }
            .padding(16)
        }
        .background(DS.bg.ignoresSafeArea())
        .navigationTitle("Gravações")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.onAppear() }
        .onDisappear { store.onDisappear() }
        .refreshable { await store.refresh() }
        .sheet(item: $store.shareFile) { sf in ActivityView(items: [sf.url]) }
    }

    private var recordCard: some View {
        DSCard {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Circle().fill(store.recording ? DS.red : DS.muted)
                        .frame(width: 8, height: 8)
                    Text(store.recording ? "Gravando a cabine…" : "Gravação parada")
                        .font(.callout).foregroundStyle(DS.text)
                    Spacer()
                    Image(systemName: store.lanReady ? "wifi" : "wifi.slash")
                        .font(.caption).foregroundStyle(store.lanReady ? DS.green : DS.muted)
                }
                Button {
                    Task { await store.toggleRecording() }
                } label: {
                    HStack(spacing: 8) {
                        if store.busy { ProgressView().tint(.white) }
                        else { Image(systemName: store.recording ? "stop.fill" : "record.circle") }
                        Text(store.recording ? "Parar gravação" : "Gravar viagem").font(.headline)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(store.recording ? DS.red : DS.teal)
                    .foregroundStyle(.white).clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(store.busy)
                Text(store.lanReady
                     ? "Áudio fica no carro. Download rápido na mesma rede (LAN)."
                     : "Áudio fica no carro. Fora da rede, baixa pelo bridge (pode levar ~1 min).")
                    .font(.caption).foregroundStyle(DS.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var settingsCard: some View {
        DSCard {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape.fill").font(.caption).foregroundStyle(DS.teal)
                    Text("Gravação").font(.callout).foregroundStyle(DS.text)
                    Spacer()
                    if store.settingsBusy { ProgressView() }
                }
                Toggle(isOn: Binding(get: { store.autoRecord },
                                     set: { v in Task { await store.setAutoRecord(v) } })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Gravação automática").font(.callout).foregroundStyle(DS.text)
                        Text("Grava sozinha toda vez que o carro liga.")
                            .font(.caption2).foregroundStyle(DS.muted)
                    }
                }.tint(DS.teal)
                Divider().overlay(DS.muted.opacity(0.2))
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Minutos por arquivo").font(.callout).foregroundStyle(DS.text)
                        Text("Grava em blocos; ao atingir, abre um novo.")
                            .font(.caption2).foregroundStyle(DS.muted)
                    }
                    Spacer()
                    Stepper(value: Binding(get: { store.segMin },
                                           set: { v in Task { await store.setSegMin(v) } }),
                            in: 1...60) {
                        Text("\(store.segMin) min").font(.headline).foregroundStyle(DS.teal).frame(minWidth: 56)
                    }.labelsHidden().fixedSize()
                    Text("\(store.segMin) min").font(.headline).foregroundStyle(DS.teal)
                        .frame(minWidth: 54, alignment: .trailing)
                }
                Divider().overlay(DS.muted.opacity(0.2))
                Toggle(isOn: Binding(get: { store.agc },
                                     set: { v in Task { await store.setAgc(v) } })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Ganho automático (AGC)").font(.callout).foregroundStyle(DS.text)
                        Text("Nivela o volume sozinho. Pode 'respirar' em silêncio.")
                            .font(.caption2).foregroundStyle(DS.muted)
                    }
                }.tint(DS.teal)
            }
        }
    }

    // Passos de ganho (×). Mic da cabine é baixo; ajusta aqui sem ir no carro.
    private static let gainSteps: [Double] = [0.5, 1, 1.5, 2, 3, 4, 6, 8, 12, 16]

    private func stepGain(_ dir: Int) {
        let cur = store.gain
        let idx = Self.gainSteps.firstIndex { $0 >= cur - 0.001 } ?? 1
        let next = max(0, min(Self.gainSteps.count - 1, idx + dir))
        Task { await store.setGain(Self.gainSteps[next]) }
    }

    private var gainCard: some View {
        DSCard {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "mic.fill").font(.caption).foregroundStyle(DS.teal)
                    Text("Ganho do microfone").font(.callout).foregroundStyle(DS.text)
                    Spacer()
                    if store.gainBusy { ProgressView() }
                }
                HStack(spacing: 16) {
                    Button { stepGain(-1) } label: {
                        Image(systemName: "minus.circle.fill").font(.title)
                            .foregroundStyle(store.gain <= Self.gainSteps.first! ? DS.muted : DS.teal)
                    }.disabled(store.gainBusy || store.gain <= Self.gainSteps.first!)
                    Text(String(format: "×%g", store.gain))
                        .font(.title2.weight(.semibold)).foregroundStyle(DS.text)
                        .frame(minWidth: 70)
                    Button { stepGain(1) } label: {
                        Image(systemName: "plus.circle.fill").font(.title)
                            .foregroundStyle(store.gain >= Self.gainSteps.last! ? DS.muted : DS.teal)
                    }.disabled(store.gainBusy || store.gain >= Self.gainSteps.last!)
                }
                Text("Multiplica o sinal captado (escuta ao vivo e gravação). ×1 = neutro.")
                    .font(.caption).foregroundStyle(DS.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var listCard: some View {
        DSCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Sessões").font(.callout.weight(.semibold)).foregroundStyle(DS.text)
                if store.sessions.isEmpty {
                    Text("Nenhuma gravação ainda.").font(.caption).foregroundStyle(DS.muted)
                } else {
                    ForEach(store.sessions) { s in
                        sessionRow(s)
                        if s.id != store.sessions.last?.id { Divider().overlay(DS.muted.opacity(0.2)) }
                    }
                }
            }
        }
    }

    private func sessionRow(_ s: RecSession) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.df.string(from: s.date)).font(.callout).foregroundStyle(DS.text)
                    Text("\(fmtDur(s.durationMs)) · \(fmtMB(s.bytes))")
                        .font(.caption).foregroundStyle(DS.muted)
                }
                Spacer()
                // Download / compartilhar (e-mail, WhatsApp, outro app)
                if store.sharingId == s.id {
                    ProgressView()
                } else {
                    Button { Task { await store.share(s) } } label: {
                        Image(systemName: "square.and.arrow.up").font(.title3).foregroundStyle(DS.teal)
                    }
                }
                // Play (o controle completo aparece no painel abaixo quando tocando)
                if store.downloadingId == s.id {
                    ProgressView()
                } else if store.playingId == s.id {
                    Image(systemName: "speaker.wave.2.fill").font(.title3).foregroundStyle(DS.teal)
                } else {
                    Button { Task { await store.play(s) } } label: {
                        Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(DS.teal)
                    }
                }
            }
            if store.downloadingId == s.id || store.sharingId == s.id { downloadBar }
            if store.playingId == s.id { playerPanel }
        }
        .padding(.vertical, 4)
    }

    private var downloadBar: some View {
        VStack(spacing: 4) {
            if store.downloadProgress >= 0 {
                ProgressView(value: store.downloadProgress).tint(DS.teal)
                Text("Baixando \(Int((store.downloadProgress * 100).rounded()))%")
                    .font(.caption2).foregroundStyle(DS.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ProgressView().tint(DS.teal)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Baixando…").font(.caption2).foregroundStyle(DS.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.top, 2)
    }

    // Tocador estilo música: scrubber + ±15s + play/pause + stop.
    private var playerPanel: some View {
        VStack(spacing: 6) {
            Slider(value: Binding(get: { store.playTime },
                                  set: { store.seek(to: $0) }),
                   in: 0...max(store.playDuration, 0.1))
                .tint(DS.teal)
            HStack {
                Text(fmtTime(store.playTime)).font(.caption2).foregroundStyle(DS.muted)
                Spacer()
                Text(fmtTime(store.playDuration)).font(.caption2).foregroundStyle(DS.muted)
            }
            HStack(spacing: 28) {
                Button { store.skip(-15) } label: {
                    Image(systemName: "gobackward.15").font(.title2).foregroundStyle(DS.text)
                }
                Button { store.togglePause() } label: {
                    Image(systemName: store.paused ? "play.circle.fill" : "pause.circle.fill")
                        .font(.largeTitle).foregroundStyle(DS.teal)
                }
                Button { store.skip(15) } label: {
                    Image(systemName: "goforward.15").font(.title2).foregroundStyle(DS.text)
                }
                Button { store.stopPlayback() } label: {
                    Image(systemName: "stop.circle.fill").font(.title2).foregroundStyle(DS.red)
                }
            }
        }
        .padding(.top, 4)
    }

    private func fmtDur(_ ms: Double) -> String {
        let s = Int(ms / 1000); return s >= 60 ? "\(s / 60)m\(s % 60)s" : "\(s)s"
    }
    private func fmtTime(_ secs: Double) -> String {
        let s = Int(secs.rounded()); return String(format: "%d:%02d", s / 60, s % 60)
    }
    private func fmtMB(_ b: Double) -> String {
        b >= 1_048_576 ? String(format: "%.1f MB", b / 1_048_576) : String(format: "%.0f KB", b / 1024)
    }
}
