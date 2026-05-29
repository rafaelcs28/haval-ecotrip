import Foundation

/// Snapshot de leitura de UM PID em um instante. O coordenador acumula vários
/// desses por segundo e publica o mais recente de cada via MQTT em janelas
/// regulares (1Hz pra batch + push imediato pros prioritários).
struct OBDSample: Codable {
    let pidId: String          // ex: "rpm"
    let value: Double?         // nil = inválido
    let unit: String
    let ts: Date
    /// Bytes brutos parseados (hex sem espaço) — útil pra diagnosticar
    /// fórmulas: se valor não bate, dá pra ver o hex e descobrir offset/scale.
    var rawHex: String? = nil

    /// Pra serializar como JSON estilo `{ "rpm": 1850, "speed": 60, ... }`.
    var jsonKeyValue: (key: String, value: Double?) {
        (key: pidId, value: value)
    }
}
