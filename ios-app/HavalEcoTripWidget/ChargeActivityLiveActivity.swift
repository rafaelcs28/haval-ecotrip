//
//  ChargeActivityLiveActivity.swift
//  Live Activity de recarga — redesign 2026-11 (fluxo compacto): SOC e "pronto
//  às" no hero; duas linhas de fluxo, carregador → carro (perda agora) e
//  fornecidos → recebidos (perda da sessão · custo). Frescor em hora absoluta,
//  âmbar quando stale. Concluída → variante verde de confirmação.
//
import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

// Formato compacto v2: "1h24" / "42 min".
private func chargeRemainingShort(_ min: Int) -> String {
    guard min > 0 else { return "—" }
    if min >= 60 { return "\(min / 60)h\(String(format: "%02d", min % 60))" }
    return "\(min) min"
}

// Ícone compacto pra Dynamic Island: anel mostra o SOC ao redor do carrinho.
// Resolve o caso de 2 LAs simultâneas (Haval verde + BYD azul) competindo por
// espaço quando o user pluga o segundo carro — sem texto, só símbolo.
private struct CarChargeRing: View {
    let soc: Double
    let charging: Bool
    let accent: Color
    var body: some View {
        ZStack {
            Circle().stroke(accent.opacity(0.25), lineWidth: 2.2)
            Circle().trim(from: 0, to: CGFloat(min(100, max(0, soc)) / 100))
                .stroke(accent, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: charging ? "bolt.car.fill" : "checkmark.circle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(accent)
        }
        .frame(width: 22, height: 22)
    }
}

// Linha de ações da LA de recarga. Trancar/Destrancar segue o estado real da
// trava (state.locked); o botão de limite mostra a meta atual e cicla os presets.
@available(iOS 17.0, *)
@ViewBuilder
private func chargeLAButtons(_ s: ChargeActivityAttributes.ContentState) -> some View {
    HStack(spacing: 6) {
        if s.locked == true {
            LAActionButton(title: "Destrancar", systemImage: "lock.open.fill", tint: .orange, intent: UnlockCarIntent())
        } else {
            LAActionButton(title: "Trancar", systemImage: "lock.fill", intent: LockCarIntent())
        }
        LAActionButton(title: "Limite \(Int(s.targetPct))%", systemImage: "bolt.fill", tint: .green, intent: CycleChargeLimitIntent())
    }
}

struct ChargeActivityLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ChargeActivityAttributes.self) { context in
            ChargeLockScreenView(state: context.state, carName: context.attributes.carName,
                                 isStale: context.isStale)
                .activityBackgroundTint(LAv2.bg)
                .activitySystemActionForegroundColor(LAv2.green)

        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        CarChargeRing(soc: s.soc, charging: s.charging, accent: LAv2.green)
                        Text("\(Int(s.soc))%")
                            .font(.system(size: 22, weight: .light)).monospacedDigit()
                            .foregroundStyle(LAv2.green)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 1) {
                        if s.charging {
                            chargeReadyText(s)
                                .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(LAv2.text)
                                .lineLimit(1).minimumScaleFactor(0.7)
                            Text(chargeTimingLine(s))
                                .font(.system(size: 11)).monospacedDigit().foregroundStyle(LAv2.text2)
                                .lineLimit(1).minimumScaleFactor(0.7)
                        } else {
                            Text("Recarga concluída")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(LAv2.green)
                        }
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        if s.charging {
                            ChargeProgressBar(soc: s.soc, targetPct: s.targetPct, height: 6)
                        }
                        Text(diSubline(s))
                            .font(.system(size: 11.5)).monospacedDigit().foregroundStyle(LAv2.text2)
                            .lineLimit(1).minimumScaleFactor(0.6)
                        if #available(iOS 17.0, *), s.charging {
                            chargeLAButtons(s)
                        }
                    }
                }
            } compactLeading: {
                CarChargeRing(soc: s.soc, charging: s.charging, accent: LAv2.green)
            } compactTrailing: {
                // Vazio: o anel ao redor do carro já mostra o SOC. Libera espaço
                // pra outras LAs (ex: BYD da Grasi) também aparecerem na DI.
                EmptyView()
            } minimal: {
                CarChargeRing(soc: s.soc, charging: s.charging, accent: LAv2.green)
            }
            .keylineTint(LAv2.green)
        }
    }

    private func diSubline(_ s: ChargeActivityAttributes.ContentState) -> String {
        var parts = [s.charging ? "\(laDec1(s.powerKw)) kW" : nil, "+\(laDec1(s.sessionKwh)) kWh"].compactMap { $0 }
        if let c = s.costBrl, c > 0 { parts.append("R$ \(laDec2(c))") }
        if let loss = chargeSessionLossPercent(s) { parts.append("perda \(Int(loss.rounded()))%") }
        return parts.joined(separator: " · ")
    }
}

