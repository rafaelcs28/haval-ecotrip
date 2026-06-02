//
//  NativeDashView.swift
//  Aba Painel NATIVA — visão geral do carro parado: localização, trava/aberturas,
//  ações (destravar/ligar motor), energia (bateria EV + tanque), clima, pneus.
//  Velocidade/potência/marcha vivem na aba Drive.
//

import SwiftUI

struct NativeDashView: View {
    @ObservedObject private var store = CarStore.shared
    @State private var pending: PendingAction?
    @State private var busy = false

    struct PendingAction: Identifiable {
        let id = UUID(); let name: String; let title: String; let confirm: String; let danger: Bool
    }

    private func f0(_ v: Double) -> String { String(format: "%.0f", v) }
    private func f1(_ v: Double) -> String { String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",") }
    private static let grp: NumberFormatter = {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.groupingSeparator = "."; f.maximumFractionDigits = 0; return f
    }()
    private func miles(_ v: Double) -> String { Self.grp.string(from: NSNumber(value: v)) ?? f0(v) }
    private func tyreColor(_ p: Double) -> Color { p <= 0 ? DS.muted : (p < 28 ? DS.red : DS.text) }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header
                statusActionsCard
                HStack(spacing: 14) { batteryCard; fuelCard }
                climateCard
                tyresCard
                odometerCard
            }
            .padding(16)
        }
        .background(DS.bg.ignoresSafeArea())
        .onAppear { store.start() }
        .confirmationDialog(pending?.title ?? "", isPresented: .init(
            get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { p in
            Button(p.confirm, role: p.danger ? .destructive : nil) {
                busy = true
                Task { _ = await store.action(p.name); busy = false; pending = nil }
            }
            Button("Cancelar", role: .cancel) { pending = nil }
        }
    }

    // Localização (endereço) + status online
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "location.fill").font(.subheadline).foregroundStyle(DS.green)
            Text(store.hasGps ? (store.address.isEmpty ? "Localizando endereço…" : store.address)
                              : "Localização indisponível")
                .font(.subheadline.weight(.medium)).foregroundStyle(DS.text)
                .lineLimit(2)
            Spacer(minLength: 6)
            Circle().fill(store.carOnline ? DS.green : DS.red).frame(width: 9, height: 9)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    // Trava + aberturas + botões de ação
    private var statusActionsCard: some View {
        DSCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: store.isLocked ? "lock.fill" : "lock.open.fill")
                        .foregroundStyle(store.isLocked ? DS.green : DS.orange)
                    Text(!store.lockKnown ? "Trava: desconhecida" : (store.isLocked ? "Trancado" : "Destrancado"))
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(DS.text)
                    Spacer()
                    if store.engineOn {
                        DSChip(text: "Motor ligado", color: DS.orange, filled: true)
                    }
                }
                if !store.openings.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.yellow)
                        Text("Aberto: " + store.openings.joined(separator: ", "))
                            .font(.caption).foregroundStyle(DS.yellow)
                    }
                }
                HStack(spacing: 10) {
                    DSActionButton(icon: store.isLocked ? "lock.open.fill" : "lock.fill",
                                   title: store.isLocked ? "Destravar" : "Travar",
                                   color: store.isLocked ? DS.blue : DS.muted, busy: busy) {
                        pending = store.isLocked
                            ? .init(name: "lock_open", title: "Destravar carro?", confirm: "Destravar", danger: true)
                            : .init(name: "lock_close", title: "Travar carro?", confirm: "Travar", danger: false)
                    }
                    DSActionButton(icon: "power",
                                   title: store.engineOn ? "Desligar" : "Ligar motor",
                                   color: store.engineOn ? DS.muted : DS.green, busy: busy) {
                        pending = store.engineOn
                            ? .init(name: "engine_off", title: "Desligar motor?", confirm: "Desligar", danger: true)
                            : .init(name: "engine_on", title: "Ligar motor?", confirm: "Ligar", danger: false)
                    }
                }
            }
        }
    }

    private var batteryCard: some View {
        DSCard(title: "Bateria", icon: "bolt.fill") {
            VStack(alignment: .leading, spacing: 10) {
                DSMetric(value: f0(store.socPct), unit: "%", label: "SOC", color: DS.green)
                DSMetric(value: f0(store.rangeEvKm), unit: "km", label: "Autonomia EV", color: DS.teal)
            }
        }
    }

    private var fuelCard: some View {
        DSCard(title: "Combustível", icon: "fuelpump.fill") {
            VStack(alignment: .leading, spacing: 10) {
                DSMetric(value: f0(store.fuelL), unit: "L", label: "Tanque", color: DS.orange)
                DSMetric(value: f0(store.rangeIceKm), unit: "km", label: "Autonomia térmica")
            }
        }
    }

    private var climateCard: some View {
        let acActive = store.engineOn && store.acOn
        return DSCard(title: "Clima", icon: acActive ? "snowflake" : "thermometer.medium", glass: false) {
            HStack {
                DSMetric(value: f0(store.insideTemp), unit: "°", label: "Interna")
                DSMetric(value: f0(store.outsideTemp), unit: "°", label: "Externa")
                if acActive {
                    DSMetric(value: "ON", label: "Ar-cond.", color: DS.blue)
                }
            }
        }
        .overlay(acActive ? RoundedRectangle(cornerRadius: 18).stroke(DS.blue.opacity(0.6), lineWidth: 1.5) : nil)
    }

    private var tyresCard: some View {
        func tyre(_ pKey: String, _ tKey: String, _ label: String) -> some View {
            let p = store.num(pKey); let t = store.num(tKey)
            return VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(p <= 0 ? "—" : f0(p)).font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundStyle(tyreColor(p)).monospacedDigit()
                    Text("psi").font(.system(size: 11)).foregroundStyle(DS.muted)
                    if t > 0 { Text("· \(f0(t))°").font(.system(size: 11)).foregroundStyle(DS.muted) }
                }
                Text(label.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(DS.muted)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        return DSCard(title: "Pneus", icon: "circle.grid.2x2.fill") {
            VStack(spacing: 12) {
                HStack { tyre("tyre_pressure_fl", "tyre_temp_fl", "Diant. Esq."); tyre("tyre_pressure_fr", "tyre_temp_fr", "Diant. Dir.") }
                HStack { tyre("tyre_pressure_rl", "tyre_temp_rl", "Tras. Esq.");  tyre("tyre_pressure_rr", "tyre_temp_rr", "Tras. Dir.") }
            }
        }
    }

    private var odometerCard: some View {
        DSCard {
            HStack {
                DSMetric(value: store.odometerKm > 0 ? miles(store.odometerKm) : "—", unit: "km", label: "Hodômetro")
                if store.batt12vPct > 0 {
                    DSMetric(value: f0(store.batt12vPct), unit: "%", label: "Bateria 12V")
                }
            }
        }
    }
}
