import Foundation

/// Catálogo central de PIDs que o app sabe ler. Começa com os Mode 01 padrão
/// (universais) + uns customs Haval inferidos pelas colunas do Car Scanner.
///
/// CUSTOMS HAVAL: os comandos hex EXATOS (`22 XX XX`) não estão no CSV
/// exportado — eles vivem dentro do app Car Scanner. Quando o usuário fizer
/// a sessão completa, podemos:
///   a) Capturar via BLE sniff em tempo real (Wireshark + USB BT dongle); ou
///   b) Tentar a base pública: github.com/CarScanner/elm327-pids
///   c) Sniff dos bytes brutos lidos quando o Car Scanner consulta
///
/// Por enquanto, deixo os customs como STUBS comentados com TODO e ativo
/// apenas os Mode 01 (que já cobre ~30 PIDs uteis universais).
enum PIDRegistry {
    static let all: [PIDDefinition] = [
        // ── Mode 01 — UNIVERSAIS (padrão SAE J1979) ─────────────────────
        PIDDefinition(
            id: "rpm", label: "RPM do motor", command: "010C", unit: "rpm",
            priority: .fast,
            parser: { b in b.count >= 2 ? (Double(b[0]) * 256 + Double(b[1])) / 4 : nil }
        ),
        PIDDefinition(
            id: "speed_kmh", label: "Velocidade", command: "010D", unit: "km/h",
            priority: .fast,
            parser: { b in b.count >= 1 ? Double(b[0]) : nil }
        ),
        PIDDefinition(
            id: "throttle_pct", label: "Borboleta", command: "0111", unit: "%",
            priority: .normal,
            parser: { b in b.count >= 1 ? Double(b[0]) * 100 / 255 : nil }
        ),
        PIDDefinition(
            id: "ect_c", label: "Temp. líquido refrigerante", command: "0105", unit: "°C",
            priority: .normal,
            parser: { b in b.count >= 1 ? Double(b[0]) - 40 : nil }
        ),
        PIDDefinition(
            id: "iat_c", label: "Temp. ar admissão", command: "010F", unit: "°C",
            priority: .normal,
            parser: { b in b.count >= 1 ? Double(b[0]) - 40 : nil }
        ),
        PIDDefinition(
            id: "maf_gs", label: "MAF", command: "0110", unit: "g/s",
            priority: .normal,
            parser: { b in b.count >= 2 ? (Double(b[0]) * 256 + Double(b[1])) / 100 : nil }
        ),
        PIDDefinition(
            id: "fuel_level_pct", label: "Nível combustível", command: "012F", unit: "%",
            priority: .normal,
            parser: { b in b.count >= 1 ? Double(b[0]) * 100 / 255 : nil }
        ),
        PIDDefinition(
            id: "baro_kpa", label: "Pressão barométrica", command: "0133", unit: "kPa",
            priority: .slow,
            parser: { b in b.count >= 1 ? Double(b[0]) : nil }
        ),
        PIDDefinition(
            id: "ambient_c", label: "Temp. ambiente", command: "0146", unit: "°C",
            priority: .slow,
            parser: { b in b.count >= 1 ? Double(b[0]) - 40 : nil }
        ),
        PIDDefinition(
            id: "control_voltage", label: "Voltagem 12V", command: "0142", unit: "V",
            priority: .normal,
            parser: { b in b.count >= 2 ? (Double(b[0]) * 256 + Double(b[1])) / 1000 : nil }
        ),
        PIDDefinition(
            id: "intake_pressure_kpa", label: "Pressão admissão", command: "010B", unit: "kPa",
            priority: .normal,
            parser: { b in b.count >= 1 ? Double(b[0]) : nil }
        ),
        PIDDefinition(
            id: "timing_advance_deg", label: "Avanço ignição", command: "010E", unit: "°",
            priority: .slow,
            parser: { b in b.count >= 1 ? (Double(b[0]) - 128) / 2 : nil }
        ),
        PIDDefinition(
            id: "engine_load_pct", label: "Carga do motor", command: "0104", unit: "%",
            priority: .normal,
            parser: { b in b.count >= 1 ? Double(b[0]) * 100 / 255 : nil }
        ),
        PIDDefinition(
            id: "stft_pct", label: "STFT banco 1", command: "0106", unit: "%",
            priority: .slow,
            parser: { b in b.count >= 1 ? (Double(b[0]) - 128) * 100 / 128 : nil }
        ),
        PIDDefinition(
            id: "ltft_pct", label: "LTFT banco 1", command: "0107", unit: "%",
            priority: .slow,
            parser: { b in b.count >= 1 ? (Double(b[0]) - 128) * 100 / 128 : nil }
        ),

        // ── Mode 22 — CUSTOMS HAVAL (TODO: descobrir comandos exatos) ──
        // Placeholders comentados. Quando o usuário fizer sessão completa
        // e/ou enviarmos sniff, preenchemos os comandos abaixo.
        //
        // PIDDefinition(id: "soc_pct", label: "SOC bateria",
        //               command: "22D002", unit: "%", priority: .fast,
        //               parser: { b in b.count >= 2 ? Double(b[0]*256 + b[1]) / 100 : nil }),
        //
        // PIDDefinition(id: "soh_pct", label: "SOH bateria",
        //               command: "22D003", unit: "%", priority: .slow, parser: ...),
        //
        // PIDDefinition(id: "pack_voltage", label: "Tensão pack",
        //               command: "22D005", unit: "V", priority: .normal, parser: ...),
        //
        // PIDDefinition(id: "pack_current", label: "Corrente pack",
        //               command: "22D006", unit: "A", priority: .fast, parser: ...),
        //
        // PIDDefinition(id: "tire_fl_psi", label: "Pressão FL",
        //               command: "22??", unit: "psi", priority: .slow, parser: ...),
    ]

    static var byCommand: [String: PIDDefinition] {
        Dictionary(uniqueKeysWithValues: all.map { ($0.command, $0) })
    }
}
