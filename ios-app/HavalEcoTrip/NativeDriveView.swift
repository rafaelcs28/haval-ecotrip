//
//  NativeDriveView.swift
//  Aba Drive NATIVA (Bloco 1) — viagem em curso + status de condução (leitura).
//  Os controles interativos (trocar modo/regen/one-pedal/ESP) entram no Bloco 2.
//

import SwiftUI

struct NativeDriveView: View {
    @ObservedObject private var store = CarStore.shared

    private var powerColor: Color {
        let p = store.motorPowerKw
        if p <= -0.1 { return DS.green }
        if p >=  0.1 { return DS.blue }
        return DS.text
    }
    private func f1(_ v: Double) -> String { String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",") }
    private func f0(_ v: Double) -> String { String(format: "%.0f", v) }
    private func timeStr(_ s: Int) -> String {
        let h = s / 3600, m = (s % 3600) / 60
        return h > 0 ? "\(h)h \(m)min" : "\(m) min"
    }
    private var consumo: Double { store.tripDistKm > 0.5 ? store.tripNetKwh / store.tripDistKm * 100 : 0 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    // Velocidade + potência
                    DSCard {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(f0(store.speedKmh))
                                .font(.system(size: 72, weight: .light, design: .rounded))
                                .foregroundStyle(DS.text).monospacedDigit()
                            VStack(alignment: .leading, spacing: 2) {
                                Text("km/h").foregroundStyle(DS.muted)
                                HStack(spacing: 4) {
                                    Text(f1(store.motorPowerKw)).font(.title3.weight(.semibold)).foregroundStyle(powerColor)
                                    Text("kW").font(.caption).foregroundStyle(DS.muted)
                                }
                            }
                            Spacer()
                        }
                    }

                    // Viagem em curso
                    DSCard(title: "Viagem em curso", icon: "location.fill") {
                        if store.tripActive {
                            VStack(spacing: 14) {
                                HStack {
                                    DSMetric(value: f1(store.tripDistKm), unit: "km", label: "Distância", color: DS.teal)
                                    DSMetric(value: timeStr(store.tripTimeSec), label: "Tempo")
                                    DSMetric(value: f1(store.tripNetKwh), unit: "kWh", label: "Energia (net)", color: DS.green)
                                }
                                HStack {
                                    DSMetric(value: consumo > 0 ? f1(consumo) : "—", unit: "kWh/100", label: "Consumo")
                                    DSMetric(value: f0(store.tripAvgKmh), unit: "km/h", label: "Vel. média")
                                    if store.tripFuelL > 0.05 {
                                        DSMetric(value: f1(store.tripFuelL), unit: "L", label: "Gasolina", color: DS.orange)
                                    }
                                }
                            }
                        } else {
                            Text("Nenhuma viagem em andamento.")
                                .font(.subheadline).foregroundStyle(DS.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    // Status de condução (leitura — controles no Bloco 2)
                    DSCard(title: "Condução", icon: "steeringwheel") {
                        FlowChips(chips: [
                            ("Modo", store.driveModeLabel),
                            ("Regen", store.regenLabel),
                            ("One-Pedal", store.onePedalOn ? "Ligado" : "Desligado"),
                            ("ESP", store.espOn ? "Ligado" : "Desligado"),
                        ])
                    }
                }
                .padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Drive")
        }
        .onAppear { store.start() }
    }
}

/// Linha de status rotulados (rótulo em cima, valor em chip).
private struct FlowChips: View {
    let chips: [(String, String)]
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            ForEach(chips, id: \.0) { c in
                VStack(alignment: .leading, spacing: 4) {
                    Text(c.0.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.muted)
                    Text(c.1.isEmpty ? "—" : c.1).font(.system(size: 16, weight: .bold)).foregroundStyle(DS.text)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
