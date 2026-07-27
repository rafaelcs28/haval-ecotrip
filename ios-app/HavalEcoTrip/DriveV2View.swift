//
//  DriveV2View.swift
//  Drive v2 — mapa hero (design-v2/README.md, frame 4a; RPM híbrido do 4b).
//  V1 (NativeDriveView) permanece intacta; troca via flag ui_v2.
//

import SwiftUI
import MapKit

struct DriveV2View: View {
    @ObservedObject private var store = CarStore.shared
    @StateObject private var route = CockpitRouteStore()
    @AppStorage("v2_preview") private var previewRaw: String = ""
    @AppStorage("cockpit_voice") private var voiceOn = false
    @State private var showAC = false
    @State private var showMic = false
    @State private var showMsg = false
    @State private var showControles = false

    private var navMode: Bool { route.coords.count > 1 }

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
            if store.hasGps || mock {
                FollowMap(lat: displayCoord.latitude, lng: displayCoord.longitude, heading: displayHeading,
                          speedKmh: store.speedKmh, routeCoords: route.coords,
                          v2Accessory: { AnyView(accessoryColumn) })
                    .ignoresSafeArea(edges: .top)   // não cobre a atribuição Maps (legal) na base
            } else {
                DS.bg.ignoresSafeArea()
                Text("Sem GPS do carro")
                    .font(.system(size: 13)).foregroundStyle(DS.muted)
            }

