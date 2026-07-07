//
//  DriveV2View.swift
//  Drive v2 — mapa hero (design-v2/README.md, frame 4a; RPM híbrido do 4b).
//  V1 (NativeDriveView) permanece intacta; troca via flag ui_v2.
//

import SwiftUI
import MapKit

struct DriveV2View: View {
    @ObservedObject private var store = CarStore.shared
    @AppStorage("v2_preview") private var previewRaw: String = ""
    @State private var showAC = false
    @State private var showMic = false
    @State private var showControles = false

    private var pv: String {
        #if DEBUG
        previewRaw
        #else
        ""
        #endif
    }
    private var mock: Bool { pv == "dirigindo" && !store.tripActive }

    private var speed: Double { mock ? 72 : store.speedKmh }
    private var powerKw: Double { mock ? 14.2 : store.motorPowerKw }
    private var consumo: Double {
        if mock { return 13.9 }
        return store.tripDistKm > 0.5 ? store.tripNetKwh / store.tripDistKm * 100 : 0
    }
    private var liveScore: Int? {
        if mock { return 92 }
        for k in ["score", "liveScore", "drive_score"] {
            switch store.trip?[k] { case let i as Int: return i; case let d as Double: return Int(d); default: continue }
        }
        return nil
    }

    var body: some View {
        ZStack {
            if store.hasGps {
                FollowMap(lat: store.lat, lng: store.lng, heading: store.heading,
                          speedKmh: store.speedKmh,
                          v2Accessory: { AnyView(accessoryColumn) })
                    .ignoresSafeArea()
            } else {
                DS.bg.ignoresSafeArea()
                Text("Sem GPS do carro")
                    .font(.system(size: 13)).foregroundStyle(DS.muted)
            }

            VStack(spacing: 0) {
                topRow
                Spacer(minLength: 0)
                overlayCard
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .background(alignment: .top) { topProtection }
        .onAppear { store.start(); store.startHF() }
        .onDisappear { store.stopHF() }
        .sheet(isPresented: $showAC) { ClimaSheetV2() }
        .sheet(isPresented: $showControles) { ControlesSheetV2() }
        .sheet(isPresented: $showMic) { EscutaSheetV2() }
        #if DEBUG
        .task {
            // Auto-abre sheet via `defaults write ... drive_sheet -string clima|controles`
            let d = UserDefaults.standard
            if let k = d.string(forKey: "drive_sheet") {
                d.removeObject(forKey: "drive_sheet")
                try? await Task.sleep(nanoseconds: 400_000_000)
                if k == "clima" { showAC = true } else if k == "controles" { showControles = true } else if k == "escuta" { showMic = true }
            }
        }
        #endif
    }

    // Gradiente de proteção no topo (legibilidade do chip sobre o mapa).
    private var topProtection: some View {
        LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
            .frame(height: 130)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
    }

    // MARK: topo — LiveChip + pill de destino

    private var topRow: some View {
        HStack(spacing: 8) {
            LiveChipV2(preview: pv)
            Spacer(minLength: 8)
            destinationPill
        }
        .padding(.top, 4)
    }

    private var destination: (name: String, eta: Int, dist: Double)? {
        if let a = store.arrivalRaw, let name = a["name"] as? String, !name.isEmpty {
            let eta = (a["etaMin"] as? Int) ?? Int((a["etaMin"] as? Double) ?? 0)
            let dist = (a["distKm"] as? Double) ?? Double((a["distKm"] as? Int) ?? 0)
            return (name, eta, dist)
        }
        if mock { return ("Escritório", 8, 8.2) }
        return nil
    }

    @ViewBuilder
    private var destinationPill: some View {
        if let d = destination {
            HStack(spacing: 5) {
                Text("→ \(d.name)")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(DS.text)
                Text("\(d.eta) min · \(Fmt.dec1(d.dist)) km")
                    .font(.system(size: 11.5)).foregroundStyle(DS.text2)
            }
            .lineLimit(1).minimumScaleFactor(0.8)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(DS.border, lineWidth: 1))
        }
    }

    // MARK: coluna flutuante (injetada no FollowMap sob o follow)

    private var accessoryColumn: some View {
        VStack(spacing: 10) {
            floatButton("snowflake", tint: store.acOn ? DS.teal : DS.text) { showAC = true }
            floatButton("car.fill", tint: store.lockKnown && !store.isLocked ? DS.red : DS.text) { showControles = true }
            floatButton("mic.fill", tint: DS.text) { showMic = true }
        }
    }

    // Volante ao vivo (espelha o widget do PWA). Calibração: carro envia
    // direita=NEG/esq=POS; disp = -angle faz a tela girar no mesmo sentido (direita=horário).
    private var steeringIndicator: some View {
        let ang = mock ? -18.0 : store.steeringAngle
        let disp = -ang
        let straight = abs(disp) < 5
        let lbl = straight ? "reto" : "\(Int(abs(disp).rounded()))° \(disp < 0 ? "esq" : "dir")"
        return VStack(spacing: 3) {
            Image(systemName: "steeringwheel")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(straight ? DS.text2 : DS.blue)
                .rotationEffect(.degrees(disp))
                .animation(.easeOut(duration: 0.15), value: disp)
            Text(lbl)
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(straight ? DS.muted : DS.blue)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(minWidth: 52)
    }

    private func floatButton(_ icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(DS.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: overlay inferior — velocidade + potência + linha de condução

    private var overlayCard: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("\(Fmt.adjSpeed(speed))")
                        .font(.system(size: 64, weight: .ultraLight))
                        .tracking(-2).monospacedDigit()
                        .foregroundStyle(DS.text)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text("km/h").font(.system(size: 14)).foregroundStyle(DS.muted)
                }
                Spacer(minLength: 8)
                if store.carOnline || mock { steeringIndicator }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(powerText)
                            .font(.system(size: 26, weight: .semibold, design: .rounded))
                            .monospacedDigit().foregroundStyle(powerColor)
                        Text("kW").font(.system(size: 12)).foregroundStyle(DS.muted)
                    }
                    powerBar
                    if store.engineRpm > 0 {
                        Text("\(Fmt.int(Double(store.engineRpm))) RPM")
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit().foregroundStyle(DS.orange)
                    }
                }
            }
            HStack(spacing: 8) {
                pillMini(gearLabel, .neutral)
                if !modeLabel.isEmpty { pillMini(modeLabel, .outline) }
                Spacer(minLength: 6)
                Text(consumo > 0 ? "\(Fmt.dec1(consumo)) kWh/100 · viagem" : "— kWh/100")
                    .font(.system(size: 11)).foregroundStyle(DS.text2)
                    .lineLimit(1).minimumScaleFactor(0.8)
                if let s = liveScore {
                    Spacer(minLength: 6)
                    HStack(spacing: 5) {
                        ScoreRing(score: s)
                        Text("SCORE")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(DS.muted).tracking(1)
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(Color(red: 0.071, green: 0.071, blue: 0.078).opacity(0.82))
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(DS.border, lineWidth: 1))
    }

    private var powerText: String {
        let p = powerKw
        return p < -0.05 ? "−\(Fmt.dec1(-p))" : Fmt.dec1(p)
    }
    private var powerColor: Color { powerKw < -0.05 ? DS.green : DS.orange }

    // Barra bidirecional 130×8: zero central, regen ← green, consumo → laranja.
    private var powerBar: some View {
        let maxKw = 60.0
        let frac = min(1, abs(powerKw) / maxKw)
        let half = 65.0
        return VStack(alignment: .trailing, spacing: 3) {
            ZStack(alignment: .center) {
                Capsule().fill(Color.white.opacity(0.10))
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white.opacity(0.25))
                    .frame(width: 1.5, height: 8)
                HStack(spacing: 0) {
                    Color.clear.frame(width: half)
                    Rectangle().fill(DS.orange)
                        .frame(width: powerKw >= 0 ? half * frac : 0)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Rectangle().fill(DS.green)
                        .frame(width: powerKw < 0 ? half * frac : 0)
                    Color.clear.frame(width: half)
                }
            }
            .frame(width: 130, height: 8)
            .clipShape(Capsule())
            HStack {
                Text("REGEN").foregroundStyle(DS.green)
                Spacer()
                Text("CONSUMO").foregroundStyle(DS.orange)
            }
            .font(.system(size: 8, weight: .bold))
            .tracking(0.8)
            .frame(width: 130)
        }
    }

    private var gearLabel: String {
        let g = store.gearDisplay.isEmpty ? (mock ? "D" : "—") : store.gearDisplay
        if let n = store.intOrNil("gear_ecm"), n > 0 { return "\(g) · \(n)ª" }
        return mock ? "D · 3ª" : g
    }
    private var modeLabel: String {
        if !store.driveModeLabel.isEmpty { return store.driveModeLabel }
        return mock ? "Modo EV" : ""
    }

    private enum PillStyle { case neutral, outline }
    private func pillMini(_ text: String, _ style: PillStyle) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(style == .outline ? DS.green : DS.text)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(style == .neutral ? Color.white.opacity(0.08) : .clear)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(style == .outline ? DS.green.opacity(0.5) : .clear, lineWidth: 1))
    }
}

// MARK: - anel de score (26px, dasharray ∝ score)

struct ScoreRing: View {
    let score: Int
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.12), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(100, score))) / 100)
                .stroke(DS.green, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(score)")
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .monospacedDigit().foregroundStyle(DS.text)
        }
        .frame(width: 26, height: 26)
    }
}
