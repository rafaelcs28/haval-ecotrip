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
    /// ATSH (Set Header) — ECU específica pra mandar este PID.
    /// nil = usa broadcast 7DF (Mode 01 universal).
    /// Mode 22 customs do Haval precisam de ATSH específica:
    ///   "763" (com ATCRA 7A3), "76C" (7AC), "782" (7C2), "787" (7C7), "78B" (7CB)
    let header: String?
    let receiveFilter: String?    // ATCRA — corresponde ao header (+ 8 ou similar)
    /// Fórmula que aplica nos bytes de dados (após o header de resposta).
    let parser: ([UInt8]) -> Double?

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
