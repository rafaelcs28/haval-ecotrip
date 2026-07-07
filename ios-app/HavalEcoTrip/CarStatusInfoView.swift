//  CarStatusInfoView.swift
//  Estilo "informações padrão" do card principal — mesmo padrão visual do app
//  Grasi Recarga: anel de SOC como herói, métricas grandes em rounded mono,
//  tiles de status (trava/portas/vidros) e de pneus. Alternativa ao desenho do
//  carro (CarHeroView), escolhível em Configurações.

import SwiftUI

struct CarStatusData {
    var locked: Bool?
    var charging = false
    var engineOn = false
    var socPct: Double = 0
    var rangeEvKm: Double = 0
    var chargePowerKw: Double = 0
    var openDoors: [String] = []      // nomes legíveis (inclui porta-malas)
    var openWindows: [String] = []    // nomes legíveis (inclui teto solar)
    var tyres: [Double] = [0, 0, 0, 0]      // psi  FL,FR,RL,RR
    var tyreTemps: [Double] = [0, 0, 0, 0]  // °C
    // dados da carga (só relevantes quando charging)
    var chargeSessionKwh: Double = 0
    var chargeRemainingMin: Int = 0
    var chargeLimitPct: Double = 0
    var chargeTargetPct: Int = 0      // alvo custom; 0 = corte por software desligado
    // energia incorporada (modo Informações): tanque + autonomia térmica + preços
    var fuelL: Double = 0
    var rangeIceKm: Double = 0
    var priceKwh: Double = 0
    var priceGas: Double = 0
    var tankL: Double = 55      // capacidade do tanque p/ o gauge de gasolina
}

struct CarStatusInfoView: View {
    let data: CarStatusData

