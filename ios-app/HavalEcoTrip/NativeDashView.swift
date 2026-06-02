//
//  NativeDashView.swift
//  Aba Painel — visão do carro parado: localização, trava/motor (ícones),
//  energia (bateria + tanque por nível), clima, e cards colapsáveis de pneus,
//  portas e vidros (abrem sozinhos em anomalia) + hodômetro/12V/manutenção.
//

import SwiftUI

struct NativeDashView: View {
    @ObservedObject private var store = CarStore.shared
    @StateObject private var maint = MaintenanceStore()
    @StateObject private var trips = TripsLoader()
    @State private var busy = false
    @State private var showPreclimat = false
    @State private var showMaint = false
    @State private var showLock = false
    @State private var showEngine = false

    private let tankL = 55.0   // capacidade aprox. do tanque (H6 PHEV) p/ o medidor

    private func f0(_ v: Double) -> String { String(format: "%.0f", v) }
    private func f1(_ v: Double) -> String { String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",") }
    private func brl(_ v: Double) -> String { Fmt.brl(v) }
    private static let grp: NumberFormatter = {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.groupingSeparator = "."; f.maximumFractionDigits = 0; return f
    }()
    private func miles(_ v: Double) -> String { Self.grp.string(from: NSNumber(value: v)) ?? f0(v) }

    // Aberturas separadas (chave 'on' = aberto)
    private func openList(_ map: [(String, String)]) -> [String] { map.filter { store.str($0.0) == "on" }.map { $0.1 } }
    private var doorsMap: [(String, String)] { [("door_fl","Diant. esq."),("door_fr","Diant. dir."),("door_rl","Tras. esq."),("door_rr","Tras. dir."),("door_trunk","Porta-malas")] }
    private var windowsMap: [(String, String)] { [("window_fl","Vidro diant. esq."),("window_fr","Vidro diant. dir."),("window_rl","Vidro tras. esq."),("window_rr","Vidro tras. dir."),("sunroof","Teto solar")] }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header
                statusCard
                if store.isCharging { chargingCard } else { HStack(spacing: 14) { batteryCard; fuelCard } }
                costPerKmCard
                climateCard
                tyresCard
                doorsCard
                windowsCard
                revisaoCard
                tripCard
            }
            .padding(16)
        }
        .background(DS.bg.ignoresSafeArea())
        .onAppear { store.start(); Task { await maint.load() }; Task { await trips.load() } }
        .sheet(isPresented: $showPreclimat) { PreclimatSheet() }
        .sheet(isPresented: $showMaint) { MaintenanceSheet(store: maint) }
    }

    // MARK: localização
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "location.fill").font(.subheadline).foregroundStyle(DS.green)
            Text(store.hasGps ? (store.address.isEmpty ? "Localizando endereço…" : store.address) : "Localização indisponível")
                .font(.subheadline.weight(.medium)).foregroundStyle(DS.text).lineLimit(2)
            Spacer(minLength: 6)
            if store.lanConnected { DSChip(text: "LAN", color: DS.teal, filled: true) }
            Text(lastUpdateText).font(.system(size: 10)).foregroundStyle(DS.muted).lineLimit(1)
            Circle().fill(store.carOnline ? DS.green : DS.red).frame(width: 9, height: 9)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
    }

    private var lastUpdateText: String {
        let ms = store.num("last_apk_ms")
        guard ms > 0 else { return "" }
        let age = Date().timeIntervalSince1970 - ms / 1000
        if age < 60 { return "há \(Int(max(0, age)))s" }
        if age < 3600 { return "há \(Int(age/60))min" }
        if age < 86400 { return "há \(Int(age/3600))h" }
        return "há \(Int(age/86400))d"
    }

    // MARK: trava + motor (ícones com confirmação ancorada) + hodômetro/12V ao lado
    private var statusCard: some View {
        DSCard {
            HStack(spacing: 16) {
                iconButton(icon: store.isLocked ? "lock.fill" : "lock.open.fill",
                           tint: store.isLocked ? DS.green : DS.orange,
                           caption: !store.lockKnown ? "—" : (store.isLocked ? "Trancado" : "Destrancado")) {
                    showLock = true
                }
                .popover(isPresented: $showLock) {
                    confirmPopover(title: store.isLocked ? "Destravar carro?" : "Travar carro?",
                                   confirm: store.isLocked ? "Destravar" : "Travar", danger: store.isLocked,
                                   name: store.isLocked ? "lock_open" : "lock_close", binding: $showLock)
                }
                iconButton(icon: "power", tint: store.engineOn ? DS.green : DS.muted,
                           caption: store.engineOn ? "Ligado" : "Desligado") {
                    showEngine = true
                }
                .popover(isPresented: $showEngine) {
                    confirmPopover(title: store.engineOn ? "Desligar motor?" : "Ligar motor?",
                                   confirm: store.engineOn ? "Desligar" : "Ligar", danger: store.engineOn,
                                   name: store.engineOn ? "engine_off" : "engine_on", binding: $showEngine)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 10) {
                    rightMetric("Hodômetro", store.odometerKm > 0 ? "\(miles(store.odometerKm)) km" : "—")
                    if store.batt12vPct > 0 { rightMetric("Bateria 12V", "\(f0(store.batt12vPct))%") }
                }
            }
        }
    }

    private func rightMetric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value).font(.system(size: 18, weight: .semibold, design: .rounded)).foregroundStyle(DS.text).lineLimit(1).minimumScaleFactor(0.6)
            Text(label.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(DS.muted)
        }
    }

    private func confirmPopover(title: String, confirm: String, danger: Bool, name: String, binding: Binding<Bool>) -> some View {
        VStack(spacing: 14) {
            Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(DS.text).multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button("Cancelar") { binding.wrappedValue = false }
                    .frame(maxWidth: .infinity).frame(height: 44).foregroundStyle(DS.text).background(DS.panel2).clipShape(RoundedRectangle(cornerRadius: 11))
                Button(confirm) { binding.wrappedValue = false; busy = true; Task { _ = await store.action(name); busy = false } }
                    .frame(maxWidth: .infinity).frame(height: 44).foregroundStyle(.black).background(danger ? DS.red : DS.green).clipShape(RoundedRectangle(cornerRadius: 11)).font(.system(size: 15, weight: .bold))
            }
        }
        .padding(18).frame(width: 280).background(DS.panel)
        .presentationCompactAdaptation(.popover)
    }

    private func iconButton(icon: String, tint: Color, caption: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 22, weight: .medium)).foregroundStyle(tint)
                    .frame(width: 56, height: 56).background(DS.panel2).clipShape(Circle())
                    .overlay(Circle().stroke(DS.border, lineWidth: 1))
                Text(caption).font(.system(size: 11, weight: .medium)).foregroundStyle(DS.muted)
            }
        }
        .buttonStyle(.plain).disabled(busy)
    }

    // MARK: energia
    private func batteryIcon(_ soc: Double) -> String {
        switch soc { case ..<13: return "battery.0percent"; case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"; case ..<88: return "battery.75percent"; default: return "battery.100percent" }
    }
    private var batteryCard: some View {
        let soc = store.socPct
        let tint: Color = soc < 20 ? DS.red : (soc < 50 ? DS.yellow : DS.green)
        return DSCard {
            VStack(alignment: .leading, spacing: 10) {
                LevelBadge(icon: batteryIcon(soc), fraction: soc/100, value: f0(soc), unit: "%", label: "Bateria", tint: tint)
                Text("\(f0(store.rangeEvKm)) km EV").font(.caption).foregroundStyle(DS.muted)
            }
        }
    }

    // Recarregando: bateria expandida (esconde tanque) + dados da carga atual
    private var chargingCard: some View {
        let soc = store.socPct
        return DSCard(title: "Carregando", icon: "bolt.fill") {
            VStack(alignment: .leading, spacing: 12) {
                LevelBadge(icon: batteryIcon(soc), fraction: soc/100, value: f0(soc), unit: "%", label: "Bateria", tint: DS.green)
                HStack {
                    DSMetric(value: f1(store.chargePowerKw), unit: "kW", label: "Potência", color: DS.green)
                    DSMetric(value: f1(store.chargeSessionKwh), unit: "kWh", label: "Sessão", color: DS.teal)
                    DSMetric(value: store.chargeRemainingMin > 0 ? "\(store.chargeRemainingMin)" : "—", unit: "min", label: "Faltam")
                    DSMetric(value: f0(store.rangeEvKm), unit: "km", label: "Autonomia")
                }
            }
        }
    }

    // Custo por km atual (EV e gasolina)
    @ViewBuilder private var costPerKmCard: some View {
        if store.costPerKmEv > 0 || store.costPerKmGas > 0 {
            DSCard {
                HStack {
                    DSMetric(value: store.costPerKmEv > 0 ? brl(store.costPerKmEv) : "—", label: "R$/km EV", color: DS.green)
                    DSMetric(value: store.costPerKmGas > 0 ? brl(store.costPerKmGas) : "—", label: "R$/km Gasolina", color: DS.orange)
                }
            }
        }
    }
    private var fuelCard: some View {
        let frac = min(1, store.fuelL / tankL)
        let tint: Color = frac < 0.15 ? DS.red : (frac < 0.35 ? DS.yellow : DS.orange)
        return DSCard {
            VStack(alignment: .leading, spacing: 10) {
                LevelBadge(icon: "fuelpump.fill", fraction: frac, value: f0(store.fuelL), unit: "L", label: "Tanque", tint: tint)
                Text("\(f0(store.rangeIceKm)) km térmico").font(.caption).foregroundStyle(DS.muted)
            }
        }
    }

    // MARK: clima (compacto)
    private var climateCard: some View {
        let acActive = store.acOn
        return DSCard {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: acActive ? "snowflake" : "thermometer.medium")
                        .font(.title3).foregroundStyle(acActive ? DS.blue : DS.muted)
                    Text("\(f0(store.insideTemp))°").font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundStyle(DS.text)
                    Text("interna").font(.caption).foregroundStyle(DS.muted)
                    Spacer()
                    Text("\(f0(store.outsideTemp))°").font(.system(size: 16, weight: .medium)).foregroundStyle(DS.text)
                    Text("externa").font(.caption).foregroundStyle(DS.muted)
                    if acActive { DSChip(text: "AC", color: DS.blue, filled: true) }
                }
                Button { showPreclimat = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "fan.fill").font(.subheadline)
                        Text("Pré-climatização").font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(DS.muted)
                    }
                    .foregroundStyle(DS.text).frame(maxWidth: .infinity).frame(height: 44).padding(.horizontal, 14)
                    .background(DS.panel2).clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(DS.border, lineWidth: 1))
                }
            }
        }
    }

    // MARK: pneus (colapsável; abre em anomalia <28 psi)
    private var tyresCard: some View {
        let ps = ["tyre_pressure_fl","tyre_pressure_fr","tyre_pressure_rl","tyre_pressure_rr"].map { store.num($0) }
        let low = ps.contains { $0 > 0 && $0 < 28 }
        let summary = ps.allSatisfy { $0 <= 0 } ? "sem dados" : ps.map { $0 <= 0 ? "—" : f0($0) }.joined(separator: "/") + " psi"
        func tyre(_ pk: String, _ tk: String, _ label: String) -> some View {
            let p = store.num(pk), t = store.num(tk)
            return VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(p <= 0 ? "—" : f0(p)).font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(p > 0 && p < 28 ? DS.red : DS.text).monospacedDigit()
                    Text("psi").font(.system(size: 11)).foregroundStyle(DS.muted)
                    if t > 0 { Text("· \(f0(t))°").font(.system(size: 11)).foregroundStyle(DS.muted) }
                }
                Text(label.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(DS.muted)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        return CollapsibleCard(icon: "circle.grid.2x2.fill", title: "Pneus", summary: summary, alert: low) {
            VStack(spacing: 12) {
                HStack { tyre("tyre_pressure_fl","tyre_temp_fl","Diant. Esq."); tyre("tyre_pressure_fr","tyre_temp_fr","Diant. Dir.") }
                HStack { tyre("tyre_pressure_rl","tyre_temp_rl","Tras. Esq.");  tyre("tyre_pressure_rr","tyre_temp_rr","Tras. Dir.") }
            }
        }
    }

    // MARK: portas (colapsável; abre se alguma aberta)
    private var doorsCard: some View {
        let open = openList(doorsMap)
        return CollapsibleCard(icon: "car.door.front.left.open", title: "Portas",
                               summary: open.isEmpty ? "Tudo fechado" : open.joined(separator: ", "), alert: !open.isEmpty) {
            VStack(spacing: 8) {
                ForEach(doorsMap, id: \.0) { k, label in stateRow(label, store.str(k) == "on") }
            }
        }
    }

    // MARK: vidros + teto (colapsável; abre se algo aberto)
    private var windowsCard: some View {
        let open = openList(windowsMap)
        return CollapsibleCard(icon: "macwindow", title: "Vidros / Teto",
                               summary: open.isEmpty ? "Tudo fechado" : open.joined(separator: ", "), alert: !open.isEmpty) {
            VStack(spacing: 8) {
                ForEach(windowsMap, id: \.0) { k, label in stateRow(label, store.str(k) == "on") }
            }
        }
    }

    private func stateRow(_ label: String, _ open: Bool) -> some View {
        HStack {
            Text(label).font(.system(size: 14)).foregroundStyle(DS.text)
            Spacer()
            Text(open ? "Aberto" : "Fechado").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(open ? DS.yellow : DS.muted)
        }
    }

    // MARK: revisão (botão → popup com tudo)
    private var revisaoCard: some View {
        let next = maint.items.first
        return DSCard {
            Button { showMaint = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "wrench.and.screwdriver.fill").font(.subheadline).foregroundStyle(DS.muted)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Revisão").font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.text)
                        Text(next.map { "\($0.label ?? "Próxima") · \(maintWhen($0))" } ?? "Ver histórico e custos")
                            .font(.caption).foregroundStyle(DS.muted)
                    }
                    Spacer()
                    if let n = next { Circle().fill(n.statusColor).frame(width: 9, height: 9) }
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(DS.muted)
                }
            }.buttonStyle(.plain)
        }
    }

    private func maintWhen(_ m: MaintItem) -> String {
        if let km = m.remaining_km { return km <= 0 ? "vencida" : "faltam \(miles(km)) km" }
        if let d = m.remaining_days { return d <= 0 ? "vencida" : "faltam \(f0(d)) dias" }
        return ""
    }

    // MARK: viagem em andamento (ou última)
    @ViewBuilder private var tripCard: some View {
        if store.tripActive {
            DSCard(title: "Viagem em andamento", icon: "car.fill") {
                tripMetrics(distKm: store.tripDistKm, timeSec: Double(store.tripTimeSec),
                            netKwh: store.tripNetKwh, fuelL: store.tripFuelL)
            }
        } else if let t = trips.trips.first {
            DSCard(title: "Última viagem", icon: "car.fill") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(lastTripDate(t)).font(.caption).foregroundStyle(DS.muted).frame(maxWidth: .infinity, alignment: .leading)
                    tripMetrics(distKm: t.distKm, timeSec: t.timeSec, netKwh: t.netKwh, fuelL: t.fuelL)
                }
            }
        }
    }

    private func tripMetrics(distKm: Double, timeSec: Double, netKwh: Double, fuelL: Double) -> some View {
        let cons = distKm > 0.5 ? netKwh / distKm * 100 : 0
        let h = Int(timeSec) / 3600, m = (Int(timeSec) % 3600) / 60
        return HStack {
            DSMetric(value: f1(distKm), unit: "km", label: "Distância", color: DS.teal)
            DSMetric(value: h > 0 ? "\(h)h \(m)min" : "\(m) min", label: "Tempo")
            DSMetric(value: f1(netKwh), unit: "kWh", label: "Energia", color: DS.green)
            DSMetric(value: cons > 0 ? f1(cons) : "—", unit: "kWh/100", label: "Consumo")
        }
    }

    private static let tripDF: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR"); f.dateFormat = "d MMM · HH:mm"; return f }()
    private func lastTripDate(_ t: Trip) -> String { Self.tripDF.string(from: t.date) }
}
