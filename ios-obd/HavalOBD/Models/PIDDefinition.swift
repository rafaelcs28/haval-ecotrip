import Foundation

/// Definição de UM PID que o app sabe ler do ELM327. Determinístico:
/// dado um `command` (string ASCII a enviar pro ELM327), e a resposta hex
/// recebida, o `parser` extrai o valor numérico final.
///
/// Tipos suportados:
///   • Mode 01 standard (PID hex 1 byte: ex "01 0C" pro RPM)
///   • Mode 22 custom (PID hex 2 bytes: ex "22 D0 02" pra SOC pack Haval)
///   • Multi-frame (ELM327 desfragmenta sozinho se header CAN ativo)
struct PIDDefinition: Identifiable, Hashable {
    enum Priority: Int, Codable {
        case fast = 5       // 5 Hz — RPM, speed, motor_kw, regen
        case normal = 1     // 1 Hz — SOC, fuel, temps, boost
        case slow = 6       // a cada 6s — SoH, cell voltages, limites
    }

    let id: String                // chave estável usada no MQTT: "rpm", "soc_pct", "tire_fl_psi"
    let label: String             // nome legível em PT-BR
    let command: String           // string ASCII enviada (sem CR) — ex: "010C" ou "22D002"
    let unit: String
    let priority: Priority
    /// Fórmula que aplica nos bytes de dados (após o header de resposta).
    /// `bytes` já vem só com os bytes do PAYLOAD (sem 41 XX ou 62 XX XX).
    let parser: ([UInt8]) -> Double?

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