// "pronto às 14:59" (ou "sem previsão" quando o carro não estima o fim).
private func chargeReadyText(_ s: ChargeActivityAttributes.ContentState) -> Text {
    guard s.remainingMin > 0 else { return Text("sem previsão") }
    let ready = s.updatedAt.addingTimeInterval(Double(s.remainingMin) * 60)
    return Text("pronto às ") + Text(ready, format: .dateTime.hour().minute())
}

// "faltam 13 min · limite 80%"
private func chargeTimingLine(_ s: ChargeActivityAttributes.ContentState) -> String {
    var parts: [String] = []
    if s.remainingMin > 0 { parts.append("faltam \(chargeRemainingShort(s.remainingMin))") }
    if s.targetPct > 0 { parts.append("limite \(Int(s.targetPct))%") }
    return parts.joined(separator: " · ")
}

// Perda da sessão (energia da tomada vs. energia que entrou no carro); na falta
// do medidor de energia, a perda instantânea pela potência. Uma perda só na tela.
private func chargeSessionLossPercent(_ s: ChargeActivityAttributes.ContentState) -> Double? {
    if let chargerEnergy = s.chargerSessionKwh,
       let energy = ChargeEnergyComparison(chargerEnergyKwh: chargerEnergy, vehicleEnergyKwh: s.sessionKwh) {
        return energy.lossPercent
    }
    if s.charging, let chargerPower = s.chargerPowerKw,
       let power = ChargePowerComparison(chargerPowerKw: chargerPower, vehiclePowerKw: s.powerKw) {
        return power.lossPercent
    }
    return nil
}

// Barra plana: preenchimento verde até o SOC e traço amarelo no limite (< 100%).
private struct ChargeProgressBar: View {
    let soc: Double
    let targetPct: Double
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let frac = CGFloat(min(100, max(0, soc)) / 100)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12)).frame(height: height)
                Capsule().fill(LAv2.green)
                    .frame(width: max(height, w * frac), height: height)
                if targetPct > 0, targetPct < 100 {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color(red: 0.980, green: 0.800, blue: 0.082))
                        .frame(width: 2, height: height + 5)
                        .offset(x: w * CGFloat(targetPct / 100) - 1)
                }
            }
            .frame(height: height + 5, alignment: .leading)
        }
        .frame(height: height + 5)
        .accessibilityHidden(true)
    }
}

struct ChargeLockScreenView: View {
    let state: ChargeActivityAttributes.ContentState
    let carName: String
    var isStale: Bool = false

