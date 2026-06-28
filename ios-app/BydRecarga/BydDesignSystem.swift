//
//  BydDesignSystem.swift
//  Tokens + modifiers de Liquid Glass (iOS 26+) do app Grasi Recarga.
//  Replica os 4 modifiers centrais do playbook (gated com fallback pro
//  material antigo) usando paleta independente do Haval.
//

import SwiftUI

enum BD {
    static let bg     = Color.black
    static let panel2 = Color(red: 0.086, green: 0.086, blue: 0.102)   // #16161a
    static let stroke = Color.white.opacity(0.08)
}

extension View {
    /// Superfície de controle flutuante sobre conteúdo (botões circulares sobre mapa).
    /// iOS 26+: Liquid Glass real e interativo. Anteriores: ultraThinMaterial escuro.
    @ViewBuilder
    func glassControl<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(.regular.interactive(), in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .environment(\.colorScheme, .dark)
        }
    }

    /// Painel translúcido sobre conteúdo (overlay do cluster sobre o mapa).
    /// iOS 26+: glassEffect com tint escuro pra preservar legibilidade.
    /// Anteriores: ultraThinMaterial + véu preto (comportamento antigo).
    @ViewBuilder
    func glassPanel<S: Shape>(in shape: S, stroke: Color) -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(.regular.tint(BD.panel2.opacity(0.55)), in: shape)
                .overlay(shape.stroke(stroke, lineWidth: 1))
        } else {
            self.background {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    Rectangle().fill(Color.black.opacity(0.35))
                }.environment(\.colorScheme, .dark)
            }
            .clipShape(shape)
            .overlay(shape.stroke(stroke, lineWidth: 1))
        }
    }

    /// Minimiza a tab bar do sistema ao rolar (iOS 26+). No-op nos anteriores.
    @ViewBuilder
    func tabBarMinimizeOnScroll() -> some View {
        if #available(iOS 26, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }

    /// Nav bar escura opaca (comportamento legado). No iOS 26+ deixa o glass do
    /// sistema aparecer (não força fundo) — no-op. Manter pra eventual uso futuro.
    @ViewBuilder
    func legacyDarkNavBar() -> some View {
        if #available(iOS 26, *) {
            self
        } else {
            self.toolbarBackground(.visible, for: .navigationBar)
                .toolbarBackground(BD.bg, for: .navigationBar)
        }
    }
}
