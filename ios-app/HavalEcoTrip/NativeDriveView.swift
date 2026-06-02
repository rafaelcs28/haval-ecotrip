//
//  NativeDriveView.swift
//  Aba Drive — mapa escuro full-screen seguindo o carro, com cards de
//  velocidade (topo) e condução (base) por cima, info da viagem e botões
//  que abrem os sheets de Controles e AC. Zoom + reenquadramento discretos;
//  auto-recenter 10s após o último toque.
//

import SwiftUI
import MapKit

struct NativeDriveView: View {
    @ObservedObject private var store = CarStore.shared
    @State private var showControls = false
    @State private var showAC = false

    private var powerColor: Color {
        let p = store.motorPowerKw
        if p <= -0.1 { return DS.green }; if p >= 0.1 { return DS.blue }; return DS.text
    }
    private func f0(_ v: Double) -> String { String(format: "%.0f", v) }
    private func f1(_ v: Double) -> String { String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",") }
    private func timeStr(_ s: Int) -> String { let h = s/3600, m = (s%3600)/60; return h > 0 ? "\(h)h \(m)min" : "\(m) min" }
    private var consumo: Double { store.tripDistKm > 0.5 ? store.tripNetKwh / store.tripDistKm * 100 : 0 }

    var body: some View {
        ZStack {
            if store.hasGps { FollowMap(lat: store.lat, lng: store.lng).ignoresSafeArea() }
            else { DS.bg.ignoresSafeArea() }

            VStack(spacing: 12) {
                speedCard
                Spacer(minLength: 0)
                if store.tripActive { tripCard }
                conducaoCard
            }
            .padding(16)
        }
        .onAppear { store.start() }
        .sheet(isPresented: $showControls) { DriveControlsSheet() }
        .sheet(isPresented: $showAC) { ACSheet() }
    }

    private var speedCard: some View {
        DSCard(glass: true) {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Circle().fill(store.carOnline ? DS.green : DS.red).frame(width: 8, height: 8)
                    if !store.gearDisplay.isEmpty { DSChip(text: store.gearDisplay, color: DS.blue, filled: true) }
                    Spacer()
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(f0(store.speedKmh)).font(.system(size: 64, weight: .light, design: .rounded))
                        .foregroundStyle(DS.text).monospacedDigit()
                    Text("km/h").font(.headline).foregroundStyle(DS.muted)
                }
                HStack(spacing: 12) {
                    powerCell(f1(store.motorPowerKw), "kW", "Elétrico", powerColor)
                    Divider().frame(height: 30).overlay(DS.border)
                    powerCell(store.engineRpm > 0 ? "\(store.engineRpm)" : "—", "rpm", "Térmico",
                              store.engineRpm > 0 ? DS.orange : DS.muted)
                }
            }
        }
    }

    private func powerCell(_ v: String, _ u: String, _ l: String, _ c: Color) -> some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(v).font(.system(size: 22, weight: .semibold, design: .rounded)).foregroundStyle(c).monospacedDigit()
                Text(u).font(.system(size: 12)).foregroundStyle(DS.muted)
            }
            Text(l.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(DS.muted)
        }.frame(maxWidth: .infinity)
    }

    private var tripCard: some View {
        DSCard(title: "Viagem em curso", icon: "location.fill", glass: true) {
            HStack {
                DSMetric(value: f1(store.tripDistKm), unit: "km", label: "Distância", color: DS.teal)
                DSMetric(value: timeStr(store.tripTimeSec), label: "Tempo")
                DSMetric(value: f1(store.tripNetKwh), unit: "kWh", label: "Energia", color: DS.green)
                DSMetric(value: consumo > 0 ? f1(consumo) : "—", unit: "kWh/100", label: "Consumo")
            }
        }
    }

    private var conducaoCard: some View {
        DSCard(glass: true) {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    chip("Modo", store.driveModeLabel)
                    chip("Regen", store.regenLabel)
                    chip("1-Pedal", store.onePedalOn ? "On" : "Off")
                    chip("ESP", store.espOn ? "On" : "Off")
                }
                HStack(spacing: 10) {
                    DSActionButton(icon: "slider.horizontal.3", title: "Controles", color: DS.green) { showControls = true }
                    DSActionButton(icon: store.acOn ? "snowflake" : "fan", title: "AC", color: DS.blue) { showAC = true }
                }
            }
        }
    }

    private func chip(_ k: String, _ v: String) -> some View {
        VStack(spacing: 2) {
            Text(k.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(DS.muted)
            Text(v.isEmpty ? "—" : v).font(.system(size: 13, weight: .bold)).foregroundStyle(DS.text)
        }.frame(maxWidth: .infinity)
    }
}

// MARK: - Mapa escuro que segue o carro (zoom + reenquadramento; auto 10s)
struct FollowMap: View {
    let lat: Double
    let lng: Double
    @State private var cam: MapCameraPosition = .automatic
    @State private var span = 0.004
    @State private var autoFollow = true
    @State private var lastTouch = Date.distantPast
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var coord: CLLocationCoordinate2D { .init(latitude: lat, longitude: lng) }
    private func center() { cam = .region(MKCoordinateRegion(center: coord,
        span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span))) }
    private func zoom(_ factor: Double) {
        span = min(0.08, max(0.0015, span * factor)); center()
    }

    var body: some View {
        Map(position: $cam, interactionModes: .all) {
            Annotation("", coordinate: coord) {
                ZStack {
                    Circle().fill(DS.green.opacity(0.22)).frame(width: 42, height: 42)
                    Circle().fill(DS.green).frame(width: 16, height: 16).overlay(Circle().stroke(.white, lineWidth: 2))
                        .shadow(color: DS.green.opacity(0.6), radius: 6)
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .environment(\.colorScheme, .dark)   // mapa escuro
        .simultaneousGesture(DragGesture().onChanged { _ in autoFollow = false; lastTouch = Date() }
                                          .onEnded { _ in lastTouch = Date() })
        .onAppear { center() }
        .onChange(of: lat) { _, _ in if autoFollow { center() } }
        .onChange(of: lng) { _, _ in if autoFollow { center() } }
        .onReceive(tick) { _ in
            if !autoFollow && Date().timeIntervalSince(lastTouch) > 10 { autoFollow = true; center() }
        }
        .overlay(alignment: .trailing) {
            VStack(spacing: 10) {
                mapButton("plus") { zoom(0.6) }
                mapButton("minus") { zoom(1.6) }
                mapButton("location.fill", tint: autoFollow ? DS.green : DS.text) {
                    autoFollow = true; center()
                }
            }
            .padding(.trailing, 12)
        }
    }

    private func mapButton(_ icon: String, tint: Color = DS.text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 38, height: 38).background(.ultraThinMaterial).environment(\.colorScheme, .dark)
                .clipShape(Circle()).overlay(Circle().stroke(DS.border, lineWidth: 1))
        }
    }
}
