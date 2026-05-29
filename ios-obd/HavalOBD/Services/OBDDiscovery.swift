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
    @Published var currentEcu: String = ""
    @Published var totalScanned = 0
    @Published var foundPids: [(ecu: String, pid: UInt16, response: String)] = []
    @Published var statusMsg: String = ""

    private weak var elm: ELM327?
    private var task: Task<Void, Never>?

    /// ECUs típicas do Haval H6 PHEV. ATSH define qual módulo recebe o comando.
    /// Cada ECU tem seu próprio conjunto de PIDs Mode 22.
    private let ecuHeaders: [(name: String, header: String)] = [
        ("ECM",  "7E0"),  // Motor a combustão
        ("TCM",  "7E1"),  // Transmissão
        ("BMS",  "7E2"),  // Bateria
        ("TMCU", "7E3"),  // Motor elétrico traseiro
        ("GMCU", "7E4"),  // Gerador/motor dianteiro
        ("HVAC", "7B0"),  // Ar-condicionado
        ("BCM",  "720"),  // Body Control (portas, luzes)
        ("EPB",  "760"),  // Freio de estacionamento
    ]

    /// Ranges de PIDs por ECU. Cada range = high byte. Low byte 0x00-0xFF.
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
            elm.stopPolling()
            try? await Task.sleep(nanoseconds: 300_000_000)

            // Total = ECUs × ranges × 256
            var pidsPerEcu = 0
            for range in scanRanges { pidsPerEcu += range.count * 256 }
            let totalPids = pidsPerEcu * ecuHeaders.count
            var scanned = 0
            let startTime = Date()

            for ecu in ecuHeaders {
                if Task.isCancelled { break }
                // Muda header pra a ECU atual
                await MainActor.run { self.currentEcu = ecu.name }
                _ = await elm.send("ATSH \(ecu.header)", timeout: 1.0)
                try? await Task.sleep(nanoseconds: 200_000_000)

                for range in scanRanges {
                    if Task.isCancelled { break }
                    for high in range {
                        if Task.isCancelled { break }
                        for low in 0...0xFF {
                            if Task.isCancelled { break }
                            let pid = (UInt16(high) << 8) | UInt16(low)
                            await MainActor.run {
                                self.currentPid = pid
                                self.statusMsg = String(format: "[%@] 22 %04X · %d/%d · %d achados",
                                                         ecu.name, pid, scanned, totalPids, self.foundPids.count)
                            }
                            let cmd = String(format: "22%04X", pid)
                            let resp = await elm.send(cmd, timeout: 1.0)
                            let up = resp.uppercased().replacingOccurrences(of: " ", with: "")
                            let expectedPrefix = String(format: "62%04X", pid)
                            if up.contains(expectedPrefix) {
                                await MainActor.run {
                                    self.foundPids.append((ecu: ecu.name, pid: pid, response: resp))
                                }
                            }
                            scanned += 1
                            await MainActor.run {
                                self.totalScanned = scanned
                                self.progress = Double(scanned) / Double(totalPids)
                            }
                            try? await Task.sleep(nanoseconds: 60_000_000)
                        }
                    }
                }
            }

            // Volta header pro default
            _ = await elm.send("ATSH 7DF", timeout: 1.0)

            let elapsed = Int(Date().timeIntervalSince(startTime))
            await MainActor.run {
                self.isRunning = false
                self.statusMsg = "Concluído: \(self.foundPids.count) PIDs válidos em \(elapsed)s"
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
                "ecu": entry.ecu,
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
