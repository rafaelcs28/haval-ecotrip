//  RecordingsView.swift
//  Gravações de cabine por viagem. Controle manual: liga/desliga a gravação na
//  central (via bridge → MQTT). O áudio fica LOCAL no carro; o download é sob
//  demanda — LAN direto (APK /api/rec/file/<id>) com fallback de listagem pelo
//  bridge. Toca o WAV baixado com AVAudioPlayer.

import SwiftUI
import AVFoundation

struct RecSession: Identifiable {
    let id: String
    let startMs: Double
    let durationMs: Double
    let bytes: Double
    var date: Date { Date(timeIntervalSince1970: startMs / 1000) }
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
    @Published var gain: Double = 1.0
    @Published var gainBusy = false

    private let lan = LANDiscovery()
    private var lanHostPort: (String, Int)?
    private var player: AVAudioPlayer?

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

    func onDisappear() { lan.stop(); player?.stop() }

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
            if res.hasPrefix("error") { error = res; return }
            if res == "" { error = "Sem resposta do carro (offline?)."; return }
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

    // ── Download + play: LAN direto se disponível, senão bridge (WAN) ─────────
    func play(_ s: RecSession) async {
        error = nil
        downloadingId = s.id; defer { downloadingId = nil }
        // 1) LAN direto (rápido, sem auth)
        if let (host, port) = lanHostPort,
           let u = URL(string: "http://\(host):\(port)/api/rec/file/\(s.id)") {
            if await download(u, viaBridge: false, id: s.id) { return }
        }
        // 2) Fallback bridge — bridge puxa o WAV do carro via MQTT (até 90s)
        guard let u = URL(string: base + "/api/rec/file/\(s.id)") else {
            error = "Bridge não configurado."; return
        }
        _ = await download(u, viaBridge: true, id: s.id)
    }

    private func download(_ url: URL, viaBridge: Bool, id: String) async -> Bool {
        var r = URLRequest(url: url)
        r.timeoutInterval = viaBridge ? 100 : 20
        if viaBridge { r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization") }
        do {
            let (tmp, resp) = try await URLSession.shared.download(for: r)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                if viaBridge { error = "Carro offline — não enviou o arquivo." }
                return false
            }
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent("\(id).wav")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(contentsOf: dest)
            p.delegate = self
            player = p
            playingId = id
            p.play()
            return true
        } catch {
            if viaBridge { self.error = "Falha no download: \(error.localizedDescription)" }
            return false
        }
    }

    func stopPlayback() { player?.stop(); player = nil; playingId = nil }
}

extension RecordingsStore: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.playingId = nil }
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
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.df.string(from: s.date)).font(.callout).foregroundStyle(DS.text)
                Text("\(fmtDur(s.durationMs)) · \(fmtMB(s.bytes))")
                    .font(.caption).foregroundStyle(DS.muted)
            }
            Spacer()
            if store.downloadingId == s.id {
                ProgressView()
            } else if store.playingId == s.id {
                Button { store.stopPlayback() } label: {
                    Image(systemName: "stop.circle.fill").font(.title2).foregroundStyle(DS.red)
                }
            } else {
                Button { Task { await store.play(s) } } label: {
                    Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(DS.teal)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func fmtDur(_ ms: Double) -> String {
        let s = Int(ms / 1000); return s >= 60 ? "\(s / 60)m\(s % 60)s" : "\(s)s"
    }
    private func fmtMB(_ b: Double) -> String {
        b >= 1_048_576 ? String(format: "%.1f MB", b / 1_048_576) : String(format: "%.0f KB", b / 1024)
    }
}
