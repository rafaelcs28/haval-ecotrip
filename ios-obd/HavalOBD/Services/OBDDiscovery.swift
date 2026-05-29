import Foundation

/// Descobre PIDs Mode 22 (Service 22) custom do Haval via brute force.
///
/// Mode 22 é "Read Data by Identifier" do ISO 14229 (UDS). Cada fabricante
/// tem seus próprios IDs. ECM do Haval H6 PHEV responde nos ranges:
///   • 0x10-0x1F  → motor elétrico (TMCU/GMCU)
///   • 0x20-0x2F  → ECM extras
///   • 0xD0-0xDF  → BMS bateria
///   • 0xD2-0xD3  → packs e células
///   • 0x80-0x8F  → TPMS, HVAC
///
/// Pra cada PID: envia "22 XX XX", se resposta começar com "62 XX XX" é VÁLIDO.
/// Loga PID + resposta hex bruta. Cruza depois com nomes do CSV do Car Scanner.
@MainActor
final class OBDDiscovery: ObservableObject {
    @Published var isRunning = false
    @Published var progress: Double = 0
    @Published var currentPid: UInt16 = 0
    @Published var totalScanned = 0
    @Published var foundPids: [(pid: UInt16, response: String)] = []
    @Published var statusMsg: String = ""

    private weak var elm: ELM327?
    private var task: Task<Void, Never>?

    /// Ranges conhecidos de PIDs Mode 22 em PHEVs/Hybrids GWM.
    /// Cada range = (high byte mínimo, máximo). Low byte 0x00-0xFF.
    /// ~16 high bytes × 256 = 4096 PIDs. A 100ms cada = ~7min total.
    private let scanRanges: [ClosedRange<UInt8>] = [
        0x10...0x14,   // motores elétricos (TMCU, GMCU)
        0x20...0x24,   // ECM extras
        0x40...0x44,   // sensores diversos
        0x80...0x82,   // TPMS, HVAC
        0xD0...0xD3,   // BMS principal
        0xF4...0xF4,   // diagnostics extras
    ]

    func bind(elm: ELM327) {
        self.elm = elm
    }

    func start() {
        guard !isRunning, let elm = elm, elm.initialized else {
            statusMsg = "ELM não inicializado"
            return
        }
        isRunning = true
        progress = 0
        currentPid = 0
        totalScanned = 0
        foundPids = []
        statusMsg = "Iniciando…"

        task = Task { [weak self] in
            guard let self else { return }
            // Para o polling regular durante o scan (não conflita)
            elm.stopPolling()
            try? await Task.sleep(nanoseconds: 300_000_000)

            // Calcula total de PIDs
            var totalPids = 0
            for range in scanRanges { totalPids += range.count * 256 }
            var scanned = 0
            let startTime = Date()

            for range in scanRanges {
                if Task.isCancelled { break }
                for high in range {
                    if Task.isCancelled { break }
                    for low in 0...0xFF {
                        if Task.isCancelled { break }
                        let pid = (UInt16(high) << 8) | UInt16(low)
                        await MainActor.run {
                            self.currentPid = pid
                            self.statusMsg = String(format: "22 %04X · %d/%d · %d achados",
                                                     pid, scanned, totalPids, self.foundPids.count)
                        }
                        let cmd = String(format: "22%04X", pid)
                        let resp = await elm.send(cmd, timeout: 1.0)
                        let up = resp.uppercased().replacingOccurrences(of: " ", with: "")
                        let expectedPrefix = String(format: "62%04X", pid)
                        if up.contains(expectedPrefix) {
                            await MainActor.run {
                                self.foundPids.append((pid: pid, response: resp))
                            }
                        }
                        scanned += 1
                        await MainActor.run {
                            self.totalScanned = scanned
                            self.progress = Double(scanned) / Double(totalPids)
                        }
                        // Throttle 80ms — Veepeak BLE precisa de tempo
                        try? await Task.sleep(nanoseconds: 80_000_000)
                    }
                }
            }

            let elapsed = Int(Date().timeIntervalSince(startTime))
            await MainActor.run {
                self.isRunning = false
                self.statusMsg = "Concluído: \(self.foundPids.count) PIDs válidos em \(elapsed)s"
                // Retoma polling normal
                if elm.initialized { elm.startPolling() }
            }
        }
    }

    func stop() {
        task?.cancel()
        isRunning = false
        statusMsg = "Cancelado"
        if let elm = elm, elm.initialized { elm.startPolling() }
    }

    /// Exporta os PIDs achados como JSON pra clipboard.
    func exportJSON() -> String {
        let dict = foundPids.map { entry -> [String: Any] in
            return [
                "pid_hex": String(format: "%04X", entry.pid),
                "command": String(format: "22%04X", entry.pid),
                "response": entry.response,
            ]
        }
        let payload: [String: Any] = [
            "scanned": totalScanned,
            "found": foundPids.count,
            "ts": ISO8601DateFormatter().string(from: Date()),
            "pids": dict,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{}"
    }
}
