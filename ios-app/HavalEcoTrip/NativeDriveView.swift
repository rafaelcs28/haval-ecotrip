//
//  NativeDriveView.swift
//  Aba Drive NATIVA — condução ao vivo: velocidade, potências, mapa em tempo
//  real, viagem em curso e resumo. Controles e AC abrem em sheets full-screen.
//

import SwiftUI
import MapKit

struct NativeDriveView: View {
    @ObservedObject private var store = CarStore.shared
    @State private var showControls = false
    @State private var showAC = false

    private var powerColor: Color {
        let p = store.motorPowerKw
        if p <= -0.1 { return DS.green }
        if p >=  0.1 { return DS.blue }
        return DS.text
    }
    private func f0(_ v: Double) -> String { String(format: "%.0f", v) }
    private func f1(_ v: Double) -> String { String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",") }
    private func timeStr(_ s: Int) -> String { let h = s/3600, m = (s%3600)/60; return h > 0 ? "\(h)h \(m)min" : "\(m) min" }
    private var consumo: Double { store.tripDistKm > 0.5 ? store.tripNetKwh / store.tripDistKm * 100 : 0 }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                speedCard
                if store.hasGps { LiveMapCard(lat: store.lat, lng: store.lng) }
                if store.tripActive { tripCard }
                statusCard
            }
            .padding(16)
        }
        .background(DS.bg.ignoresSafeArea())
        .onAppear { store.start() }
        .sheet(isPresented: $showControls) { DriveControlsSheet() }
        .sheet(isPresented: $showAC) { ACSheet() }
    }

    // Velocidade centralizada + potências (elétrico | térmico) lado a lado
    private var speedCard: some View {
        DSCard {
            VStack(spacing: 14) {
                HStack(spacing: 8) {
                    Circle().fill(store.carOnline ? DS.green : DS.red).frame(width: 8, height: 8)
                    if !store.gearDisplay.isEmpty { DSChip(text: store.gearDisplay, color: DS.blue, filled: true) }
                    Spacer()
                }
                VStack(spacing: -4) {
                    Text(f0(store.speedKmh))
                        .font(.system(size: 96, weight: .light, design: .rounded))
                        .foregroundStyle(DS.text).monospacedDigit()
                    Text("km/h").font(.title3).foregroundStyle(DS.muted)
                }
                .frame(maxWidth: .infinity)
                HStack(spacing: 12) {
                    powerCell(value: f1(store.motorPowerKw), unit: "kW", label: "Motor elétrico", color: powerColor)
                    Divider().frame(height: 36).overlay(DS.border)
                    powerCell(value: store.engineRpm > 0 ? "\(store.engineRpm)" : "—",
                              unit: "rpm", label: "Motor térmico", color: store.engineRpm > 0 ? DS.orange : DS.muted)
                }
            }
        }
    }

    private func powerCell(value: String, unit: String, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: 28, weight: .semibold, design: .rounded)).foregroundStyle(color).monospacedDigit()
                Text(unit).font(.system(size: 13)).foregroundStyle(DS.muted)
            }
            Text(label.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.muted)
        }.frame(maxWidth: .infinity)
    }

    private var tripCard: some View {
        DSCard(title: "Viagem em curso", icon: "location.fill") {
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
        }
    }

    // Resumo de condução + botões pros sheets
    private var statusCard: some View {
        DSCard(title: "Condução", icon: "steeringwheel") {
            VStack(spacing: 14) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    summary("Modo", store.driveModeLabel)
                    summary("Regen", store.regenLabel)
                    summary("One-Pedal", store.onePedalOn ? "Ligado" : "Desligado")
                    summary("ESP", store.espOn ? "Ligado" : "Desligado")
                }
                HStack(spacing: 10) {
                    DSActionButton(icon: "slider.horizontal.3", title: "Controles", color: DS.green) { showControls = true }
                    DSActionButton(icon: store.acOn ? "snowflake" : "fan", title: "Ar-condicionado", color: DS.blue) { showAC = true }
                }
            }
        }
    }

    private func summary(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.muted)
            Text(value.isEmpty ? "—" : value).font(.system(size: 16, weight: .bold)).foregroundStyle(DS.text)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Mapa ao vivo (segue o carro conforme ele se move)
struct LiveMapCard: View {
    let lat: Double
    let lng: Double
    @State private var cam: MapCameraPosition = .automatic

    private var coord: CLLocationCoordinate2D { .init(latitude: lat, longitude: lng) }
    private func recenter() {
        cam = .region(MKCoordinateRegion(center: coord, span: MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004)))
    }

    var body: some View {
        Map(position: $cam, interactionModes: []) {
            Annotation("", coordinate: coord) {
                ZStack {
                    Circle().fill(DS.green.opacity(0.22)).frame(width: 40, height: 40)
                    Circle().fill(DS.green).frame(width: 14, height: 14).overlay(Circle().stroke(.white, lineWidth: 2))
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(DS.border, lineWidth: 1))
        .onAppear { recenter() }
        .onChange(of: lat) { _, _ in recenter() }
        .onChange(of: lng) { _, _ in recenter() }
    }
}
