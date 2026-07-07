//  CarHeroView.swift
//  Herói do Painel: render real do H6 (vista de cima) com camadas de estado —
//  os mesmos PNGs do app do carro (porta/vidro/teto/mala abertos, farol, ar,
//  trava, carga). Camadas empilhadas sobre o h6, espelhando InteractiveCar do
//  Android (HomeLayouts.kt). Pressão por pneu é overlay nosso nos 4 cantos.
//  Trava (toque no carro) e mala têm callback; demais comandos na fileira abaixo.

import SwiftUI

struct CarHeroState {
    var locked: Bool?                                 // nil = desconhecido
    var charging = false
    var frontLight = false
    var acOn = false
    var turnLeft = false
    var turnRight = false
    var doors: [Bool] = [false, false, false, false]  // FL, FR, RL, RR
    var windows: [Bool] = [false, false, false, false]
    var sunroof = false
    var trunk = false
    var tyres: [Double] = [0, 0, 0, 0]                // FL, FR, RL, RR (psi)
}

struct CarHeroView: View {
    let state: CarHeroState
    var onLock: () -> Void = {}
    var onTrunk: () -> Void = {}

    // cor da lataria do H6 (espelho em estado normal) e âmbar da seta
    private let mirrorBody = Color(red: 0.890, green: 0.906, blue: 0.945)
    private let amber = Color(red: 1.0, green: 0.757, blue: 0.027)

    private func tyreColor(_ psi: Double) -> Color {
        if psi <= 0 { return DS.border }
        return psi < 28 ? DS.red : DS.teal.opacity(0.85)
    }
    private func layer(_ name: String) -> some View {
        Image(name).resizable().scaledToFit()
    }
    private func tinted(_ name: String, _ color: Color, _ opacity: Double) -> some View {
        Image(name).renderingMode(.template).resizable().scaledToFit()
            .foregroundStyle(color).opacity(opacity)
    }

    var body: some View {
        TimelineView(.animation) { tl in
            let blink = Int(tl.date.timeIntervalSinceReferenceDate * 1.1) % 2 == 0
            GeometryReader { g in
                // retângulo real da imagem com scaledToFit (794×720)
                let imgAR: CGFloat = 794.0 / 720.0
                let boxAR = g.size.width / g.size.height
                let iw = boxAR > imgAR ? g.size.height * imgAR : g.size.width
                let ih = boxAR > imgAR ? g.size.height : g.size.width / imgAR
                let ox = (g.size.width - iw) / 2, oy = (g.size.height - ih) / 2
                // âncoras dos rótulos de pneu, em fração do retângulo da imagem
                let pt: (CGFloat, CGFloat) -> CGPoint = { fx, fy in
                    CGPoint(x: ox + fx * iw, y: oy + fy * ih)
                }

                ZStack {
                    layer("car_h6")
                    if state.frontLight { layer("car_farol") }

                    // espelho/seta no mesmo arco: cinza = espelho (porta fechada),
                    // âmbar piscando = seta. Porta aberta esconde o espelho.
                    if state.turnLeft { tinted("car_retrovisor_esquerdo", amber, blink ? 1 : 0) }
                    else if !state.doors[0] { tinted("car_retrovisor_esquerdo", mirrorBody, 1) }
                    if state.turnRight { tinted("car_retrovisor_direito", amber, blink ? 1 : 0) }
                    else if !state.doors[1] { tinted("car_retrovisor_direito", mirrorBody, 1) }

                    if state.doors[0] { layer("car_porta_dianteira_esquerda_aberta") }
                    if state.doors[1] { layer("car_porta_dianteira_direita_aberta") }
                    if state.doors[2] { layer("car_porta_traseira_esquerda_aberta") }
                    if state.doors[3] { layer("car_porta_traseira_direita_aberta") }
                    if state.trunk { layer("car_porta_malas") }
                    if state.sunroof { layer("car_teto_solar_aberto") }
                    if state.windows[0] { layer("car_vidro_dianteiro_esquerdo_aberto") }
                    if state.windows[1] { layer("car_vidro_dianteiro_direito_aberto") }
                    if state.windows[2] { layer("car_vidro_traseiro_esquerdo_aberto") }
                    if state.windows[3] { layer("car_vidro_traseiro_direito_aberto") }
                    if state.charging { layer("car_carga_carregando") }
                    if state.acOn { layer("car_ac_esquerda"); layer("car_ac_direita") }
                    if state.locked == true { layer("car_trava") }

                    // toques diretos: trava (corpo) e mala (traseira) — áreas invisíveis
                    Color.clear.contentShape(Rectangle())
                        .frame(width: iw * 0.34, height: ih * 0.45)
                        .position(pt(0.5, 0.45)).onTapGesture(perform: onLock)
                    Color.clear.contentShape(Rectangle())
                        .frame(width: iw * 0.30, height: ih * 0.10)
                        .position(pt(0.5, 0.80)).onTapGesture(perform: onTrunk)

                    // pressão dos pneus nos 4 cantos (overlay nosso): pneu colorido
                    // na roda + número pra fora
                    tyreMarker(0, wheel: pt(0.305, 0.30), outward: -20)
                    tyreMarker(1, wheel: pt(0.695, 0.30), outward: 20)
                    tyreMarker(2, wheel: pt(0.305, 0.685), outward: -20)
                    tyreMarker(3, wheel: pt(0.695, 0.685), outward: 20)
                }
            }
        }
    }

    private func tyreMarker(_ i: Int, wheel p: CGPoint, outward: CGFloat) -> some View {
        let psi = state.tyres[i]
        let low = psi > 0 && psi < 28
        return ZStack {
            Capsule().fill(tyreColor(psi))
                .frame(width: 7, height: 21)
                .overlay(Capsule().stroke(.black.opacity(0.25), lineWidth: 0.5))
                .shadow(color: (low ? DS.red : .clear).opacity(0.7), radius: 4)
            Text(psi <= 0 ? "—" : "\(Int(psi.rounded()))")
                .font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(low ? .white : DS.text)
                .padding(.horizontal, low ? 5 : 0).padding(.vertical, low ? 1 : 0)
                .background(low ? Capsule().fill(DS.red) : nil)
                .fixedSize()
                .offset(x: outward)
        }.position(p)
    }
}

#Preview {
    CarHeroView(state: CarHeroState(
        locked: false, charging: true, frontLight: false, acOn: true,
        doors: [false, true, false, false], windows: [true, false, false, false],
        sunroof: true, trunk: true, tyres: [34, 34, 26, 33]))
        .frame(height: 320).padding().background(Color.black)
}
