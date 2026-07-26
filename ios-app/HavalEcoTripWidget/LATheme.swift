//
//  LATheme.swift
//  Tokens v2 pras Live Activities (widget target não inclui DesignSystem.swift).
//  Gramática: fundo #0d0d0f, numerais leves monospaced, micro-rótulos CAPS.
//
import SwiftUI

enum LAv2 {
    static let bg     = Color(red: 0.051, green: 0.051, blue: 0.059)   // #0d0d0f
    static let text   = Color(red: 0.961, green: 0.961, blue: 0.961)   // #f5f5f5
    static let text2  = Color(red: 0.580, green: 0.639, blue: 0.722)   // #94a3b8
    static let muted  = Color(red: 0.420, green: 0.447, blue: 0.502)   // #6b7280
    static let green  = Color(red: 0.133, green: 0.773, blue: 0.369)   // #22c55e
    static let teal   = Color(red: 0.133, green: 0.827, blue: 0.933)   // #22d3ee
    static let orange = Color(red: 0.984, green: 0.573, blue: 0.235)   // #fb923c
    static let red    = Color(red: 0.937, green: 0.267, blue: 0.267)   // #ef4444
    static let blue   = Color(red: 0.235, green: 0.573, blue: 0.984)   // #3c92fb (parking/nav)
}

func laDec1(_ v: Double) -> String {
    String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",")
}

func laDec2(_ v: Double) -> String {
    String(format: "%.2f", v).replacingOccurrences(of: ".", with: ",")
}

/// Velocidade corrigida pra bater com o velocímetro do carro. Espelha
/// `Fmt.adjSpeed` do app e o `getAdjustedSpeed` do APK — o widget não compila
/// DesignSystem.swift, então a fórmula é replicada aqui.
/// SÓ para DISPLAY; nunca em cálculo físico (consumo/km).
/// ⚠ Se mudar aqui, mudar em DesignSystem.swift (Fmt.adjSpeed) e no APK.
func laAdjSpeed(_ raw: Double) -> Int {
    let s = max(0, raw)
    return Int((s * 1.07 - s / 180 * 0.02).rounded(.towardZero))
}

// Micro-rótulo CAPS (8.5pt bold tracking) da gramática v2.
struct LACaps: View {
    let text: String
    var color: Color = LAv2.muted
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 8.5, weight: .bold))
            .tracking(1).foregroundStyle(color)
    }
}