    private func f0(_ v: Double) -> String { String(format: "%.0f", v) }
    private func f1(_ v: Double) -> String { String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",") }

    private var accent: Color {
        if data.charging { return DS.green }
        if data.engineOn { return DS.yellow }
        return DS.blue
    }
    private var stateLabel: String {
        if data.charging { return "Carregando" }
        if data.engineOn { return "Dirigindo" }
        return "Ocioso"
    }

    private var chargeTargetLabel: String? {
        if data.chargeTargetPct > 0 { return "alvo \(data.chargeTargetPct)% · corte automático" }
        if data.chargeLimitPct > 0 && data.chargeLimitPct < 100 { return "limite \(f0(data.chargeLimitPct))%" }
        return nil
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                Text(stateLabel).font(.system(size: 15, weight: .semibold)).foregroundStyle(accent)
                if data.charging, let t = chargeTargetLabel {
                    Text("· \(t)").font(.caption2).foregroundStyle(DS.muted)
                }
                Spacer()
            }
            HStack(spacing: 12) {
                batteryGauge
                fuelGauge
            }
            if data.charging {
                HStack(spacing: 8) {
                    chargeMetric(f1(data.chargeSessionKwh), unit: "kWh", label: "Sessão", color: DS.teal)
                    chargeMetric(data.chargeRemainingMin > 0 ? "\(data.chargeRemainingMin)" : "—",
                                 unit: "min", label: "Faltam", color: DS.text)
                    chargeMetric(f1(data.chargePowerKw), unit: "kW", label: "Potência", color: DS.green)
                }
            }
            HStack(spacing: 8) {
                lockTile
                statTile(icon: "door.left.hand.open",
                         value: data.openDoors.isEmpty ? "ok" : data.openDoors.joined(separator: ", "),
                         label: "Portas", color: data.openDoors.isEmpty ? DS.green : DS.orange)
                statTile(icon: "macwindow",
                         value: data.openWindows.isEmpty ? "ok" : data.openWindows.joined(separator: ", "),
                         label: "Vidros/teto", color: data.openWindows.isEmpty ? DS.green : DS.orange)
            }
            HStack(spacing: 8) { tyreTile(0, "Diant. esq."); tyreTile(1, "Diant. dir.") }
            HStack(spacing: 8) { tyreTile(2, "Tras. esq.");  tyreTile(3, "Tras. dir.") }
        }
    }

    // Gauge da bateria: anel de SOC + nº reduzido + "% SOC" + R$/kWh dentro do anel;
    // autonomia elétrica vai no rodapé (sem duplicar). Marcador branco = limite de carga.
    private var batteryGauge: some View {
        let effLimit: Double = data.chargeTargetPct > 0 ? Double(data.chargeTargetPct) : data.chargeLimitPct
        let showMarker = data.charging && effLimit > 0 && effLimit < 100
        return VStack(spacing: 8) {
            ZStack {
                ringTrack
                Circle()
                    .trim(from: 0, to: CGFloat(min(max(data.socPct, 0), 100) / 100))
                    .stroke(accent, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.5), value: data.socPct)
                if showMarker {
                    Circle()
                        .trim(from: 0, to: 0.004)
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 16, lineCap: .butt))
                        .rotationEffect(.degrees(-90 + effLimit / 100 * 360))
                }
                VStack(spacing: 0) {
                    if data.charging {
                        Image(systemName: "bolt.fill").font(.caption2).foregroundStyle(accent)
                    }
                    Text("\(Int(data.socPct.rounded()))")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(DS.text).contentTransition(.numericText())
                    Text("% SOC").font(.system(size: 10)).foregroundStyle(DS.muted)
                    if data.priceKwh > 0 {
                        Text("\(Fmt.brl(data.priceKwh))/kWh")
                            .font(.system(size: 9, weight: .semibold)).foregroundStyle(DS.green)
                    }
                }
            }
            .frame(width: 120, height: 120)
            gaugeFooter(icon: "bolt.fill", tint: DS.green, value: f0(data.rangeEvKm), unit: "km EV")
        }
        .frame(maxWidth: .infinity)
    }

    // Gauge de gasolina (espelha o da bateria): anel por nível do tanque + litros + R$/L;
    // autonomia térmica no rodapé.
    private var fuelGauge: some View {
        let frac = data.tankL > 0 ? min(max(data.fuelL / data.tankL, 0), 1) : 0
        let tint = DS.orange
        return VStack(spacing: 8) {
            ZStack {
                ringTrack
                Circle()
                    .trim(from: 0, to: CGFloat(frac))
                    .stroke(tint, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.5), value: data.fuelL)
                VStack(spacing: 0) {
                    Text("\(f0(data.fuelL))")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(DS.text)
                    Text("litros").font(.system(size: 10)).foregroundStyle(DS.muted)
                    if data.priceGas > 0 {
                        Text("\(Fmt.brl(data.priceGas))/L")
                            .font(.system(size: 9, weight: .semibold)).foregroundStyle(tint)
                    }
                }
            }
            .frame(width: 120, height: 120)
            gaugeFooter(icon: "fuelpump.fill", tint: tint, value: f0(data.rangeIceKm), unit: "km térmico")
        }
        .frame(maxWidth: .infinity)
    }

    private var ringTrack: some View {
        Circle().stroke(Color.white.opacity(0.10), lineWidth: 12)
    }

    private func gaugeFooter(icon: String, tint: Color, value: String, unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: icon).font(.caption2).foregroundStyle(tint)
            Text(value).font(.system(size: 16, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(DS.text)
            Text(unit).font(.caption2).foregroundStyle(DS.muted)
        }
    }

    private var lockTile: some View {
        let known = data.locked != nil
        let locked = data.locked == true
        return statTile(icon: locked ? "lock.fill" : "lock.open.fill",
                        value: !known ? "—" : (locked ? "Trancado" : "Destranc."),
                        label: "Trava",
                        color: !known ? DS.muted : (locked ? DS.green : DS.orange))
    }

    private func chargeMetric(_ value: String, unit: String, label: String, color: Color) -> some View {
        VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 20, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(color)
                Text(unit).font(.caption2).foregroundStyle(DS.muted)
            }
            Text(label).font(.caption2).foregroundStyle(DS.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func statTile(icon: String, value: String, label: String, color: Color) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon).font(.callout).foregroundStyle(color)
                .frame(height: 18)   // altura fixa: glifos (porta vs trava vs vidro) têm bbox diferente
            Text(value).font(.subheadline.weight(.bold)).foregroundStyle(DS.text)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption2).foregroundStyle(DS.muted)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func tyreTile(_ i: Int, _ pos: String) -> some View {
        let psi = data.tyres[i], temp = data.tyreTemps[i]
        let known = psi > 0
        let ok = !known || psi >= 28
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(pos).font(.caption2.weight(.bold)).foregroundStyle(DS.muted)
                    .lineLimit(1).minimumScaleFactor(0.8)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(known ? f0(psi) : "—").font(.subheadline.weight(.bold)).monospacedDigit()
                        .foregroundStyle(ok ? DS.text : DS.orange)
                    Text("psi").font(.caption2).foregroundStyle(DS.muted)
                    if temp > 0 {
                        Text("· \(f0(temp))°").font(.caption2).foregroundStyle(DS.muted)
                    }
                }
                .lineLimit(1).fixedSize()
            }
            Spacer(minLength: 4)
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(ok ? DS.green : DS.orange)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10).padding(.horizontal, 12)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    CarStatusInfoView(data: CarStatusData(
        locked: false, charging: true, engineOn: false,
        socPct: 64, rangeEvKm: 210, chargePowerKw: 7.2,
        openDoors: ["Diant. dir.", "Porta-malas"],
        openWindows: ["Diant. esq.", "Teto solar"],
        tyres: [34, 34, 26, 33], tyreTemps: [30, 31, 29, 30],
        fuelL: 15, rangeIceKm: 203, priceKwh: 0.64, priceGas: 6.71))
        .padding().background(DS.panel)
}
