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
    /// PIDs que ELM respondeu mas parser não conseguiu extrair valor.
    /// Útil pra diagnosticar formatos inesperados (multi-frame, len errado, etc).
    @Published private(set) var failedPids: [String: String] = [:]   // pid.id → raw hex recebido

    let bt: BluetoothManager
    private var pollTask: Task<Void, Never>?

    init(bt: BluetoothManager) { self.bt = bt }

    func initialize() async {
        initialized = false
        lastErrorMsg = nil
        try? await Task.sleep(nanoseconds: 300_000_000)
        // Boot agressivo: protocolo do Haval H6 PHEV é ATSP6 (CAN 11-bit
        // 500kbps), conhecido. Não testa outros. Sleeps mínimos entre AT.
        let initCommands: [(cmd: String, timeout: TimeInterval, abortOnError: Bool)] = [
            ("ATZ",  3.0, true),
            ("ATE0", 1.0, true),
            ("ATL0", 1.0, true),
            ("ATH0", 1.0, false),
            ("ATS0", 1.0, false),
            ("ATSP6", 1.0, false),
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
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        // Handshake 0100 — timeout 6s suficiente pro ATSP6 negociar.
        // Tenta 2 vezes (caso de STOPPED transiente).
        var handshakeOk = false
        for attempt in 0..<2 {
            lastErrorMsg = "Handshake \(attempt + 1)/2…"
            let resp = await send("0100", timeout: 6.0)
            let up = resp.uppercased().replacingOccurrences(of: " ", with: "")
            if up.contains("4100") {
                handshakeOk = true
                lastErrorMsg = nil
                break
            }
            if up.contains("STOPPED") {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }
            if up.contains("UNABLE") || up.contains("BUS INIT") {
                break
            }
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
        if !handshakeOk {
            lastErrorMsg = "Carro não respondeu — precisa estar em DRIVING READY (freio+START)"
            return
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

    private var currentHeader: String = ""

    /// Aplica configuração de ECU se mudou desde o último poll (evita ATSH
    /// repetido — só configura quando troca de ECU).
    private func ensureHeader(for pid: PIDDefinition) async {
        guard let header = pid.header else {
            // Mode 01 padrão usa broadcast — reseta TUDO se a última foi custom
            if !currentHeader.isEmpty && currentHeader != "7DF" {
                _ = await send("ATSH7DF", timeout: 1.5)
                try? await Task.sleep(nanoseconds: 50_000_000)
                _ = await send("ATCRA", timeout: 1.5)        // limpa filter
                try? await Task.sleep(nanoseconds: 50_000_000)
                _ = await send("ATFCSM0", timeout: 1.5)      // DESLIGA flow control (estava em 1 do Mode 22)
                try? await Task.sleep(nanoseconds: 100_000_000)
                currentHeader = "7DF"
            }
            return
        }
        if currentHeader == header { return }
        for cmd in PIDRegistry.setupCommands(forHeader: header, receiveFilter: pid.receiveFilter) {
            _ = await send(cmd, timeout: 1.5)
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        currentHeader = header
    }

    /// Manda um PID específico, parseia e atualiza o store.
    @discardableResult
    func poll(_ pid: PIDDefinition) async -> OBDSample? {
        guard initialized else { return nil }
        await ensureHeader(for: pid)
        let raw = await send(pid.command, timeout: 2.0)
        guard !raw.isEmpty else { return nil }
        // Ignora respostas administrativas que não são dados de PID
        let up = raw.uppercased()
        if up.contains("STOPPED") || up.contains("SEARCHING") ||
           up.contains("NO DATA") || up.contains("UNABLE") {
            // Guarda no failedPids pra dar visibilidade no overlay debug.
            // Útil pra confirmar se o BMS está respondendo ou não cada PID.
            let trimmed = raw.replacingOccurrences(of: ">", with: "")
                             .trimmingCharacters(in: .whitespacesAndNewlines)
            failedPids[pid.id] = trimmed
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
        // Cap em 48 bytes — cobre multi-frame ISO-TP típico e elimina trailing
        if hex.count > 96 { hex = String(hex.prefix(96)) }
        // Converte pares hex em UInt8
        var bytes: [UInt8] = []
        var idx = hex.startIndex
        while idx < hex.endIndex, hex.distance(from: idx, to: hex.endIndex) >= 2 {
            let next = hex.index(idx, offsetBy: 2)
            if let b = UInt8(hex[idx..<next], radix: 16) { bytes.append(b) }
            idx = next
        }
        let hexJoined = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        guard let value = pid.parser(bytes) else {
            // Bytes chegaram mas parser não soube extrair — registra pra debug
            failedPids[pid.id] = hexJoined
            return nil
        }
        // Removeu falha anterior se desta vez parseou OK
        failedPids.removeValue(forKey: pid.id)
        let s = OBDSample(pidId: pid.id, value: value, unit: pid.unit, ts: Date(), rawHex: hexJoined)
        samples[pid.id] = s
        return s
    }

    /// Loop de polling priorizado por frequência:
    ///   • .fast    — pollados TODOS a cada tick (speed, rpm, soc, battery_current)
    ///   • .normal  — 1 por tick em rotação
    ///   • .slow    — 1 a cada 3 ticks em rotação (temps, células, limites)
    ///
    /// Resultado típico: fast PIDs atualizam a ~1.5Hz (~600ms cada),
    /// normal a cada 4s, slow a cada 30s. Speed nunca trava porque
    /// é pollado a cada ciclo.
    ///
    /// Agrupamento por ECU: normals e slows do mesmo header são
    /// agrupados pra evitar re-setup constante (cada switch de ECU
    /// custa ~500ms em 5 AT commands ATSH/ATCRA/ATFCSH/ATFCSD/ATFCSM).
    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            let allFast   = PIDRegistry.all.filter { $0.priority == .fast }
            let allNormal = PIDRegistry.all.filter { $0.priority == .normal }
            let allSlow   = PIDRegistry.all.filter { $0.priority == .slow }
            var normalIdx = 0
            var slowIdx = 0
            var tick = 0
            while !Task.isCancelled {
                // 1) FAST — todos a cada tick (speed_kmh_obd, rpm, soc, battery_current)
                for pid in allFast {
                    if Task.isCancelled { return }
                    await self.poll(pid)
                    try? await Task.sleep(nanoseconds: 50_000_000)   // 50ms
                }
                // 2) NORMAL — 1 por tick rotativo
                if !allNormal.isEmpty {
                    let pid = allNormal[normalIdx % allNormal.count]
                    normalIdx += 1
                    if Task.isCancelled { return }
                    await self.poll(pid)
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                // 3) SLOW — 1 a cada 3 ticks rotativo
                if tick % 3 == 0 && !allSlow.isEmpty {
                    let pid = allSlow[slowIdx % allSlow.count]
                    slowIdx += 1
                    if Task.isCancelled { return }
                    await self.poll(pid)
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                tick &+= 1
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
}
