//
//  SecurityLiveActivity.swift
//  Live Activity persistente de veículo desprotegido (lock screen + Dynamic
//  Island). Desenha o carro em VISTA DE CIMA e destaca qual porta / vidro /
//  teto / porta-malas está aberto. Some sozinha quando tudo é resolvido.
//
import ActivityKit
import SwiftUI
import WidgetKit

// Paleta dos estados desenhados no carro.
private enum CarTint {
    static let secure  = Color.secondary.opacity(0.22)   // fechado/seguro
    static let door    = Color.red                       // porta/porta-malas aberto
    static let window  = Color.blue                      // vidro aberto
    static let sunroof = Color.orange                    // teto solar aberto
    static let body    = Color.gray.opacity(0.14)
    static let stroke  = Color.secondary.opacity(0.45)
}

struct SecurityLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SecurityActivityAttributes.self) { context in
            SecurityLockScreenView(state: context.state, carName: context.attributes.carName)
                .activityBackgroundTint(securityTint(context.state))
                .activitySystemActionForegroundColor(.red)

        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    CarTopView(state: s).frame(width: 62, height: 96)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .leading, spacing: 5) {
                        Label(s.active ? "Desprotegido" : "Seguro",
                              systemImage: s.active ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                            .font(.subheadline).bold()
                            .foregroundStyle(s.active ? .red : .green)
                        SecurityIssueList(state: s, limit: 3, dense: true)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if s.unlocked {
                        HStack {
                            Label("Veículo destrancado", systemImage: "lock.open.fill")
                                .font(.caption2).foregroundStyle(.red)
                            Spacer()
                            if #available(iOS 17.0, *) {
                                LAActionButton(title: "Travar", systemImage: "lock.fill", tint: .red, intent: LockCarIntent())
                            }
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: s.active ? "lock.open.fill" : "lock.fill")
                    .foregroundStyle(s.active ? .red : .green)
            } compactTrailing: {
                if s.active {
                    Text("\(s.openCount)").bold().foregroundStyle(.red)
                }
            } minimal: {
                Image(systemName: s.active ? "exclamationmark.triangle.fill" : "lock.fill")
                    .foregroundStyle(s.active ? .red : .green)
            }
            .keylineTint(s.unlocked ? .red : (s.active ? .orange : .green))
        }
    }
}

// MARK: - Lock screen

struct SecurityLockScreenView: View {
    let state: SecurityActivityAttributes.ContentState
    let carName: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            CarTopView(state: state).frame(width: 84, height: 130)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: state.active ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                        .foregroundStyle(state.active ? .red : .green)
                    Text(state.active ? "Veículo desprotegido" : "Veículo seguro")
                        .font(.headline).foregroundStyle(state.active ? .red : .primary)
                }
                Text(carName).font(.caption2).foregroundStyle(.secondary)

                if state.active {
                    SecurityIssueList(state: state, limit: 5, dense: false)
                        .padding(.top, 2)
                } else {
                    Text("Tudo trancado e fechado").font(.caption).foregroundStyle(.secondary)
                }
                if state.unlocked, #available(iOS 17.0, *) {
                    LAActionButton(title: "Travar", systemImage: "lock.fill", tint: .red, intent: LockCarIntent())
                        .padding(.top, 2)
                }
                Spacer(minLength: 0)
                CarLegend()
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }
}

// Lista textual dos itens abertos, com bolinha colorida por categoria.
private struct SecurityIssueList: View {
    let state: SecurityActivityAttributes.ContentState
    let limit: Int
    let dense: Bool

