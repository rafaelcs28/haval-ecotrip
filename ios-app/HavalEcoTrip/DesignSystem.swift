//
//  DesignSystem.swift
//  Tema + componentes base da UI nativa (migração PWA→SwiftUI).
//  Cores espelham o tema do cluster/PWA (fundo escuro + acentos).
//

import SwiftUI

/// Formatação numérica pt-BR com separador de milhares.
enum Fmt {
    private static func nf(_ frac: Int) -> NumberFormatter {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.groupingSeparator = "."
        f.decimalSeparator = ","; f.minimumFractionDigits = frac; f.maximumFractionDigits = frac; return f
    }
    private static let f0 = nf(0)
    private static let f1 = nf(1)
    private static let f2 = nf(2)
    static func int(_ v: Double) -> String { f0.string(from: NSNumber(value: v)) ?? String(format: "%.0f", v) }
    static func dec1(_ v: Double) -> String { f1.string(from: NSNumber(value: v)) ?? String(format: "%.1f", v) }
    static func dec2(_ v: Double) -> String { f2.string(from: NSNumber(value: v)) ?? String(format: "%.2f", v) }
    /// km: <100 com 2 casas, >=100 inteiro (com milhares).
    static func km(_ v: Double) -> String { v < 100 ? dec2(v) : int(v) }
    static func brl(_ v: Double) -> String { "R$ " + (f2.string(from: NSNumber(value: v)) ?? String(format: "%.2f", v)) }
}

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
    var glass: Bool = false   // true = fundo translúcido (legível sobre o mapa)
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
        .background {
            if glass {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    Rectangle().fill(Color.black.opacity(0.35))
                }.environment(\.colorScheme, .dark)
            } else {
                Rectangle().fill(DS.panel)
            }
        }
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
                Text(value).font(.system(size: 21, weight: .semibold, design: .rounded))
                    .foregroundStyle(color).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.5).layoutPriority(1)
                if !unit.isEmpty {
                    Text(unit).font(.system(size: 11, weight: .regular)).foregroundStyle(DS.muted)
                        .lineLimit(1).minimumScaleFactor(0.5)
                }
            }
            Text(label.uppercased()).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DS.muted).tracking(0.4).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Botão de ação grande (ícone + texto), toque fácil. `busy` mostra spinner.
struct DSActionButton: View {
    let icon: String
    let title: String
    var color: Color = DS.blue
    var busy: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy { ProgressView().tint(.black) }
                else { Image(systemName: icon).font(.headline) }
                Text(title).font(.system(size: 16, weight: .bold))
            }
            .frame(maxWidth: .infinity).frame(height: 52)
            .foregroundStyle(.black)
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .disabled(busy)
    }
}

/// Seletor de opções em coluna/linha, alvo de toque grande (usado nos sheets).
struct DSChoiceRow<T: Hashable>: View {
    let options: [(T, String)]
    let selected: T
    var color: Color = DS.green
    let onPick: (T) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, opt in
                let on = opt.0 == selected
                Button { onPick(opt.0) } label: {
                    Text(opt.1)
                        .font(.system(size: 15, weight: .bold))
                        .frame(maxWidth: .infinity).frame(height: 50)
                        .foregroundStyle(on ? Color.black : DS.text)
                        .background(on ? color : DS.panel2)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(on ? .clear : DS.border, lineWidth: 1))
                }
            }
        }
    }
}

/// Card que recolhe/expande. `alert` força aberto e pinta de alerta (anomalia).
/// Recolhido mostra um resumo de uma linha; expandido mostra `content`.
struct CollapsibleCard<Content: View>: View {
    let icon: String
    let title: String
    let summary: String
    var alert: Bool = false
    @ViewBuilder var content: () -> Content
    @State private var userOpen = false

    var body: some View {
        let open = userOpen || alert
        let tint = alert ? DS.yellow : DS.muted
        DSCard {
            VStack(alignment: .leading, spacing: open ? 12 : 0) {
                Button { withAnimation(.easeInOut(duration: 0.2)) { userOpen.toggle() } } label: {
                    HStack(spacing: 8) {
                        Image(systemName: alert ? "exclamationmark.triangle.fill" : icon)
                            .font(.caption).foregroundStyle(tint)
                        Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(tint).tracking(0.5)
                        Spacer()
                        if !open { Text(summary).font(.caption).foregroundStyle(tint).lineLimit(1) }
                        Image(systemName: open ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(DS.muted)
                    }
                }
                .buttonStyle(.plain)
                if open { content() }
            }
        }
        .overlay(alert ? RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(DS.yellow.opacity(0.7), lineWidth: 1.5) : nil)
    }
}

/// Medidor de nível: ícone tingido + barra de preenchimento + valor/rótulo.
struct LevelBadge: View {
    let icon: String
    let fraction: Double       // 0…1
    let value: String
    let unit: String
    let label: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 26)).foregroundStyle(tint).frame(width: 30)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value).font(.system(size: 24, weight: .semibold, design: .rounded)).foregroundStyle(DS.text).monospacedDigit()
                    Text(unit).font(.system(size: 12)).foregroundStyle(DS.muted)
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(DS.panel2)
                        Capsule().fill(tint).frame(width: max(4, g.size.width * min(1, max(0, fraction))))
                    }
                }.frame(height: 6)
                Text(label.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(DS.muted).tracking(0.4)
            }
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
