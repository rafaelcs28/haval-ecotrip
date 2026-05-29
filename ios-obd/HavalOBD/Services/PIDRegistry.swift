import Foundation

/// Catálogo de PIDs do app.
///
/// Mode 01 universais — funcionam em qualquer carro OBD-II via broadcast 7DF.
/// Mode 22 customs Haval — descobertos no log do Car Scanner v2.1.25 com perfil
/// "Haval H6 Gen.3 HEV/PHEV (2021-)". Cada PID precisa do ATSH correto:
///
///   ECU 763 (resp 7A3): 22A012, 22A019           — ?
///   ECU 76C (resp 7AC): 220210                    — ?
///   ECU 782 (resp 7C2): 226303                    — ?
///   ECU 787 (resp 7C7): 22 1109..1111, 22 2108..2111, 22 2304/2305 — BMS provável
///   ECU 78B (resp 7CB): 22E114, 22E115            — ?
///
/// Parsers são placeholders — precisam ser calibrados pelos bytes reais
/// recebidos. Por enquanto registramos como `byte0` pra ver os dados crus.
enum PIDRegistry {
    static let all: [PIDDefinition] = [
        // ────────── Mode 01 UNIVERSAIS ──────────
        PIDDefinition(id: "rpm", label: "RPM do motor", command: "010C", unit: "rpm",
            priority: .fast, header: nil, receiveFilter: nil,
            parser: { b in b.count >= 2 ? (Double(b[0]) * 256 + Double(b[1])) / 4 : nil }),
        PIDDefinition(id: "speed_kmh", label: "Velocidade", command: "010D", unit: "km/h",
            priority: .fast, header: nil, receiveFilter: nil,
            parser: { b in b.count >= 1 ? Double(b[0]) : nil }),
        PIDDefinition(id: "throttle_pct", label: "Borboleta", command: "0111", unit: "%",
            priority: .normal, header: nil, receiveFilter: nil,
            parser: { b in b.count >= 1 ? Double(b[0]) * 100 / 255 : nil }),
        PIDDefinition(id: "ect_c", label: "Temp. líquido", command: "0105", unit: "°C",
            priority: .normal, header: nil, receiveFilter: nil,
            parser: { b in b.count >= 1 ? Double(b[0]) - 40 : nil }),
        PIDDefinition(id: "iat_c", label: "Temp. ar adm.", command: "010F", unit: "°C",
            priority: .normal, header: nil, receiveFilter: nil,
            parser: { b in b.count >= 1 ? Double(b[0]) - 40 : nil }),
        PIDDefinition(id: "maf_gs", label: "MAF", command: "0110", unit: "g/s",
            priority: .normal, header: nil, receiveFilter: nil,
            parser: { b in b.count >= 2 ? (Double(b[0]) * 256 + Double(b[1])) / 100 : nil }),
        PIDDefinition(id: "fuel_level_pct", label: "Combustível", command: "012F", unit: "%",
            priority: .normal, header: nil, receiveFilter: nil,
            parser: { b in b.count >= 1 ? Double(b[0]) * 100 / 255 : nil }),
        PIDDefinition(id: "baro_kpa", label: "Pressão baro", command: "0133", unit: "kPa",
            priority: .slow, header: nil, receiveFilter: nil,
            parser: { b in b.count >= 1 ? Double(b[0]) : nil }),
        PIDDefinition(id: "ambient_c", label: "Temp. ambiente", command: "0146", unit: "°C",
            priority: .slow, header: nil, receiveFilter: nil,
            parser: { b in b.count >= 1 ? Double(b[0]) - 40 : nil }),
        PIDDefinition(id: "control_voltage", label: "12V", command: "0142", unit: "V",
            priority: .normal, header: nil, receiveFilter: nil,
            parser: { b in b.count >= 2 ? (Double(b[0]) * 256 + Double(b[1])) / 1000 : nil }),
        PIDDefinition(id: "intake_pressure_kpa", label: "Pressão adm.", command: "010B", unit: "kPa",
            priority: .normal, header: nil, receiveFilter: nil,
            parser: { b in b.count >= 1 ? Double(b[0]) : nil }),
        PIDDefinition(id: "engine_load_pct", label: "Carga motor", command: "0104", unit: "%",
            priority: .normal, header: nil, receiveFilter: nil,
            parser: { b in b.count >= 1 ? Double(b[0]) * 100 / 255 : nil }),
        PIDDefinition(id: "stft_pct", label: "STFT", command: "0106", unit: "%",
            priority: .slow, header: nil, receiveFilter: nil,
            parser: { b in b.count >= 1 ? (Double(b[0]) - 128) * 100 / 128 : nil }),
        PIDDefinition(id: "ltft_pct", label: "LTFT", command: "0107", unit: "%",
            priority: .slow, header: nil, receiveFilter: nil,
            parser: { b in b.count >= 1 ? (Double(b[0]) - 128) * 100 / 128 : nil }),
        PIDDefinition(id: "timing_advance_deg", label: "Avanço ignição", command: "010E", unit: "°",
            priority: .slow, header: nil, receiveFilter: nil,
            parser: { b in b.count >= 1 ? (Double(b[0]) - 128) / 2 : nil }),

        // ────────── Mode 22 CUSTOMS Haval (descobertos no log Car Scanner) ──────────
        // Parsers PROVISÓRIOS — capturam bytes pra debug. Ajustar depois com base
        // nos valores reais lidos vs valores esperados (SOC%, voltagem pack, etc.).

        // ── ECU 787 (resp 7C7) — provavelmente BMS principal ──
        PIDDefinition(id: "haval_787_2304", label: "BMS 2304", command: "222304", unit: "?",
            priority: .normal, header: "787", receiveFilter: "7C7",
            parser: { b in b.count >= 2 ? Double(b[0]) * 256 + Double(b[1]) : (b.first.map(Double.init)) }),
        PIDDefinition(id: "haval_787_2305", label: "BMS 2305", command: "222305", unit: "?",
            priority: .normal, header: "787", receiveFilter: "7C7",
            parser: { b in b.count >= 2 ? Double(b[0]) * 256 + Double(b[1]) : (b.first.map(Double.init)) }),
        PIDDefinition(id: "haval_787_1109", label: "BMS 1109", command: "221109", unit: "?",
            priority: .normal, header: "787", receiveFilter: "7C7",
            parser: { b in b.count >= 2 ? Double(b[0]) * 256 + Double(b[1]) : (b.first.map(Double.init)) }),
        PIDDefinition(id: "haval_787_1110", label: "BMS 1110", command: "221110", unit: "?",
            priority: .normal, header: "787", receiveFilter: "7C7",
            parser: { b in b.count >= 2 ? Double(b[0]) * 256 + Double(b[1]) : (b.first.map(Double.init)) }),
        PIDDefinition(id: "haval_787_1111", label: "BMS 1111", command: "221111", unit: "?",
            priority: .normal, header: "787", receiveFilter: "7C7",
            parser: { b in b.count >= 2 ? Double(b[0]) * 256 + Double(b[1]) : (b.first.map(Double.init)) }),
        PIDDefinition(id: "haval_787_2108", label: "BMS 2108", command: "222108", unit: "?",
            priority: .slow, header: "787", receiveFilter: "7C7",
            parser: { b in b.count >= 2 ? Double(b[0]) * 256 + Double(b[1]) : (b.first.map(Double.init)) }),
        PIDDefinition(id: "haval_787_2109", label: "BMS 2109", command: "222109", unit: "?",
            priority: .slow, header: "787", receiveFilter: "7C7",
            parser: { b in b.count >= 2 ? Double(b[0]) * 256 + Double(b[1]) : (b.first.map(Double.init)) }),
        PIDDefinition(id: "haval_787_2110", label: "BMS 2110", command: "222110", unit: "?",
            priority: .slow, header: "787", receiveFilter: "7C7",
            parser: { b in b.count >= 2 ? Double(b[0]) * 256 + Double(b[1]) : (b.first.map(Double.init)) }),
        PIDDefinition(id: "haval_787_2111", label: "BMS 2111", command: "222111", unit: "?",
            priority: .slow, header: "787", receiveFilter: "7C7",
            parser: { b in b.count >= 2 ? Double(b[0]) * 256 + Double(b[1]) : (b.first.map(Double.init)) }),

        // ── ECU 78B (resp 7CB) ──
        PIDDefinition(id: "haval_78B_E114", label: "ECU E114", command: "22E114", unit: "?",
            priority: .slow, header: "78B", receiveFilter: "7CB",
            parser: { b in b.count >= 2 ? Double(b[0]) * 256 + Double(b[1]) : (b.first.map(Double.init)) }),
        PIDDefinition(id: "haval_78B_E115", label: "ECU E115", command: "22E115", unit: "?",
            priority: .slow, header: "78B", receiveFilter: "7CB",
            parser: { b in b.count >= 2 ? Double(b[0]) * 256 + Double(b[1]) : (b.first.map(Double.init)) }),

        // ── ECU 763 (resp 7A3) ──
        PIDDefinition(id: "haval_763_A012", label: "ECU A012", command: "22A012", unit: "?",
            priority: .normal, header: "763", receiveFilter: "7A3",
            parser: { b in b.count >= 2 ? Double(b[0]) * 256 + Double(b[1]) : (b.first.map(Double.init)) }),
        PIDDefinition(id: "haval_763_A019", label: "ECU A019", command: "22A019", unit: "?",
            priority: .normal, header: "763", receiveFilter: "7A3",
            parser: { b in b.count >= 2 ? Double(b[0]) * 256 + Double(b[1]) : (b.first.map(Double.init)) }),

        // ── ECU 76C (resp 7AC) ──
        PIDDefinition(id: "haval_76C_0210", label: "ECU 0210", command: "220210", unit: "?",
            priority: .normal, header: "76C", receiveFilter: "7AC",
            parser: { b in b.count >= 2 ? Double(b[0]) * 256 + Double(b[1]) : (b.first.map(Double.init)) }),

        // ── ECU 782 (resp 7C2) ──
        PIDDefinition(id: "haval_782_6303", label: "ECU 6303", command: "226303", unit: "?",
            priority: .normal, header: "782", receiveFilter: "7C2",
            parser: { b in b.count >= 2 ? Double(b[0]) * 256 + Double(b[1]) : (b.first.map(Double.init)) }),
    ]

    /// Configura headers/filtros pra uma ECU específica. Sequência crucial pra
    /// Mode 22 receber respostas multi-frame (>7 bytes).
    static func setupCommands(forHeader header: String, receiveFilter: String?) -> [String] {
        var cmds: [String] = []
        cmds.append("ATSH\(header)")            // Set header (request address)
        if let rcv = receiveFilter {
            cmds.append("ATCRA\(rcv)")          // CAN Receive Address filter
        }
        cmds.append("ATFCSH\(header)")          // Flow Control Source Header
        cmds.append("ATFCSD300000")             // Flow Control Data: 30 00 00 (continue, no delay)
        cmds.append("ATFCSM1")                  // Flow Control Mode 1
        return cmds
    }
}