    var body: some View {
        let items = securityIssues(state)
        VStack(alignment: .leading, spacing: dense ? 1 : 3) {
            ForEach(items.prefix(limit), id: \.label) { item in
                HStack(spacing: 5) {
                    Circle().fill(item.color).frame(width: 6, height: 6)
                    Text(item.label)
                        .font(dense ? .caption2 : .caption)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
            }
            if items.count > limit {
                Text("+\(items.count - limit) mais")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

private struct CarLegend: View {
    var body: some View {
        HStack(spacing: 10) {
            legendDot(CarTint.door, "porta")
            legendDot(CarTint.window, "vidro")
            legendDot(CarTint.sunroof, "teto")
        }
    }
    private func legendDot(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(c).frame(width: 6, height: 6)
            Text(t).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Desenho do carro (vista de cima, frente no topo)

struct CarTopView: View {
    let state: SecurityActivityAttributes.ContentState

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let cx = w / 2
            ZStack {
                // Carroceria (silhueta — frente afunilada no topo)
                CarBodyShape()
                    .fill(CarTint.body)
                    .overlay(CarBodyShape().stroke(CarTint.stroke, lineWidth: 1.4))
                // Para-brisa (trapézio logo abaixo do capô) — reforça o "frente"
                WindshieldShape()
                    .fill(CarTint.stroke.opacity(0.35))
                    .frame(width: w * 0.5, height: h * 0.1)
                    .position(x: cx, y: h * 0.2)

                // Teto solar (centro-frente)
                roofElement(width: w * 0.40, height: h * 0.14, open: state.sunroof, tint: CarTint.sunroof)
                    .position(x: cx, y: h * 0.30)

                // Portas (barras nas laterais) — frente e traseira
                doorBar(open: state.doorFL, h: h).position(x: w * 0.085, y: h * 0.36)
                doorBar(open: state.doorFR, h: h).position(x: w * 0.915, y: h * 0.36)
                doorBar(open: state.doorRL, h: h).position(x: w * 0.085, y: h * 0.60)
                doorBar(open: state.doorRR, h: h).position(x: w * 0.915, y: h * 0.60)

                // Vidros (quadradinhos logo para dentro de cada porta)
                winDot(open: state.winFL).position(x: w * 0.24, y: h * 0.36)
                winDot(open: state.winFR).position(x: w * 0.76, y: h * 0.36)
                winDot(open: state.winRL).position(x: w * 0.24, y: h * 0.60)
                winDot(open: state.winRR).position(x: w * 0.76, y: h * 0.60)

                // Porta-malas (traseira, embaixo)
                roofElement(width: w * 0.46, height: h * 0.075, open: state.trunk, tint: CarTint.door)
                    .position(x: cx, y: h * 0.85)

                // Cadeado central (estado de trava)
                Image(systemName: state.unlocked ? "lock.open.fill" : "lock.fill")
                    .font(.system(size: w * 0.2, weight: .bold))
                    .foregroundStyle(state.unlocked ? CarTint.door : .green)
                    .position(x: cx, y: h * 0.485)
            }
        }
    }

    private func doorBar(open: Bool, h: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2.5)
            .fill(open ? CarTint.door : CarTint.secure)
            .frame(width: 8, height: h * 0.20)
            .shadow(color: open ? CarTint.door.opacity(0.6) : .clear, radius: 3)
    }

    private func winDot(open: Bool) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(open ? CarTint.window : CarTint.secure)
            .frame(width: 9, height: 9)
            .shadow(color: open ? CarTint.window.opacity(0.6) : .clear, radius: 3)
    }

    private func roofElement(width: CGFloat, height: CGFloat, open: Bool, tint: Color) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(open ? tint : CarTint.secure)
            .frame(width: width, height: height)
            .shadow(color: open ? tint.opacity(0.6) : .clear, radius: 3)
    }
}

// MARK: - Shapes do carro

// Silhueta vista de cima: frente (topo) mais estreita, abre nas portas, afunila
// de leve na traseira. Curvas suaves nos para-choques.
struct CarBodyShape: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height, cx = r.midX
        let frontHalf = w * 0.30, midHalf = w * 0.47, rearHalf = w * 0.41
        let yFront = r.minY + h * 0.05, yMid = r.minY + h * 0.34, yRear = r.maxY - h * 0.05
        var p = Path()
        p.move(to: CGPoint(x: cx - frontHalf, y: yFront))
        // Para-choque dianteiro
        p.addQuadCurve(to: CGPoint(x: cx + frontHalf, y: yFront),
                       control: CGPoint(x: cx, y: r.minY - h * 0.03))
        // Lateral direita: frente → meio (alarga)
        p.addQuadCurve(to: CGPoint(x: cx + midHalf, y: yMid),
                       control: CGPoint(x: cx + midHalf, y: r.minY + h * 0.14))
        // Meio → traseira (afunila um pouco)
        p.addLine(to: CGPoint(x: cx + rearHalf, y: yRear))
        // Para-choque traseiro
        p.addQuadCurve(to: CGPoint(x: cx - rearHalf, y: yRear),
                       control: CGPoint(x: cx, y: r.maxY + h * 0.03))
        // Lateral esquerda: traseira → meio → frente
        p.addLine(to: CGPoint(x: cx - midHalf, y: yMid))
        p.addQuadCurve(to: CGPoint(x: cx - frontHalf, y: yFront),
                       control: CGPoint(x: cx - midHalf, y: r.minY + h * 0.14))
        p.closeSubpath()
        return p
    }
}

// Para-brisa: trapézio com a base maior embaixo (em direção à cabine).
struct WindshieldShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + r.width * 0.18, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - r.width * 0.18, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Helpers

// Fundo da LA conforme a gravidade: destrancado é o mais crítico (vermelho
// forte); só vidro/teto aberto é alerta leve (laranja); seguro fica neutro.
func securityTint(_ s: SecurityActivityAttributes.ContentState) -> Color {
    if !s.active { return Color.green.opacity(0.12) }
    if s.unlocked { return Color.red.opacity(0.30) }
    if s.anyDoor { return Color.red.opacity(0.20) }
    return Color.orange.opacity(0.16)   // só vidro/teto
}

private struct SecurityIssueItem { let label: String; let color: Color }

private func securityIssues(_ s: SecurityActivityAttributes.ContentState) -> [SecurityIssueItem] {
    var out: [SecurityIssueItem] = []
    if s.unlocked { out.append(.init(label: "Destrancado", color: CarTint.door)) }
    if s.doorFL   { out.append(.init(label: "Porta diant. esq.", color: CarTint.door)) }
    if s.doorFR   { out.append(.init(label: "Porta diant. dir.", color: CarTint.door)) }
    if s.doorRL   { out.append(.init(label: "Porta tras. esq.", color: CarTint.door)) }
    if s.doorRR   { out.append(.init(label: "Porta tras. dir.", color: CarTint.door)) }
    if s.trunk    { out.append(.init(label: "Porta-malas", color: CarTint.door)) }
    if s.winFL    { out.append(.init(label: "Vidro diant. esq.", color: CarTint.window)) }
    if s.winFR    { out.append(.init(label: "Vidro diant. dir.", color: CarTint.window)) }
    if s.winRL    { out.append(.init(label: "Vidro tras. esq.", color: CarTint.window)) }
    if s.winRR    { out.append(.init(label: "Vidro tras. dir.", color: CarTint.window)) }
    if s.sunroof  { out.append(.init(label: "Teto solar", color: CarTint.sunroof)) }
    return out
}
