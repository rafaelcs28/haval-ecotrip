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
        lastErrorMsg = nil
        try? await Task.sleep(nanoseconds: 800_000_000)
        // Sequência de boot. Importante: ATSP6 força CAN ISO 15765-4 11-bit
        // 500 kbps — protocolo do Haval H6 PHEV (e maioria pós-2008). Pular
        // a fase SEARCHING do auto-detect (ATSP0) que demora 5-10s e mete
        // STOPPED nos primeiros polls.
        // Sequência mínima e robusta — todos universais ELM327 v1.x+
        let initCommands: [(cmd: String, timeout: TimeInterval, abortOnError: Bool)] = [
            ("ATZ",  5.0, true),   // reset (mandatório)
            ("ATE0", 1.0, true),   // echo off (mandatório pra parser funcionar)
            ("ATL0", 1.0, true),   // line feed off
            ("ATH0", 1.0, false),  // headers off (opcional)
            ("ATS0", 1.0, false),  // spaces off (opcional)
            ("ATSP0", 1.5, true),  // AUTO protocol
            ("0100", 10.0, false), // primeira query — pode dar NO DATA se carro não READY
        ]
        for (cmd, to, mandatory) in initCommands {
            let resp = await send(cmd, timeout: to)
            if resp.isEmpty && mandatory {
                lastErrorMsg = "Sem resposta em \(cmd)"
                return
            }
            let up = resp.uppercased()
            if up.contains("?") && mandatory {
                lastErrorMsg = "Erro em \(cmd): \(resp)"
                return
            }
            if up.contains("UNABLE TO CONNECT") {
                lastErrorMsg = "ECU não responde — carro pisado no freio + START (driving ready)?"
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        initialized = true
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
        // Timeout 2s — Haval responde em ~50-200ms, mas pode subir em rajada
        let raw = await send(pid.command, timeout: 2.0)
        guard !raw.isEmpty else { return nil }
        // Ignora respostas administrativas que não são dados de PID
        let up = raw.uppercased()
        if up.contains("STOPPED") || up.contains("SEARCHING") ||
           up.contains("NO DATA") || up.contains("UNABLE") {
            return nil
        }
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

    /// Loop de polling — espaça mais que antes pra evitar "STOPPED".
    /// ELM327 BLE não acompanha 5Hz com Haval — fica STOPPED em cascata.
    /// Agora 2 Hz: tick a cada 500ms. Cada tick faz 1 PID fast + round-robin
    /// dos normal/slow.
    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            let fastPids   = PIDRegistry.all.filter { $0.priority == .fast }
            let normalPids = PIDRegistry.all.filter { $0.priority == .normal }
            let slowPids   = PIDRegistry.all.filter { $0.priority == .slow }
            var tickAll = 0, tickFast = 0, tickNormal = 0, tickSlow = 0
            while !Task.isCancelled {
                // 1 fast PID por tick (round-robin) — cobre fastPids.count em N ticks
                if !fastPids.isEmpty {
                    let pid = fastPids[tickFast % fastPids.count]
                    await self.poll(pid)
                    tickFast &+= 1
                }
                // 1 normal PID a cada 2 ticks
                if !normalPids.isEmpty && tickAll % 2 == 0 {
                    let pid = normalPids[tickNormal % normalPids.count]
                    await self.poll(pid)
                    tickNormal &+= 1
                }
                // 1 slow PID a cada 12 ticks (6s)
                if !slowPids.isEmpty && tickAll % 12 == 0 {
                    let pid = slowPids[tickSlow % slowPids.count]
                    await self.poll(pid)
                    tickSlow &+= 1
                }
                tickAll &+= 1
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
}
