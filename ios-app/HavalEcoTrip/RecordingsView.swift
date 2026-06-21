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

    // ── Download + play (LAN direto) ──────────────────────────────────────────
    func play(_ s: RecSession) async {
        error = nil
        guard let (host, port) = lanHostPort else {
            error = "Download só na mesma rede do carro (LAN)."; return
        }
        guard let u = URL(string: "http://\(host):\(port)/api/rec/file/\(s.id)") else { return }
        downloadingId = s.id; defer { downloadingId = nil }
        do {
            let (tmp, resp) = try await URLSession.shared.download(from: u)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { error = "Arquivo indisponível."; return }
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent("\(s.id).wav")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(contentsOf: dest)
            p.delegate = self
            player = p
            playingId = s.id
            p.play()
        } catch { self.error = "Falha no download: \(error.localizedDescription)" }
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
                     ? "Áudio fica no carro. Download e play só na mesma rede (LAN)."
                     : "Conecte na mesma rede do carro pra baixar e ouvir.")
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
                .disabled(!store.lanReady)
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
