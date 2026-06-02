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
    @State private var pending: PendingAction?
    @State private var busy = false

    struct PendingAction: Identifiable {
        let id = UUID(); let name: String; let title: String; let confirm: String; let danger: Bool
    }

    private let tankL = 55.0   // capacidade aprox. do tanque (H6 PHEV) p/ o medidor

    private func f0(_ v: Double) -> String { String(format: "%.0f", v) }
    private func f1(_ v: Double) -> String { String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",") }
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
                HStack(spacing: 14) { batteryCard; fuelCard }
                climateCard
                tyresCard
                doorsCard
                windowsCard
                serviceCard
            }
            .padding(16)
        }
        .background(DS.bg.ignoresSafeArea())
        .onAppear { store.start(); Task { await maint.load() } }
        .confirmationDialog(pending?.title ?? "", isPresented: .init(
            get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { p in
            Button(p.confirm, role: p.danger ? .destructive : nil) {
                busy = true; Task { _ = await store.action(p.name); busy = false; pending = nil }
            }
            Button("Cancelar", role: .cancel) { pending = nil }
        }
    }

    // MARK: localização
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "location.fill").font(.subheadline).foregroundStyle(DS.green)
            Text(store.hasGps ? (store.address.isEmpty ? "Localizando endereço…" : store.address) : "Localização indisponível")
                .font(.subheadline.weight(.medium)).foregroundStyle(DS.text).lineLimit(2)
            Spacer(minLength: 6)
            if store.lanConnected { DSChip(text: "LAN", color: DS.teal, filled: true) }
            Circle().fill(store.carOnline ? DS.green : DS.red).frame(width: 9, height: 9)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
    }

    // MARK: trava + motor (ícones com confirmação)
    private var statusCard: some View {
        DSCard {
            HStack(spacing: 16) {
                iconButton(icon: store.isLocked ? "lock.fill" : "lock.open.fill",
                           tint: store.isLocked ? DS.green : DS.orange,
                           caption: !store.lockKnown ? "—" : (store.isLocked ? "Trancado" : "Destrancado")) {
                    pending = store.isLocked
                        ? .init(name: "lock_open", title: "Destravar carro?", confirm: "Destravar", danger: true)
                        : .init(name: "lock_close", title: "Travar carro?", confirm: "Travar", danger: false)
                }
                iconButton(icon: "power", tint: store.engineOn ? DS.green : DS.muted,
                           caption: store.engineOn ? "Ligado" : "Desligado") {
                    pending = store.engineOn
                        ? .init(name: "engine_off", title: "Desligar motor?", confirm: "Desligar", danger: true)
                        : .init(name: "engine_on", title: "Ligar motor?", confirm: "Ligar", danger: false)
                }
                Spacer()
            }
        }
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

    // MARK: hodômetro + 12V + manutenção
    private var serviceCard: some View {
        DSCard(title: "Veículo", icon: "wrench.and.screwdriver.fill") {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    DSMetric(value: store.odometerKm > 0 ? miles(store.odometerKm) : "—", unit: "km", label: "Hodômetro")
                    if store.batt12vPct > 0 { DSMetric(value: f0(store.batt12vPct), unit: "%", label: "Bateria 12V") }
                }
                if !maint.items.isEmpty {
                    Divider().overlay(DS.border)
                    ForEach(maint.items.prefix(3)) { m in
                        HStack(spacing: 8) {
                            Circle().fill(m.statusColor).frame(width: 8, height: 8)
                            Text(m.label ?? "Manutenção").font(.system(size: 13, weight: .medium)).foregroundStyle(DS.text)
                            Spacer()
                            Text(maintWhen(m)).font(.caption).foregroundStyle(DS.muted)
                        }
                    }
                }
            }
        }
    }

    private func maintWhen(_ m: MaintItem) -> String {
        if let km = m.remaining_km {
            if km <= 0 { return "vencida" }
            return "faltam \(miles(km)) km"
        }
        if let d = m.remaining_days {
            if d <= 0 { return "vencida" }
            return "faltam \(f0(d)) dias"
        }
        return ""
    }
}
