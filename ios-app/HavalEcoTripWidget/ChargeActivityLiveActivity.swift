//
//  ChargeActivityLiveActivity.swift
//  Live Activity de recarga — redesign 2026-11: SOC e "pronto às" são o hero;
//  potência, energia e custo numa grade de três colunas (carro em cima, tomada
//  embaixo); uma única perda, a da sessão. Frescor em hora absoluta, âmbar
//  quando a atividade fica stale. Concluída → variante verde de confirmação.
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

    // A tela bloqueada limita a Live Activity a ~160 pt: cabeçalho, hero,
    // barra, grade de duas linhas e botões cabem nesse orçamento.
    private var chargingBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            hero
            ChargeProgressBar(soc: state.soc, targetPct: state.targetPct)
            metrics
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
            Text(carName)
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

    // SOC grande | "pronto às 14:59" com "faltam 13 min · limite 100%" embaixo.
    private var hero: some View {
        HStack(alignment: .bottom, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(Int(state.soc))")
                    .font(.system(size: 32, weight: .light)).tracking(-1)
                    .monospacedDigit().foregroundStyle(LAv2.green)
                Text("%").font(.system(size: 15)).foregroundStyle(LAv2.green)
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                chargeReadyText(state)
                    .font(.system(size: 15, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(LAv2.text)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(chargeTimingLine(state))
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(LAv2.text2)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .frame(height: 36)
    }

    // Grade de três colunas: valor do carro em cima, valor da tomada embaixo.
    private var metrics: some View {
        let power = state.chargerPowerKw.flatMap {
            ChargePowerComparison(chargerPowerKw: $0, vehiclePowerKw: state.powerKw)
        }
        let energy = state.chargerSessionKwh.flatMap {
            ChargeEnergyComparison(chargerEnergyKwh: $0, vehicleEnergyKwh: state.sessionKwh)
        }
        let loss = chargeSessionLossPercent(state).map { "perda \(Int($0.rounded()))%" }
        let cost = state.costBrl.flatMap { $0 > 0 ? "R$ \(laDec2($0))" : nil }
        return HStack(alignment: .top, spacing: 8) {
            metric(value: "\(laDec1(state.powerKw)) kW",
                   sub: power.map { "tomada \(laDec1($0.chargerPowerKw)) kW" },
                   alignment: .leading)
            metric(value: "+\(laDec1(state.sessionKwh)) kWh",
                   sub: energy.map { "tomada \(laDec1($0.chargerEnergyKwh)) kWh" },
                   alignment: .center)
            if let cost {
                metric(value: cost, sub: loss, alignment: .trailing, subColor: LAv2.orange)
            } else if let loss {
                metric(value: loss, sub: nil, alignment: .trailing, valueColor: LAv2.orange)
            } else {
                Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
            }
        }
    }

    private func metric(value: String, sub: String?, alignment: HorizontalAlignment,
                        valueColor: Color = LAv2.text, subColor: Color = LAv2.text2) -> some View {
        let frameAlignment: Alignment = alignment == .leading ? .leading
            : (alignment == .trailing ? .trailing : .center)
        return VStack(alignment: alignment, spacing: 1) {
            Text(value)
                .font(.system(size: 13.5, weight: .semibold)).monospacedDigit()
                .foregroundStyle(valueColor)
            if let sub {
                Text(sub)
                    .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(subColor)
            }
        }
        .lineLimit(1).minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity, alignment: frameAlignment)
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