    var body: some View {
        Group {
            if state.charging { chargingBody } else { doneBody }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    // A tela bloqueada limita a Live Activity a ~160 pt: cabeçalho, hero de uma
    // linha, barra, duas linhas de fluxo e botões cabem nesse orçamento.
    private var chargingBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            hero
            ChargeProgressBar(soc: state.soc, targetPct: state.targetPct)
            flows
            if #available(iOS 17.0, *) {
                chargeLAButtons(state)
            }
        }
    }

    // Carro | ponto + "atualizado 14:46" (âmbar "sem atualização desde" quando stale).
    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 9, weight: .bold)).foregroundStyle(.black)
                .frame(width: 17, height: 17)
                .background(LAv2.green, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .accessibilityHidden(true)
            Text("\(carName) · Carregando")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(LAv2.text)
                .lineLimit(1).minimumScaleFactor(0.7)
            Spacer(minLength: 6)
            Circle().fill(isStale ? LAv2.orange : LAv2.green).frame(width: 5, height: 5)
                .accessibilityHidden(true)
            (Text(isStale ? "sem atualização desde " : "atualizado ")
                + Text(state.updatedAt, format: .dateTime.hour().minute()))
                .font(.system(size: 10.5)).monospacedDigit()
                .foregroundStyle(isStale ? LAv2.orange : LAv2.text2)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    // SOC grande | "pronto às 15:02 · 6 min" numa linha só.
    private var hero: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(Int(state.soc))")
                    .font(.system(size: 32, weight: .light)).tracking(-1)
                    .monospacedDigit().foregroundStyle(LAv2.green)
                Text("%").font(.system(size: 15)).foregroundStyle(LAv2.green)
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            (chargeReadyText(state).font(.system(size: 15, weight: .semibold)).foregroundColor(LAv2.text)
                + Text(state.remainingMin > 0 ? " · \(chargeRemainingShort(state.remainingMin))" : "")
                    .font(.system(size: 13)).foregroundColor(LAv2.text2))
                .monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(height: 34)
    }

    // Fluxo em duas linhas: potência (carregador → carro, perda agora) e energia
    // (fornecidos → recebidos, perda da sessão · custo). Sem medidor do carregador,
    // a linha mostra só o lado do carro.
    private var flows: some View {
        let power = state.chargerPowerKw.flatMap {
            ChargePowerComparison(chargerPowerKw: $0, vehiclePowerKw: state.powerKw)
        }
        let energy = state.chargerSessionKwh.flatMap {
            ChargeEnergyComparison(chargerEnergyKwh: $0, vehicleEnergyKwh: state.sessionKwh)
        }
        let cost = state.costBrl.flatMap { $0 > 0 ? "R$ \(laDec2($0))" : nil }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                if let power {
                    flowLabel("Carregador"); flowValue("\(laDec1(power.chargerPowerKw)) kW")
                    flowArrow
                }
                flowLabel("Carro"); flowValue("\(laDec1(state.powerKw)) kW")
                Spacer(minLength: 6)
                if let power {
                    Text("perda agora \(Int(power.lossPercent.rounded()))%").foregroundStyle(LAv2.orange)
                }
            }
            HStack(spacing: 5) {
                if let energy {
                    flowValue("\(laDec1(energy.chargerEnergyKwh)) kWh"); flowLabel("fornecidos")
                    flowArrow
                    flowValue(laDec1(energy.vehicleEnergyKwh)); flowLabel("recebidos")
                } else {
                    flowValue("+\(laDec1(state.sessionKwh)) kWh"); flowLabel("recebidos")
                }
                Spacer(minLength: 6)
                if let energy {
                    Text("perda \(Int(energy.lossPercent.rounded()))%").foregroundStyle(LAv2.orange)
                }
                if let cost {
                    Text(energy == nil ? cost : "· \(cost)").fontWeight(.semibold).foregroundStyle(LAv2.text)
                }
            }
        }
        .font(.system(size: 11.5)).monospacedDigit()
        .lineLimit(1).minimumScaleFactor(0.7)
    }

    private func flowLabel(_ text: String) -> some View {
        Text(text).foregroundStyle(LAv2.text2)
    }

    private func flowValue(_ text: String) -> some View {
        Text(text).fontWeight(.semibold).foregroundStyle(LAv2.text)
    }

    private var flowArrow: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 9, weight: .semibold)).foregroundStyle(LAv2.text2)
            .accessibilityLabel("para")
    }

    // Variante verde de confirmação — bridge encerra com stale/dismissal.
    private var doneBody: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 34)).foregroundStyle(LAv2.green)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Recarga concluída · \(Int(state.soc))%")
                    .font(.system(size: 14, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(LAv2.text)
                Text(doneSub)
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(LAv2.text2)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            Spacer(minLength: 6)
            Text(state.updatedAt, format: .dateTime.hour().minute())
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(LAv2.text2)
        }
    }

    private var doneSub: String {
        var parts = ["+\(laDec1(state.sessionKwh)) kWh"]
        if let c = state.costBrl, c > 0 { parts.append("R$ \(laDec2(c))") }
        if let loss = chargeSessionLossPercent(state) { parts.append("perda \(Int(loss.rounded()))%") }
        return parts.joined(separator: " · ")
    }
}
