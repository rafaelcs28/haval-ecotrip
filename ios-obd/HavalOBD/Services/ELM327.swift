import Foundation
import Combine

/// Camada que sabe falar ELM327 sobre o BluetoothManager.
///
/// Roteiro:
///   1. `initialize()`  — manda ATZ (reset), ATE0 (echo off), ATL0 (linefeed off),
///                        ATSP0 (auto protocol). Aguarda OK em cada.
///   2. `poll(_:)`      — manda um comando (ex "010C"), parseia resposta hex,
///                        aplica `pid.parser`, retorna `OBDSample`.
///   3. Coordenador externo agenda polls em loop respeitando priority.
@MainActor
final class ELM327: ObservableObject {
    @Published var initialized = false
    @Published var lastErrorMsg: String?
    @Published private(set) var samples: [String: OBDSample] = [:]    // último valor por PID

    let bt: BluetoothManager
    private var pollTask: Task<Void, Never>?

    init(bt: BluetoothManager) { self.bt = bt }

    func initialize() async {
        initialized = false
        // Sequência mínima de boot do ELM327
        let initCommands = ["ATZ", "ATE0", "ATL0", "ATH0", "ATS0", "ATSP0"]
        for cmd in initCommands {
            let resp = await send(cmd, timeout: 2.0)
            if resp.isEmpty {
                lastErrorMsg = "Sem resposta em \(cmd)"
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        initialized = true
        lastErrorMsg = nil
        startPolling()
    }

    /// Envia 1 comando e retorna a resposta crua (string ASCII recebida).
    func send(_ command: String, timeout: TimeInterval = 1.0) async -> String {
        await withCheckedContinuation { cont in
            bt.send(command, timeout: timeout) { resp in
                cont.resume(returning: resp)
            }
        }
    }

    /// Manda um PID específico, parseia e atualiza o store.
    @discardableResult
    func poll(_ pid: PIDDefinition) async -> OBDSample? {
        guard initialized else { return nil }
        let raw = await send(pid.command, timeout: 1.0)
        guard !raw.isEmpty else { return nil }
        // Limpa o eco/prompt/whitespace e pega só os bytes hex
        let cleaned = raw
            .replacingOccurrences(of: ">", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        // Resposta esperada começa com "41XX" (Mode 01) ou "62XXXX" (Mode 22)
        // Encontra o início ignorando ruído antes
        var dataHex: String?
        if let r = cleaned.range(of: "41", options: .caseInsensitive) {
            // Mode 01: 41 XX YY ZZ... — pula 41 + 2 (PID echo) = 4 chars
            let start = r.lowerBound
            let from = cleaned.index(start, offsetBy: 4, limitedBy: cleaned.endIndex) ?? cleaned.endIndex
            dataHex = String(cleaned[from...])
        } else if let r = cleaned.range(of: "62", options: .caseInsensitive) {
            // Mode 22: 62 XX XX YY ZZ... — pula 62 + 4 (PID echo) = 6 chars
            let start = r.lowerBound
            let from = cleaned.index(start, offsetBy: 6, limitedBy: cleaned.endIndex) ?? cleaned.endIndex
            dataHex = String(cleaned[from...])
        }
        guard var hex = dataHex, hex.count >= 2 else { return nil }
        // Cap em 16 bytes pra ignorar trailing
        if hex.count > 32 { hex = String(hex.prefix(32)) }
        // Converte pares hex em UInt8
        var bytes: [UInt8] = []
        var idx = hex.startIndex
        while idx < hex.endIndex, hex.distance(from: idx, to: hex.endIndex) >= 2 {
            let next = hex.index(idx, offsetBy: 2)
            if let b = UInt8(hex[idx..<next], radix: 16) { bytes.append(b) }
            idx = next
        }
        guard let value = pid.parser(bytes) else { return nil }
        let s = OBDSample(pidId: pid.id, value: value, unit: pid.unit, ts: Date())
        samples[pid.id] = s
        return s
    }

    /// Loop de polling — alterna PIDs por priority. Fast a 5Hz, normal 1Hz, slow ~0.16Hz.
    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            let fastPids   = PIDRegistry.all.filter { $0.priority == .fast }
            let normalPids = PIDRegistry.all.filter { $0.priority == .normal }
            let slowPids   = PIDRegistry.all.filter { $0.priority == .slow }
            var tickFast = 0, tickNormal = 0, tickSlow = 0
            while !Task.isCancelled {
                // Cada tick de ~200ms (5Hz):
                //   • TODOS os fast PIDs
                //   • Round-robin 1 normal PID por tick (cobre lista em len(normal) ticks)
                //   • Round-robin 1 slow PID a cada 30 ticks (6s)
                for pid in fastPids {
                    if Task.isCancelled { return }
                    await self.poll(pid)
                }
                if !normalPids.isEmpty {
                    let i = tickFast % normalPids.count
                    await self.poll(normalPids[i])
                    tickNormal &+= 1
                }
                if !slowPids.isEmpty && tickFast % 30 == 0 {
                    let i = tickSlow % slowPids.count
                    await self.poll(slowPids[i])
                    tickSlow &+= 1
                }
                tickFast &+= 1
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
}
