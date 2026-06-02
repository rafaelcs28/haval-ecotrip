//
//  DesignSystem.swift
//  Tema + componentes base da UI nativa (migração PWA→SwiftUI).
//  Cores espelham o tema do cluster/PWA (fundo escuro + acentos).
//

import SwiftUI

enum DS {
    // Paleta (igual ao :root do cluster.html)
    static let bg     = Color.black
    static let panel  = Color(red: 0.051, green: 0.051, blue: 0.059)   // #0d0d0f
    static let panel2 = Color(red: 0.086, green: 0.086, blue: 0.102)   // #16161a
    static let text   = Color(white: 0.961)                            // #f5f5f5
    static let muted  = Color(red: 0.42, green: 0.45, blue: 0.50)      // #6b7280
    static let border = Color.white.opacity(0.08)

    static let green  = Color(red: 0.133, green: 0.773, blue: 0.369)   // #22c55e
    static let blue   = Color(red: 0.220, green: 0.741, blue: 0.973)   // #38bdf8
    static let orange = Color(red: 0.984, green: 0.573, blue: 0.235)   // #fb923c
    static let teal   = Color(red: 0.133, green: 0.827, blue: 0.933)   // #22d3ee
    static let yellow = Color(red: 0.980, green: 0.800, blue: 0.082)   // #facc15
    static let red    = Color(red: 0.937, green: 0.267, blue: 0.267)   // #ef4444
}

/// Card padrão (painel escuro arredondado com borda sutil).
struct DSCard<Content: View>: View {
    var title: String? = nil
    var icon: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack(spacing: 6) {
                    if let icon { Image(systemName: icon).font(.caption).foregroundStyle(DS.muted) }
                    Text(title.uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DS.muted)
                        .tracking(0.5)
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.panel)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(DS.border, lineWidth: 1))
    }
}

/// Métrica compacta: valor grande + unidade + rótulo embaixo.
struct DSMetric: View {
    let value: String
    var unit: String = ""
    let label: String
    var color: Color = DS.text

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(color).monospacedDigit()
                if !unit.isEmpty {
                    Text(unit).font(.system(size: 13, weight: .regular)).foregroundStyle(DS.muted)
                }
            }
            Text(label.uppercased()).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DS.muted).tracking(0.4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Chip/pill (estado, marcha, etc.)
struct DSChip: View {
    let text: String
    var color: Color = DS.muted
    var filled: Bool = false
    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .bold))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .foregroundStyle(filled ? Color.black : color)
            .background(filled ? color : color.opacity(0.15))
            .clipShape(Capsule())
    }
}
