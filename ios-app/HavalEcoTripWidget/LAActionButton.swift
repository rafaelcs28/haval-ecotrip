//
//  LAActionButton.swift
//  Botão compacto pra Live Activity (iOS 17+): roda o AppIntent em background,
//  sem abrir o app. Visual discreto pra caber no tema escuro da LA. Compartilhado
//  entre as LAs (recarga, motor).
//
import AppIntents
import SwiftUI

@available(iOS 17.0, *)
struct LAActionButton<I: AppIntent>: View {
    let title: String
    let systemImage: String
    let tint: Color
    let intent: I

    init(title: String, systemImage: String, tint: Color = .green, intent: I) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.intent = intent
    }

    var body: some View {
        Button(intent: intent) {
            HStack(spacing: 4) {
                Image(systemName: systemImage).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.12))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .tint(tint)
    }
}
