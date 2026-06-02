//
//  NativeDashView.swift
//  Painel NATIVO (Bloco 1). Mapa de fundo com a localização em destaque
//  (entorno escurecido) + número limpo + cards translúcidos por cima.
//

import SwiftUI
import MapKit

// MARK: - Mapa de fundo (localização atual evidente, resto escurecido)
struct MapBackground: View {
    let lat: Double
    let lng: Double
    @State private var cam: MapCameraPosition = .automatic

    private var coord: CLLocationCoordinate2D { .init(latitude: lat, longitude: lng) }
    private func recenter() {
        cam = .region(MKCoordinateRegion(center: coord,
                                         span: MKCoordinateSpan(latitudeDelta: 0.006, longitudeDelta: 0.006)))
    }

    var body: some View {
        Map(position: $cam, interactionModes: []) {
            Annotation("", coordinate: coord) {
                ZStack {
                    Circle().fill(DS.green.opacity(0.22)).frame(width: 46, height: 46)
                    Circle().fill(DS.green).frame(width: 16, height: 16)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .shadow(color: DS.green.opacity(0.6), radius: 6)
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .onAppear { recenter() }
        .onChange(of: lat) { _, _ in recenter() }
        .onChange(of: lng) { _, _ in recenter() }
        .overlay(
            // só o centro (carro) fica evidente; o entorno escurece
            RadialGradient(colors: [.clear, .black.opacity(0.55), .black.opacity(0.92)],
                           center: .center, startRadius: 70, endRadius: 380)
        )
        .overlay(
            LinearGradient(colors: [.black.opacity(0.65), .clear, .clear, .black.opacity(0.75)],
                           startPoint: .top, endPoint: .bottom)
        )
        .ignoresSafeArea()
    }
}

struct NativeDashView: View {
    @ObservedObject private var store = CarStore.shared

    private var powerColor: Color {
        let p = store.motorPowerKw
        if p <= -0.1 { return DS.green }
        if p >=  0.1 { return DS.blue }
        return DS.text
    }
    private func f1(_ v: Double) -> String { String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",") }
    private func f0(_ v: Double) -> String { String(format: "%.0f", v) }
    private func tyreColor(_ p: Double) -> Color { p <= 0 ? DS.muted : (p < 28 ? DS.red : DS.text) }
    private func tyreStr(_ p: Double) -> String { p <= 0 ? "—" : f0(p) }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                if store.hasGps { MapBackground(lat: store.lat, lng: store.lng) }
                else { DS.bg.ignoresSafeArea() }

                ScrollView {
                    VStack(spacing: 14) {
                        // Velocidade — número limpo (sem arco)
                        DSCard(glass: true) {
                            VStack(spacing: 2) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(f0(store.speedKmh))
                                        .font(.system(size: 88, weight: .light, design: .rounded))
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
                            }.frame(maxWidth: .infinity)
                        }

                        // Recarga (só quando carregando)
                        if store.isCharging {
                            DSCard(title: "Carregando", icon: "bolt.fill", glass: true) {
                                HStack {
                                    DSMetric(value: f1(store.chargePowerKw), unit: "kW", label: "Potência", color: DS.green)
                                    DSMetric(value: f1(store.chargeSessionKwh), unit: "kWh", label: "Sessão", color: DS.teal)
                                    DSMetric(value: store.chargeRemainingMin > 0 ? "\(store.chargeRemainingMin)" : "—", unit: "min", label: "Faltam")
                                }
                            }
                        }

                        // Bateria + autonomia + 12V
                        DSCard(title: "Bateria", icon: "bolt.fill", glass: true) {
                            HStack {
                                DSMetric(value: f0(store.socPct), unit: "%", label: "SOC", color: DS.green)
                                DSMetric(value: f0(store.rangeEvKm), unit: "km", label: "Autonomia EV", color: DS.teal)
                                if store.batt12vPct > 0 {
                                    DSMetric(value: f0(store.batt12vPct), unit: "%", label: "12V")
                                }
                            }
                        }

                        // Pneus
                        DSCard(title: "Pneus (PSI)", icon: "car.side.rear.and.tire.marks", glass: true) {
                            HStack {
                                DSMetric(value: tyreStr(store.tyreFL), label: "Diant. Esq.", color: tyreColor(store.tyreFL))
                                DSMetric(value: tyreStr(store.tyreFR), label: "Diant. Dir.", color: tyreColor(store.tyreFR))
                                DSMetric(value: tyreStr(store.tyreRL), label: "Tras. Esq.", color: tyreColor(store.tyreRL))
                                DSMetric(value: tyreStr(store.tyreRR), label: "Tras. Dir.", color: tyreColor(store.tyreRR))
                            }
                        }

                        // Temperatura
                        DSCard(title: "Temperatura", icon: "thermometer.medium", glass: true) {
                            HStack {
                                DSMetric(value: f0(store.insideTemp), unit: "°", label: "Interna")
                                DSMetric(value: f0(store.outsideTemp), unit: "°", label: "Externa")
                                if store.odometerKm > 0 {
                                    DSMetric(value: f0(store.odometerKm), unit: "km", label: "Hodômetro", color: DS.muted)
                                }
                            }
                        }
                    }
                    .padding(16)
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Painel")
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 6) {
                        Circle().fill(store.carOnline ? DS.green : DS.red).frame(width: 8, height: 8)
                        if !store.gearDisplay.isEmpty { DSChip(text: store.gearDisplay, color: DS.blue, filled: true) }
                    }
                }
            }
        }
        .onAppear { store.start() }
    }
}
