//
//  NativeDashView.swift
//  Dash NATIVA piloto (Bloco 0/1 da migração). Consome o CarStore ao vivo.
//

import SwiftUI

struct NativeDashView: View {
    @ObservedObject private var store = CarStore.shared

    // Potência: azul = consumindo (positivo) · verde = regenerando (negativo)
    private var powerColor: Color {
        let p = store.motorPowerKw
        if p <= -0.1 { return DS.green }
        if p >=  0.1 { return DS.blue }
        return DS.text
    }

    private func f1(_ v: Double) -> String { String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",") }
    private func f0(_ v: Double) -> String { String(format: "%.0f", v) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    // Velocidade — herói
                    DSCard {
                        VStack(spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(f0(store.speedKmh))
                                    .font(.system(size: 92, weight: .light, design: .rounded))
                                    .foregroundStyle(DS.text).monospacedDigit()
                                Text("km/h").font(.title3).foregroundStyle(DS.muted)
                            }
                            HStack(spacing: 6) {
                                Text(f1(store.motorPowerKw)).font(.title.weight(.semibold))
                                    .foregroundStyle(powerColor).monospacedDigit()
                                Text("kW").foregroundStyle(DS.muted)
                                if store.engineRpm > 0 {
                                    Text("·").foregroundStyle(DS.muted)
                                    Text("\(store.engineRpm) rpm").foregroundStyle(DS.muted)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }

                    // SOC + autonomia
                    DSCard(title: "Bateria", icon: "bolt.fill") {
                        HStack {
                            DSMetric(value: f0(store.socPct), unit: "%", label: "SOC", color: DS.green)
                            DSMetric(value: f0(store.rangeEvKm), unit: "km", label: "Autonomia EV", color: DS.teal)
                        }
                    }

                    // Temperaturas
                    DSCard(title: "Temperatura", icon: "thermometer.medium") {
                        HStack {
                            DSMetric(value: f0(store.insideTemp), unit: "°", label: "Interna")
                            DSMetric(value: f0(store.outsideTemp), unit: "°", label: "Externa")
                        }
                    }
                }
                .padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Painel")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 6) {
                        Circle().fill(store.carOnline ? DS.green : DS.red).frame(width: 8, height: 8)
                        if !store.gear.isEmpty { DSChip(text: store.gear, color: DS.blue, filled: true) }
                    }
                }
            }
        }
        .onAppear { store.start() }
    }
}
