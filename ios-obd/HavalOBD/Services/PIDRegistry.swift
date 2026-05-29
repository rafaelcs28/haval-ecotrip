import Foundation

/// Catálogo de PIDs do Haval H6 PHEV.
///
/// Mode 22 customs MAPEADOS via OBDb/Haval-Jolion-HEV (mesma plataforma
/// GWM Lemon B30). Fórmulas extraídas do `signalsets/v3/default.json`.
///
/// Convenção do `fmt` no OBDb:
///   valor_final = (raw * mul / div) + add
/// onde raw é interpretado em N bits (len) como signed ou unsigned.
enum PIDRegistry {

    private static func uint16(_ hi: UInt8, _ lo: UInt8) -> Int {
        Int(hi) << 8 | Int(lo)
    }
    private static func signed16(_ hi: UInt8, _ lo: UInt8) -> Int {
        let u = Int(hi) << 8 | Int(lo)
        return u > 32767 ? u - 65536 : u
    }

    static let all: [PIDDefinition] = [
        // ═════════ MODE 01 UNIVERSAIS (broadcast 7DF) ═════════
        PIDDefinition(id: "rpm", label: "RPM motor ICE", command: "010C", unit: "rpm",
            priority: .fast, header: nil, receiveFilter: nil,
            parser: { b in b.count >= 2 ? (Double(b[0]) * 256 + Double(b[1])) / 4 : nil }),
        PIDDefinition(id: "speed_kmh_obd", label: "Velocidade (OBD)", command: "010D", unit: "km/h",
            priority: .fast, header: nil, receiveFilter: nil,
            parser: { b in b.count >= 1 ? Double(b[0]) : nil }),
        PIDDefinition(id: "throttle_pct", label: "Borboleta", command: "0111", unit: "%",
            priority: .normal, header: nil, receiveFilter: nil,
            parser: { b in b.count >= 1 ? Double(b[0]) * 100 / 255 : nil }),
        PIDDefinition(id: "control_voltage", label: "12V (Mode 01)", command: "0142", unit: "V",
            priority: .normal, header: nil, receiveFilter: nil,
            parser: { b in b.count >= 2 ? (Double(b[0]) * 256 + Double(b[1])) / 1000 : nil }),
        PIDDefinition(id: "baro_kpa", label: "Pressão baro", command: "0133", unit: "kPa",
            priority: .slow, header: nil, receiveFilter: nil,
            parser: { b in b.count >= 1 ? Double(b[0]) : nil }),
        PIDDefinition(id: "ambient_c", label: "Temp. ambiente", command: "0146", unit: "°C",
            priority: .slow, header: nil, receiveFilter: nil,
            parser: { b in b.count >= 1 ? Double(b[0]) - 40 : nil }),

        // ═════════ ECU 78B — BMS (BATERIA)
        // Fmt cruzada com github.com/OBDb/Haval-Jolion-HEV
        PIDDefinition(id: "soc_pct", label: "SOC (BMS)", command: "22E0F4", unit: "%",
            priority: .fast, header: "78B", receiveFilter: "7CB",
            parser: { b in b.count >= 2 ? Double(uint16(b[0], b[1])) / 10 : nil }),    // len 16, div 10
        PIDDefinition(id: "soh_pct", label: "SoH (saúde)", command: "22E0F5", unit: "%",
            priority: .slow, header: "78B", receiveFilter: "7CB",
            parser: { b in b.first.map(Double.init) }),                                 // len 8, %
        PIDDefinition(id: "soe_kwh", label: "SoE (kWh)", command: "22E0F6", unit: "kWh",
            priority: .normal, header: "78B", receiveFilter: "7CB",
            parser: { b in b.count >= 2 ? Double(uint16(b[0], b[1])) / 10 : nil }),    // len 16, div 10
        PIDDefinition(id: "pack_voltage_v", label: "Pack Voltage", command: "22E006", unit: "V",
            priority: .normal, header: "78B", receiveFilter: "7CB",
            parser: { b in b.count >= 2 ? Double(uint16(b[0], b[1])) / 10 : nil }),
        PIDDefinition(id: "pack_cells_total_v", label: "Total cells V", command: "22E007", unit: "V",
            priority: .slow, header: "78B", receiveFilter: "7CB",
            parser: { b in b.count >= 2 ? Double(uint16(b[0], b[1])) + 1 : nil }),     // len 16, add 1
        PIDDefinition(id: "cell_voltage_max_mv", label: "Cell Max", command: "22E008", unit: "mV",
            priority: .normal, header: "78B", receiveFilter: "7CB",
            parser: { b in b.count >= 2 ? Double(uint16(b[0], b[1])) : nil }),
        PIDDefinition(id: "cell_voltage_min_mv", label: "Cell Min", command: "22E009", unit: "mV",
            priority: .normal, header: "78B", receiveFilter: "7CB",
            parser: { b in b.count >= 2 ? Double(uint16(b[0], b[1])) : nil }),
        PIDDefinition(id: "module_temp_avg_c", label: "Módulo temp avg", command: "22E0A1", unit: "°C",
            priority: .normal, header: "78B", receiveFilter: "7CB",
            parser: { b in b.first.map { Double($0) - 40 } }),
        PIDDefinition(id: "module_temp_max_c", label: "Módulo temp max", command: "22E088", unit: "°C",
            priority: .normal, header: "78B", receiveFilter: "7CB",
            parser: { b in b.first.map { Double($0) - 40 } }),
        PIDDefinition(id: "module_temp_min_c", label: "Módulo temp min", command: "22E089", unit: "°C",
            priority: .normal, header: "78B", receiveFilter: "7CB",
            parser: { b in b.first.map { Double($0) - 40 } }),
        // E0A4/E0C6/E0C8: fmt do Jolion → len 16, mul implícito 1, div 5, add -1200
        PIDDefinition(id: "battery_current_a", label: "Corrente bateria", command: "22E0A4", unit: "A",
            priority: .fast, header: "78B", receiveFilter: "7CB",
            parser: { b in b.count >= 2 ? Double(uint16(b[0], b[1])) / 5 - 1200 : nil }),
        PIDDefinition(id: "pack_discharge_limit_a", label: "Discharge limit", command: "22E0C6", unit: "A",
            priority: .slow, header: "78B", receiveFilter: "7CB",
            parser: { b in b.count >= 2 ? Double(uint16(b[0], b[1])) / 5 - 1200 : nil }),
        PIDDefinition(id: "pack_recharge_limit_a", label: "Recharge limit", command: "22E0C8", unit: "A",
            priority: .slow, header: "78B", receiveFilter: "7CB",
            parser: { b in b.count >= 2 ? Double(uint16(b[0], b[1])) / 5 - 1200 : nil }),

        // ═════════ ECU 787 — MCU (motores elétricos)
        PIDDefinition(id: "gmcu_motor_temp_c", label: "GMCU Motor Temp", command: "221109", unit: "°C",
            priority: .normal, header: "787", receiveFilter: "7C7",
            parser: { b in b.first.map { Double($0) - 40 } }),
        PIDDefinition(id: "gmcu_motor_rpm", label: "GMCU rpm", command: "221110", unit: "rpm",
            priority: .fast, header: "787", receiveFilter: "7C7",
            parser: { b in
                guard b.count >= 2 else { return nil }
                let v = signed16(b[0], b[1])
                // Sentinelas de "inválido"/"inicializando" do MCU:
                //   0x7FFC..0x7FFF (32764..32767) e 0x8000 (-32768)
                if v >= 32760 || v <= -32760 { return 0 }
                return Double(v)
            }),
        PIDDefinition(id: "gmcu_winding_temp_c", label: "GMCU enrol.", command: "221111", unit: "°C",
            priority: .slow, header: "787", receiveFilter: "7C7",
            parser: { b in b.first.map { Double($0) - 40 } }),
        PIDDefinition(id: "inverter_temp_c", label: "Inverter Temp", command: "222108", unit: "°C",
            priority: .normal, header: "787", receiveFilter: "7C7",
            parser: { b in b.first.map { Double($0) - 40 } }),
        PIDDefinition(id: "tmcu_motor_temp_c", label: "TMCU Motor Temp", command: "222109", unit: "°C",
            priority: .normal, header: "787", receiveFilter: "7C7",
            parser: { b in b.first.map { Double($0) - 40 } }),
        PIDDefinition(id: "tmcu_motor_rpm", label: "TMCU rpm", command: "222110", unit: "rpm",
            priority: .fast, header: "787", receiveFilter: "7C7",
            parser: { b in
                guard b.count >= 2 else { return nil }
                let v = signed16(b[0], b[1])
                // Sentinelas de "inválido"/"inicializando" do MCU:
                //   0x7FFC..0x7FFF (32764..32767) e 0x8000 (-32768)
                if v >= 32760 || v <= -32760 { return 0 }
                return Double(v)
            }),
        PIDDefinition(id: "tmcu_winding_temp_c", label: "TMCU enrol.", command: "222111", unit: "°C",
            priority: .slow, header: "787", receiveFilter: "7C7",
            parser: { b in b.first.map { Double($0) - 40 } }),
        PIDDefinition(id: "gmcu_torque_max_nm", label: "GMCU Torque Max", command: "222304", unit: "N·m",
            priority: .normal, header: "787", receiveFilter: "7C7",
            parser: { b in b.count >= 2 ? Double(uint16(b[0], b[1])) : nil }),
        PIDDefinition(id: "gmcu_torque_min_nm", label: "GMCU Torque Min", command: "222305", unit: "N·m",
            priority: .normal, header: "787", receiveFilter: "7C7",
            parser: { b in b.count >= 2 ? Double(uint16(b[0], b[1])) - 1023 : nil }),

        // ═════════ ECU 763 — HVAC
        PIDDefinition(id: "evaporator_temp_c", label: "Evaporador", command: "22A012", unit: "°C",
            priority: .slow, header: "763", receiveFilter: "7A3",
            parser: { b in b.count >= 2 ? Double(uint16(b[0], b[1])) / 10 - 20 : nil }),
        PIDDefinition(id: "cabin_temp_c", label: "Cabine", command: "22A019", unit: "°C",
            priority: .slow, header: "763", receiveFilter: "7A3",
            parser: { b in b.count >= 2 ? Double(uint16(b[0], b[1])) / 10 - 30 : nil }),

        // ═════════ ECU 7E0 — ECM (motor a combustão)
        PIDDefinition(id: "fuel_level_pct_22", label: "Combustível %", command: "22002F", unit: "%",
            priority: .normal, header: "7E0", receiveFilter: "7E8",
            parser: { b in b.first.map { Double($0) * 100 / 255 } }),
        PIDDefinition(id: "fuel_level_l_22", label: "Combustível L", command: "220106", unit: "L",
            priority: .normal, header: "7E0", receiveFilter: "7E8",
            parser: { b in b.count >= 2 ? Double(uint16(b[0], b[1])) / 10 : nil }),    // len 16, div 10
        // Oil temp: fmt complexa do Jolion (len 16, mul 0.023437, add -273.15 = Kelvin × 0.023437)
        PIDDefinition(id: "oil_temp_c", label: "Óleo motor", command: "220107", unit: "°C",
            priority: .slow, header: "7E0", receiveFilter: "7E8",
            parser: { b in b.count >= 2 ? Double(uint16(b[0], b[1])) * 0.023437 - 273.15 : nil }),
        PIDDefinition(id: "boost_actual_kpa", label: "Boost atual", command: "22010F", unit: "kPa",
            priority: .normal, header: "7E0", receiveFilter: "7E8",
            parser: { b in b.count >= 2 ? Double(uint16(b[0], b[1])) / 128 : nil }),   // len 16, div 128
        PIDDefinition(id: "gear_ecm", label: "Marcha (ECM)", command: "220132", unit: "",
            priority: .normal, header: "7E0", receiveFilter: "7E8",
            parser: { b in b.first.map { Double($0) } }),
        // Battery voltage 12V: byte * 12.5 / 100 → byte / 8
        PIDDefinition(id: "batt_12v_v", label: "Bateria 12V", command: "221702", unit: "V",
            priority: .slow, header: "7E0", receiveFilter: "7E8",
            parser: { b in b.first.map { Double($0) * 12.5 / 100 } }),

        // ═════════ ECU 7E1 — TCM (transmissão)
        PIDDefinition(id: "transmission_temp_c", label: "Trans. temp", command: "22D126", unit: "°C",
            priority: .slow, header: "7E1", receiveFilter: "7E9",
            parser: { b in b.first.map { Double($0) - 60 } }),                          // add -60 (não -40!)
        PIDDefinition(id: "current_gear", label: "Marcha atual", command: "226925", unit: "",
            priority: .normal, header: "7E1", receiveFilter: "7E9",
            parser: { b in b.first.map { Double($0) } }),
    ]

    /// Configura headers/filtros pra uma ECU específica.
    static func setupCommands(forHeader header: String, receiveFilter: String?) -> [String] {
        var cmds: [String] = []
        cmds.append("ATSH\(header)")
        if let rcv = receiveFilter {
            cmds.append("ATCRA\(rcv)")
        }
        cmds.append("ATFCSH\(header)")
        cmds.append("ATFCSD300000")
        cmds.append("ATFCSM1")
        return cmds
    }
}