            VStack(spacing: 8) {
                topRow
                if let m = route.maneuver { maneuverBanner(m) }
                Spacer(minLength: 0)
                overlayCard
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .background(alignment: .top) { topProtection }
        .onAppear { store.start(); store.startHF(); refreshRoute() }
        .onDisappear { store.stopHF() }
        .onChange(of: "\(store.lat)|\(store.lng)") { _, _ in refreshRoute() }
        .onChange(of: destKey) { _, _ in refreshRoute() }
        .sheet(isPresented: $showAC) { ClimaSheetV2() }
        .sheet(isPresented: $showControles) { ControlesSheetV2() }
        .sheet(isPresented: $showMic) { EscutaSheetV2() }
        .sheet(isPresented: $showMsg) { CarMessageSheet() }
        #if DEBUG
        .task {
            // Auto-abre sheet via `defaults write ... drive_sheet -string clima|controles`
            let d = UserDefaults.standard
            if let k = d.string(forKey: "drive_sheet") {
                d.removeObject(forKey: "drive_sheet")
                try? await Task.sleep(nanoseconds: 400_000_000)
                if k == "clima" { showAC = true } else if k == "controles" { showControles = true }
                else if k == "escuta" { showMic = true } else if k == "recado" { showMsg = true }
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
            if destination != nil {
                Button { Task { await clearDest() } } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(DS.text)
                        .frame(width: 30, height: 30)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().stroke(DS.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 4)
    }

    private func clearDest() async {
        route.clear()
        let base = BridgeRouter.shared.currentURL
        let b = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard let u = URL(string: "\(b)/api/nav-clear") else { return }
        var r = URLRequest(url: u); r.httpMethod = "POST"; r.timeoutInterval = 10
        r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: r)
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

    // Coordenada do destino final: última perna de state.arrival.legs (server.js:11912).
    private var destCoord: CLLocationCoordinate2D? {
        guard let legs = store.arrivalRaw?["legs"] as? [[String: Any]], let last = legs.last,
              let la = (last["lat"] as? NSNumber)?.doubleValue, let lo = (last["lng"] as? NSNumber)?.doubleValue,
              la != 0 || lo != 0 else { return nil }
        return .init(latitude: la, longitude: lo)
    }
    private var destKey: String {
        guard let c = destCoord else { return "" }
        return "\(c.latitude),\(c.longitude)"
    }
    // Mock DEBUG (v2_preview=dirigindo): carro em Goiânia + destino ~4km pra demoar a rota sem dirigir.
    private var mockCar: CLLocationCoordinate2D { .init(latitude: -16.6869, longitude: -49.2648) }
    private var mockDest: CLLocationCoordinate2D { .init(latitude: -16.7050, longitude: -49.2400) }
    private var carCoord: CLLocationCoordinate2D {
        mock ? mockCar : .init(latitude: store.lat, longitude: store.lng)
    }
    // Posição/rumo exibidos: carro snapado na rota (map-matching) quando há rota; senão cru.
    private var displayCoord: CLLocationCoordinate2D { route.matchedCar ?? carCoord }
    private var displayHeading: Double { route.courseHeading ?? store.heading }

    // Geometria da rota do bridge (Mapbox driving-traffic): [[lng,lat], …].
    private var bridgeGeometry: [CLLocationCoordinate2D] {
        guard let g = store.arrivalRaw?["geometry"] as? [[Any]] else { return [] }
        return g.compactMap { p in
            guard p.count >= 2,
                  let lng = (p[0] as? NSNumber)?.doubleValue,
                  let lat = (p[1] as? NSNumber)?.doubleValue else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lng)
        }
    }
    // Manobras (turn-by-turn com nome de via) do bridge.
    private var bridgeManeuvers: [BridgeManeuver] {
        guard let ms = store.arrivalRaw?["maneuvers"] as? [[String: Any]] else { return [] }
        return ms.compactMap { m in
            guard let lat = (m["lat"] as? NSNumber)?.doubleValue,
                  let lng = (m["lng"] as? NSNumber)?.doubleValue else { return nil }
            return BridgeManeuver(coord: .init(latitude: lat, longitude: lng),
                                  text: (m["text"] as? String) ?? "",
                                  type: (m["type"] as? String) ?? "",
                                  modifier: (m["modifier"] as? String) ?? "")
        }
    }
    private var bridgeSpeedLimit: Int? { (store.arrivalRaw?["speedLimit"] as? NSNumber)?.intValue }

    private func refreshRoute() {
        route.voiceEnabled = voiceOn
        if mock { route.updateApple(car: mockCar, dest: mockDest); return }
        guard store.hasGps else { route.clear(); return }
        let car = carCoord
        let geo = bridgeGeometry
        if geo.count > 1 {                                              // rota com trânsito ao vivo
            route.setBridgeRoute(geo, maneuvers: bridgeManeuvers, speedLimit: bridgeSpeedLimit, car: car)
        } else if destCoord != nil {
            route.updateApple(car: car, dest: destCoord)                // fallback sem bridge
        } else { route.clear() }
    }

    private func clockString(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }
    // ETA: hora de chegada (última perna) + min/km restantes.
    private var etaInfo: (clock: String, min: Int, km: Double)? {
        if mock { return (clockString(Date().addingTimeInterval(8 * 60)), 8, 3.9) }
        guard let d = destination else { return nil }
        let clock = (store.arrivalRaw?["legs"] as? [[String: Any]])?.last?["etaClock"] as? String
            ?? clockString(Date().addingTimeInterval(Double(d.eta) * 60))
        return (clock, d.eta, d.dist)
    }

    private func maneuverBanner(_ m: Maneuver) -> some View {
        let near = m.distanceM < 100
        let accent = near ? DS.green : DS.blue
        return VStack(spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: m.icon)
                    .font(.system(size: 24, weight: .bold)).foregroundStyle(accent)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(m.distanceM >= 1000 ? "\(Fmt.dec1(m.distanceM / 1000)) km" : "\(Int(m.distanceM.rounded())) m")
                        .font(.system(size: 20, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(near ? DS.green : DS.text)
                    Text(m.instruction)
                        .font(.system(size: 12.5)).foregroundStyle(DS.text2)
                        .lineLimit(2).minimumScaleFactor(0.85)
                }
                Spacer(minLength: 6)
                if let e = etaInfo {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(e.clock)
                            .font(.system(size: 19, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(DS.green)
                        Text("\(e.min) min · \(Fmt.dec1(e.km)) km")
                            .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(DS.muted)
                            .lineLimit(1)
                    }
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule().fill(accent)
                        .frame(width: max(6, geo.size.width * (1 - m.progress)))
                }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color(red: 0.071, green: 0.071, blue: 0.078).opacity(0.82))
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(near ? DS.green.opacity(0.5) : DS.border, lineWidth: 1))
        .animation(.easeOut(duration: 0.3), value: m.progress)
    }

    @ViewBuilder
    private var destinationPill: some View {
        if let d = destination {
            // Toque na pill oferece navegação guiada de verdade: o Hub calcula e
            // exibe (Google Directions), mas quem guia é o app do celular.
            // Só vira menu quando temos a coordenada do destino.
            if let c = destCoord {
                Menu {
                    ForEach(NavApp.available) { app in
                        Button {
                            NavLauncher.open(app, lat: c.latitude, lng: c.longitude, name: d.name)
                        } label: { Label("Abrir no \(app.label)", systemImage: app.icon) }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text("→ \(d.name)")
                            .font(.system(size: 12, weight: .bold)).foregroundStyle(DS.text)
                            .lineLimit(1).minimumScaleFactor(0.8)
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 10, weight: .bold)).foregroundStyle(DS.teal)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(DS.teal.opacity(0.35), lineWidth: 1))
                }
            } else {
                Text("→ \(d.name)")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(DS.text)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(DS.border, lineWidth: 1))
            }
        }
    }

    // MARK: coluna flutuante (injetada no FollowMap sob o follow)

    private var accessoryColumn: some View {
        VStack(spacing: 10) {
            if navMode {
                floatButton(voiceOn ? "speaker.wave.2.fill" : "speaker.slash.fill",
                            tint: voiceOn ? DS.green : DS.text) { voiceOn.toggle(); route.voiceEnabled = voiceOn }
            }
            floatButton("snowflake", tint: store.acOn ? DS.teal : DS.text) { showAC = true }
            floatButton("car.fill", tint: store.lockKnown && !store.isLocked ? DS.red : DS.text) { showControles = true }
            floatButton("mic.fill", tint: DS.text) { showMic = true }
            // Recado: aparece em tela cheia no painel do carro. Fica logo abaixo
            // da escuta — mesma família de "falar com o carro".
            floatButton("bubble.left.fill", tint: DS.teal) { showMsg = true }
        }
    }

    // Placa de limite de velocidade (padrão BR/EU: aro vermelho, número preto).
    private func speedLimitBadge(_ v: Int) -> some View {
        Text("\(v)")
            .font(.system(size: 17, weight: .heavy, design: .rounded)).monospacedDigit()
            .foregroundStyle(.black)
            .frame(width: 42, height: 42)
            .background(Circle().fill(.white))
            .overlay(Circle().stroke(.red, lineWidth: 4))
            .overlay(Circle().stroke(.white, lineWidth: 1.5).padding(2))
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
                if navMode, let sl = route.speedLimit { speedLimitBadge(sl) }
                else if !navMode, store.carOnline || mock { steeringIndicator }
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
                // Em nav-mode a atenção é rota+velocidade; esconde consumo/score.
                if !navMode {
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
