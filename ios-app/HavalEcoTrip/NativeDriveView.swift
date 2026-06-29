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
    @State private var showMic = false

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
            if store.hasGps { FollowMap(lat: store.lat, lng: store.lng, heading: store.heading, speedKmh: store.speedKmh).ignoresSafeArea() }
            else { DS.bg.ignoresSafeArea() }

            VStack(spacing: 12) {
                speedCard
                Spacer(minLength: 0)
                if store.tripActive { tripCard }
                conducaoCard
            }
            .padding(16)
        }
        .onAppear { store.start(); store.startHF() }   // HF: dados ~4×/s enquanto na aba
        .onDisappear { store.stopHF() }
        .sheet(isPresented: $showControls) { DriveControlsSheet() }
        .sheet(isPresented: $showAC) { ACSheet() }
        .sheet(isPresented: $showMic) { MicTestSheet() }
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
                    Text("\(Fmt.adjSpeed(store.speedKmh))").font(.system(size: 64, weight: .light, design: .rounded))
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
                    chip("One Pedal", store.onePedalOn ? "On" : "Off")
                    chip("ESP", store.espOn ? "On" : "Off")
                }
                HStack(spacing: 10) {
                    DSActionButton(icon: "slider.horizontal.3", title: "Controles", color: DS.green) { showControls = true }
                    DSActionButton(icon: store.acOn ? "snowflake" : "fan", title: "AC", color: DS.blue) { showAC = true }
                    DSActionButton(icon: "mic.fill", title: "Escuta", color: DS.teal) { showMic = true }
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

// MARK: - Ícone do carro (reprodução do _CAR_SVG do cluster iPad, visto de cima)
struct CarBodyShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 32
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
        var path = Path()
        path.move(to: p(16, 1.5))
        path.addCurve(to: p(22, 9), control1: p(20, 1.5), control2: p(22, 4.5))
        path.addLine(to: p(22, 24))
        path.addCurve(to: p(16, 30.5), control1: p(22, 28), control2: p(20, 30.5))
        path.addCurve(to: p(10, 24), control1: p(12, 30.5), control2: p(10, 28))
        path.addLine(to: p(10, 9))
        path.addCurve(to: p(16, 1.5), control1: p(10, 4.5), control2: p(12, 1.5))
        path.closeSubpath()
        return path
    }
}
private struct CarWindow: Shape {
    let pts: [(CGFloat, CGFloat)]
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 32
        var path = Path()
        for (i, pt) in pts.enumerated() {
            let c = CGPoint(x: pt.0 * s, y: pt.1 * s)
            if i == 0 { path.move(to: c) } else { path.addLine(to: c) }
        }
        path.closeSubpath()
        return path
    }
}
struct CarMarker: View {
    var size: CGFloat = 40
    var heading: Double = 0
    private let bodyColor = Color(red: 0.796, green: 0.835, blue: 0.882)   // #cbd5e1
    private let strokeColor = Color(red: 0.118, green: 0.161, blue: 0.231) // #1e293b
    private let glass = Color(red: 0.2, green: 0.255, blue: 0.333)         // #334155
    var body: some View {
        ZStack {
            CarBodyShape().fill(bodyColor)
            CarBodyShape().stroke(strokeColor, lineWidth: size / 20)
            CarWindow(pts: [(12.4, 8.5), (19.6, 8.5), (18.6, 12.5), (13.4, 12.5)]).fill(glass.opacity(0.75))
            CarWindow(pts: [(13.2, 24.5), (18.8, 24.5), (17.9, 21.5), (14.1, 21.5)]).fill(glass.opacity(0.55))
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(heading))
        .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
    }
}

// MARK: - Mapa escuro que segue o carro (zoom + reenquadramento; auto 10s)
struct FollowMap: View {
    let lat: Double
    let lng: Double
    var heading: Double = 0
    var speedKmh: Double = 0          // zoom adaptativo: mais rápido = mais afastado
    @State private var cam: MapCameraPosition = .automatic
    @State private var span = 0.004
    @State private var autoFollow = true
    @State private var lastTouch = Date.distantPast
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var coord: CLLocationCoordinate2D { .init(latitude: lat, longitude: lng) }
    // Span por velocidade: parado ~0,004; ~0,004 + v/120·0,02 (teto 0,03 ≈ ~3 km de visão).
    private func spanForSpeed() -> Double { min(0.03, max(0.0035, 0.004 + speedKmh / 120 * 0.02)) }
    private func center() { cam = .region(MKCoordinateRegion(center: coord,
        span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span))) }
    private func followCenter() { span = spanForSpeed(); center() }   // auto: zoom pela velocidade
    private func zoom(_ factor: Double) {
        autoFollow = false; lastTouch = Date()
        span = min(0.08, max(0.0015, span * factor)); center()
    }

    var body: some View {
        Map(position: $cam, interactionModes: .all) {
            Annotation("", coordinate: coord) {
                CarMarker(size: 42, heading: heading)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .environment(\.colorScheme, .dark)   // mapa escuro (ruas claras)
        .simultaneousGesture(DragGesture().onChanged { _ in autoFollow = false; lastTouch = Date() }
                                          .onEnded { _ in lastTouch = Date() })
        .onAppear { followCenter() }
        .onChange(of: lat) { _, _ in if autoFollow { followCenter() } }
        .onChange(of: lng) { _, _ in if autoFollow { followCenter() } }
        .onChange(of: speedKmh) { _, _ in if autoFollow { followCenter() } }
        .onReceive(tick) { _ in
            if !autoFollow && Date().timeIntervalSince(lastTouch) > 10 { autoFollow = true; followCenter() }
        }
        .overlay(alignment: .trailing) { mapControls.padding(.trailing, 12) }
    }

    @ViewBuilder
    private var mapControls: some View {
        let stack = VStack(spacing: 10) {
            mapButton("plus") { zoom(0.6) }
            mapButton("minus") { zoom(1.6) }
            mapButton("location.fill", tint: autoFollow ? DS.green : DS.text) {
                autoFollow = true; center()
            }
        }
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: 10) { stack }
        } else {
            stack
        }
    }

    private func mapButton(_ icon: String, tint: Color = DS.text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .glassControl(in: Circle())
                .overlay(Circle().stroke(DS.border, lineWidth: 1))
        }
    }
}
