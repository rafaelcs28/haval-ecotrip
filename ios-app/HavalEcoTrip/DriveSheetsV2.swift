//
//  DriveSheetsV2.swift
//  Sheets do Drive v2 (design-v2/HANDOFF-drive-sheets.md):
//    8a ClimaSheetV2     — setpoint hero + ventilação + modos + assentos + presets
//    8b ControlesSheetV2 — diagrama do carro + vidros/travas/teto + sinalização
//  Sheet parcial sobre o mapa vivo; comandos seguem a máquina de estados 2b
//  (padrão → enviando amarelo → confirmado/falhou) via store.commandProgress.
//
import SwiftUI

// MARK: - Container comum

struct SheetV2Header<Chip: View, Extra: View>: View {
    let title: String
    @ViewBuilder var chip: Chip
    @ViewBuilder var extra: Extra
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 16, weight: .bold)).foregroundStyle(DS.text)
            chip
            Spacer(minLength: 6)
            extra
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.text2)
                    .frame(width: 30, height: 30)
                    .background(DS.panel2, in: Circle())
            }
            .buttonStyle(.plain)
        }
    }
}

struct StateChip: View {
    let text: String
    let color: Color
    var icon: String? = nil
    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 9, weight: .bold)) }
            Text(text).font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(color.opacity(0.13), in: Capsule())
        .overlay(Capsule().stroke(color.opacity(0.35), lineWidth: 1))
    }
}

func sheetV2Presentation<V: View>(_ v: V) -> some View {
    v.presentationDetents([.fraction(0.72), .large])
        .presentationBackground(DS.panel)
        .presentationCornerRadius(24)
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.72)))
}

// MARK: - 8a · Clima

struct ClimaSheetV2: View {
    @ObservedObject private var store = CarStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var setpoint: Double = 22
    @State private var seeded = false
    @State private var sendingTemp = false
    @State private var debounce: Task<Void, Never>?
    @State private var fanLocal: Int?
    @State private var fanRevert: Task<Void, Never>?
    @State private var maxFrioUntil: Date?
    @State private var maxFrioTask: Task<Void, Never>?

    private var acOn: Bool { store.acOn }
    private var fan: Int { fanLocal ?? store.fanSpeed }

    var body: some View {
        sheetV2Presentation(content)
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 16) {
                SheetV2Header(title: "Clima") {
                    if acOn {
                        StateChip(text: "Ligado", color: DS.teal, icon: "fan.fill")
                    } else {
                        StateChip(text: "Desligado", color: DS.muted)
                    }
                } extra: {
                    if store.insideTemp > 0 || store.outsideTemp > 0 {
                        Text("cabine \(Fmt.dec1(store.insideTemp))° · externa \(Int(store.outsideTemp))°")
                            .font(.system(size: 11)).monospacedDigit().foregroundStyle(DS.muted)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                } onClose: { dismiss() }

                if !store.engineOn && !acOn {
                    Text("Comandos vão acordar o carro")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(DS.blue)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(DS.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                }

                heroSetpoint
                ventilacao
                modos
                assentos
                presets
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .onAppear {
            guard !seeded else { return }
            seeded = true
            if store.driverTemp >= 16 && store.driverTemp <= 32 { setpoint = store.driverTemp }
        }
    }

    // Hero: setpoint gigante + steppers − / +
    private var heroSetpoint: some View {
        HStack(spacing: 0) {
            stepper("minus", DS.blue) { bump(-0.5) }
            Spacer(minLength: 8)
            VStack(spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(Fmt.dec1(setpoint))
                        .font(.system(size: 76, weight: .thin)).monospacedDigit()
                        .tracking(-3)
                        .foregroundStyle(acOn ? DS.text : DS.muted)
                    Text("°C").font(.system(size: 18)).foregroundStyle(DS.muted)
                }
                Text(heroSub.0)
                    .font(.system(size: 10.5, weight: .medium)).monospacedDigit()
                    .foregroundStyle(heroSub.1)
            }
            Spacer(minLength: 8)
            stepper("plus", DS.orange) { bump(+0.5) }
        }
    }

    private var heroSub: (String, Color) {
        if sendingTemp { return ("enviando…", DS.yellow) }
        if !acOn { return ("desligado", DS.muted) }
        let cabin = store.insideTemp
        guard cabin > 0 else { return ("mantendo", DS.muted) }
        let delta = setpoint - cabin
        if delta < -0.4 {
            let min = Swift.max(1, Swift.min(15, Int((abs(delta) / 0.7).rounded(.up))))
            return ("resfriando · chega em ~\(min) min", DS.teal)
        }
        if delta > 0.4 {
            let min = Swift.max(1, Swift.min(15, Int((delta / 0.7).rounded(.up))))
            return ("aquecendo · chega em ~\(min) min", DS.orange)
        }
        return ("mantendo", DS.muted)
    }

    private func stepper(_ glyph: String, _ tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: glyph)
                .font(.system(size: 24, weight: .regular)).foregroundStyle(tint)
                .frame(width: 52, height: 52)
                .background(DS.panel2, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.10), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
    }

    private func bump(_ d: Double) {
        setpoint = Swift.min(30, Swift.max(16, setpoint + d))
        sendingTemp = true
        debounce?.cancel()
        let v = setpoint
        debounce = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)   // debounce: não spamma o MQTT
            guard !Task.isCancelled else { return }
            _ = await store.setHvac("driver_temp", v)
            if store.syncTemp { _ = await store.setHvac("passenger_temp", v) }
            sendingTemp = false
        }
    }

    // Ventilação: 7 segmentos
    private var ventilacao: some View {
        VStack(spacing: 8) {
            HStack {
                microLabel("VENTILAÇÃO")
                Spacer()
                Text(fan > 0 ? "nível \(fan) de 7" : "desligada")
                    .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(DS.text2)
            }
            HStack(spacing: 6) {
                Button { setFan(fan == 0 ? 1 : 0) } label: {
                    Image(systemName: "power")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(fan == 0 ? .black : DS.text2)
                        .frame(width: 36, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7).fill(fan == 0 ? DS.teal : DS.panel2))
                        .overlay(RoundedRectangle(cornerRadius: 7)
                            .stroke(Color.white.opacity(fan == 0 ? 0 : 0.07), lineWidth: 1))
                }
                .buttonStyle(.plain)
                GeometryReader { geo in
                    let w = geo.size.width
                    HStack(spacing: 5) {
                        ForEach(1...7, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 7)
                                .fill(i <= fan ? DS.teal : DS.panel2)
                                .overlay(RoundedRectangle(cornerRadius: 7)
                                    .stroke(Color.white.opacity(i <= fan ? 0 : 0.07), lineWidth: 1))
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                        let seg = Int((g.location.x / w * 7).rounded(.down)) + 1
                        let lvl = Swift.min(7, Swift.max(1, seg))
                        if lvl != fan { setFan(lvl) }
                    }.onEnded { g in
                        let seg = Int((g.location.x / w * 7).rounded(.down)) + 1
                        setFan(Swift.min(7, Swift.max(1, seg)))
                    })
                }
                .frame(height: 26)
            }
        }
    }

    private func setFan(_ lvl: Int) {
        guard lvl != fanLocal else { return }
        fanLocal = lvl
        fanRevert?.cancel()
        Task { _ = await store.setHvac("fan_speed", Double(lvl)) }
        fanRevert = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled { fanLocal = nil }   // volta a refletir o estado real
        }
    }

    // Modos: A/C · Recircular · Desembaçar · AUTO
    private var modos: some View {
        HStack(spacing: 8) {
            modeTile(active: store.acEnable || !acOn, tint: DS.teal, cta: !acOn) {
                if !acOn {
                    Task { _ = await store.setAcPower(true); _ = await store.setHvac("ac_enable", on: true) }
                } else {
                    Task { _ = await store.setHvac("ac_enable", on: !store.acEnable) }
                }
            } label: {
                Text("A/C").font(.system(size: 13, weight: .bold))
            }
            modeTile(active: store.cycleMode == 0, tint: DS.teal) {
                Task { _ = await store.setHvac("cycle_mode", Double(store.cycleMode == 0 ? 1 : 0)) }
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "arrow.trianglehead.2.clockwise").font(.system(size: 15))
                    Text("Recircular").font(.system(size: 9))
                }
            }
            modeTile(active: store.frontDefrost, tint: DS.teal) {
                Task { _ = await store.setHvac("front_defrost", on: !store.frontDefrost) }
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "windshield.front.and.heat.waves").font(.system(size: 15))
                    Text("Desembaçar").font(.system(size: 9))
                }
            }
            modeTile(active: store.autoMode, tint: DS.green) {
                Task { _ = await store.setHvac("auto", on: !store.autoMode) }
            } label: {
                Text("AUTO").font(.system(size: 13, weight: .bold))
            }
        }
    }

    private func modeTile<L: View>(active: Bool, tint: Color, cta: Bool = false,
                                   action: @escaping () -> Void,
                                   @ViewBuilder label: () -> L) -> some View {
        Button(action: action) {
            label()
                .foregroundStyle(active && !cta ? tint : (cta ? tint : DS.text2))
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background((active && !cta) || cta ? tint.opacity(cta ? 0.22 : 0.15) : DS.panel2,
                            in: RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13)
                    .stroke((active && !cta) || cta ? tint.opacity(0.4) : Color.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // Assentos: ventilação por assento (0–3). O carro não expõe aquecimento
    // por assento — ciclo é off → ventilar 1→2→3 → off.
    private var assentos: some View {
        HStack(spacing: 8) {
            seatCard("ASSENTO · MOTORISTA", level: store.seatVentDrv, key: "seat_vent_drv")
            seatCard("ASSENTO · PASSAG.", level: store.seatVentPass, key: "seat_vent_pass")
        }
    }

    private func seatCard(_ title: String, level: Int, key: String) -> some View {
        Button {
            let next = (level + 1) % 4
            store.optimisticRaw(key, next)
            Task { _ = await store.setHvac(key, Double(next)) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    microLabel(title)
                    Text(level > 0 ? "Ventilar · nível \(level)" : "Desligado")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(level > 0 ? DS.teal : DS.muted)
                }
                Spacer(minLength: 6)
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(1...3, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(i <= level ? DS.teal : DS.panel3)
                            .frame(width: 5, height: CGFloat(4 + i * 4))
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background(DS.panel2, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(DS.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // Presets
    private var presets: some View {
        HStack(spacing: 8) {
            Button { toggleMaxFrio() } label: {
                Group {
                    if let until = maxFrioUntil, until > Date() {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text("Máx frio · \(countdown(until))")
                        }
                    } else {
                        Text("Máx frio 5 min")
                    }
                }
                .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                .foregroundStyle(DS.teal)
                .frame(maxWidth: .infinity).frame(height: 34)
                .background(DS.teal.opacity(0.13), in: Capsule())
                .overlay(Capsule().stroke(DS.teal.opacity(0.35), lineWidth: 1))
            }
            .buttonStyle(.plain)

            Button {
                Task { _ = await store.setHvac("sync", on: !store.syncTemp) }
            } label: {
                Text("Sincronizar zonas")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(store.syncTemp ? DS.teal : DS.text2)
                    .frame(maxWidth: .infinity).frame(height: 34)
                    .background(store.syncTemp ? DS.teal.opacity(0.13) : DS.panel2, in: Capsule())
                    .overlay(Capsule().stroke(store.syncTemp ? DS.teal.opacity(0.35) : DS.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    private func toggleMaxFrio() {
        if let until = maxFrioUntil, until > Date() {
            maxFrioTask?.cancel(); maxFrioUntil = nil
            Task { _ = await store.setHvac("acmax", on: false) }
            return
        }
        maxFrioUntil = Date().addingTimeInterval(300)
        Task {
            _ = await store.setAcPower(true)
            _ = await store.setHvac("acmax", on: true)
            _ = await store.setHvac("fan_speed", 7)
        }
        maxFrioTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000_000)
            guard !Task.isCancelled else { return }
            _ = await store.setHvac("acmax", on: false)
            maxFrioUntil = nil
        }
    }

    private func countdown(_ until: Date) -> String {
        let s = Swift.max(0, Int(until.timeIntervalSinceNow))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func microLabel(_ t: String) -> some View {
        Text(t).font(.system(size: 8.5, weight: .bold)).tracking(1).foregroundStyle(DS.muted)
    }
}

// MARK: - 8b · Controles

struct ControlesSheetV2: View {
    @ObservedObject private var store = CarStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showSunroof = false
    @State private var showEngine = false
    @State private var hazardBusy = false
    @State private var pendMode: Int?
    @State private var pendReserve: Int?
    @State private var pendRegen: Int?
    @State private var pendTerrain: Int?
    @State private var pendSteer: Int?
    @State private var socTarget: Double = 50
    @State private var editingSoc = false
    @State private var toast: CtlToast?
    @State private var toastWork: DispatchWorkItem?
    @State private var sentAt: Date?

    private struct CtlToast: Equatable { let fail: Bool; let text: String; let retry: String? }

    private var isDriving: Bool {
        store.tripActive || (store.engineOn && (store.gear == "D" || store.gear == "R" || store.speedKmh > 1))
    }
    private var cp: CarStore.CommandProgress? { store.commandProgress }
    private var inFlight: Bool { cp?.phase == "sent" || cp?.phase == "running" }

    var body: some View {
        sheetV2Presentation(content)
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 16) {
                SheetV2Header(title: "Controles") {
                    if !store.lockKnown {
                        StateChip(text: "—", color: DS.muted)
                    } else if store.isLocked {
                        StateChip(text: "Travado", color: DS.green, icon: "lock.fill")
                    } else {
                        StateChip(text: "Destravado", color: DS.red, icon: "lock.open.fill")
                    }
                } extra: { EmptyView() } onClose: { dismiss() }

                carDiagram
                windowActions
                lockGrid
                signalGrid
                conducao
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .overlay(alignment: .bottom) { toastView.padding(.bottom, 10) }
        .onChange(of: store.commandProgress?.ts) { _, _ in onProgress() }
        .confirmationDialog("Teto solar", isPresented: $showSunroof, titleVisibility: .visible) {
            Button("Abrir teto") { store.fireCommand("sunroof_open") }
            Button("Fechar teto") { store.fireCommand("sunroof_close") }
            Button("Cancelar", role: .cancel) {}
        }
        .confirmationDialog(store.engineOn ? "Desligar o motor?" : "Ligar o motor remotamente?",
                            isPresented: $showEngine, titleVisibility: .visible) {
            Button(store.engineOn ? "Desligar" : "Ligar") {
                store.fireCommand(store.engineOn ? "engine_off" : "engine_on")
            }
            Button("Cancelar", role: .cancel) {}
        }
    }

    // Diagrama do carro com pills de estado ancoradas
    private var carDiagram: some View {
        ZStack {
            RadialGradient(colors: [DS.green.opacity(0.13), .clear],
                           center: .center, startRadius: 10, endRadius: 130)
            Image("haval_h6_top")
                .resizable().scaledToFit()
                .frame(height: 150)
                .shadow(color: .black.opacity(0.55), radius: 10, y: 5)

            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                statusPill(windowState("fl")).position(x: w * 0.16, y: h * 0.27)
                statusPill(windowState("fr")).position(x: w * 0.84, y: h * 0.27)
                statusPill(windowState("rl")).position(x: w * 0.16, y: h * 0.68)
                statusPill(windowState("rr")).position(x: w * 0.84, y: h * 0.68)
                statusPill(roofState).position(x: w * 0.5, y: h * 0.06)
                statusPill(trunkState).position(x: w * 0.5, y: h * 0.95)
            }
        }
        .frame(height: 190)
    }

    private enum PillKind { case neutral, alertYellow, alertRed, moving }
    private struct PillState { let text: String; let kind: PillKind }

    private func windowState(_ pos: String) -> PillState {
        if let a = cp?.action, a.hasPrefix("windows"), inFlight {
            return PillState(text: a == "windows_close" ? "fechando…" : "abrindo…", kind: .moving)
        }
        let doorLabel = ["fl": "Porta diant. esq.", "fr": "Porta diant. dir.",
                         "rl": "Porta tras. esq.", "rr": "Porta tras. dir."][pos]!
        let winLabel  = ["fl": "Vidro diant. esq.", "fr": "Vidro diant. dir.",
                         "rl": "Vidro tras. esq.", "rr": "Vidro tras. dir."][pos]!
        if store.openings.contains(doorLabel) { return PillState(text: "porta aberta", kind: .alertRed) }
        if store.openings.contains(winLabel) { return PillState(text: "aberto", kind: .alertYellow) }
        return PillState(text: "fechado", kind: .neutral)
    }

    private var roofState: PillState {
        if let a = cp?.action, a.hasPrefix("sunroof"), inFlight {
            return PillState(text: a == "sunroof_close" ? "fechando…" : "abrindo…", kind: .moving)
        }
        return store.openings.contains("Teto solar")
            ? PillState(text: "teto aberto", kind: .alertYellow)
            : PillState(text: "teto fechado", kind: .neutral)
    }

    private var trunkState: PillState {
        if let a = cp?.action, a.hasPrefix("trunk"), inFlight {
            return PillState(text: "abrindo…", kind: .moving)
        }
        return store.openings.contains("Porta-malas")
            ? PillState(text: "porta-malas aberto", kind: .alertRed)
            : PillState(text: "porta-malas fechado", kind: .neutral)
    }

    @ViewBuilder
    private func statusPill(_ s: PillState) -> some View {
        let (fg, bg, stroke): (Color, Color, Color) = {
            switch s.kind {
            case .neutral:     return (DS.text2, Color(red: 0.12, green: 0.12, blue: 0.12).opacity(0.85), Color.white.opacity(0.08))
            case .alertYellow: return (DS.yellow, DS.yellow.opacity(0.14), DS.yellow.opacity(0.4))
            case .alertRed:    return (DS.red, DS.red.opacity(0.15), DS.red.opacity(0.45))
            case .moving:      return (DS.yellow, DS.yellow.opacity(0.14), DS.yellow.opacity(0.4))
            }
        }()
        Text(s.text)
            .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(fg)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(bg, in: Capsule())
            .overlay(Capsule().stroke(stroke, lineWidth: 1))
            .opacity(s.kind == .moving ? 0.85 : 1)
            .symbolEffect(.pulse, options: .repeating, isActive: s.kind == .moving)
    }

    // Ações de vidros (grid 2)
    private var windowActions: some View {
        HStack(spacing: 8) {
            cmdTile(action: "windows_close", icon: "arrow.down.square", tint: DS.blue,
                    title: "Fechar vidros", sub: "todos", sendingTitle: "Fechando vidros…", h: 58)
            cmdTile(action: "windows_open", icon: "arrow.up.square", tint: DS.blue,
                    title: "Abrir vidros", sub: "todos", sendingTitle: "Abrindo vidros…", h: 58)
        }
    }

    // Travas e acessos (grid 4)
    private var lockGrid: some View {
        VStack(spacing: 8) {
            microLabel("TRAVAS E ACESSOS")
            HStack(spacing: 8) {
                cmdTile(action: "lock_close", icon: "lock.fill", tint: DS.green,
                        title: "Travar", sub: nil, sendingTitle: "Travando…", h: 58, compact: true)
                cmdTile(action: "lock_open", icon: "lock.open.fill", tint: DS.text2,
                        title: "Destravar", sub: nil, sendingTitle: "Destravando…", h: 58, compact: true)
                cmdTile(action: "trunk_open", icon: "car.side.rear.open.fill", tint: DS.text2,
                        title: "Porta-malas", sub: nil, sendingTitle: "Abrindo…", h: 58, compact: true,
                        dimmed: isDriving)
                plainTile(icon: "arrow.up.to.line.compact", tint: DS.text2, title: "Teto solar",
                          h: 58, compact: true, dimmed: isDriving,
                          sending: cp?.action.hasPrefix("sunroof") == true && inFlight) { showSunroof = true }
            }
        }
    }

    // Sinalização e motor
    private var signalGrid: some View {
        VStack(spacing: 8) {
            microLabel("SINALIZAÇÃO E MOTOR")
            HStack(spacing: 8) {
                Button {
                    guard !hazardBusy else { return }
                    hazardBusy = true
                    Task {
                        _ = await store.setHazard(true)
                        try? await Task.sleep(nanoseconds: 6_000_000_000)
                        _ = await store.setHazard(false)
                        hazardBusy = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 14))
                        Text(hazardBusy ? "Piscando…" : "Piscar alerta").font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(DS.yellow)
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .background(hazardBusy ? DS.yellow.opacity(0.13) : DS.panel2,
                                in: RoundedRectangle(cornerRadius: 13))
                    .overlay(RoundedRectangle(cornerRadius: 13)
                        .stroke(hazardBusy ? DS.yellow.opacity(0.4) : DS.border, lineWidth: 1))
                }
                .buttonStyle(.plain)

                engineTile
            }
        }
    }

    private var engineTile: some View {
        let st = tileState("engine")
        return Button {} label: {
            HStack(spacing: 6) {
                Image(systemName: st == .sending ? "clock" : "engine.combustion.fill").font(.system(size: 14))
                Text(engineLabel(st)).font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(engineColor(st))
            .frame(maxWidth: .infinity).frame(height: 50)
            .background(engineBg(st), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(engineStroke(st), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onLongPressGesture(minimumDuration: 0.5) { showEngine = true }
    }

    private func engineLabel(_ s: TileSt) -> String {
        switch s {
        case .sending:   return store.engineOn ? "Desligando…" : "Ligando…"
        case .confirmed: return store.engineOn ? "Motor ligado" : "Motor desligado"
        case .failed:    return "Falhou · segure"
        case .idle:      return store.engineOn ? "Motor · segure p/ desligar" : "Motor · segure p/ ligar"
        }
    }
    private func engineColor(_ s: TileSt) -> Color {
        switch s { case .sending: return DS.yellow; case .confirmed: return DS.green
                   case .failed: return DS.red; case .idle: return DS.orange }
    }
    private func engineBg(_ s: TileSt) -> Color {
        switch s { case .sending: return DS.yellow.opacity(0.10); case .confirmed: return DS.green.opacity(0.10)
                   case .failed: return DS.red.opacity(0.10); case .idle: return DS.panel2 }
    }
    private func engineStroke(_ s: TileSt) -> Color {
        switch s { case .sending: return DS.yellow.opacity(0.4); case .confirmed: return DS.green.opacity(0.4)
                   case .failed: return DS.red.opacity(0.45); case .idle: return DS.border }
    }

    // MARK: Condução (modo / regen / terreno / direção / toggles)

    private var mode: Int { pendMode ?? store.intOrNil("drive_mode") ?? -1 }
    private var reserve: Int { pendReserve ?? store.powerReserve ?? -1 }
    private var regen: Int { pendRegen ?? store.intOrNil("regen_level") ?? -1 }
    private var terrain: Int { pendTerrain ?? store.terrainMode ?? -1 }
    private var steer: Int { pendSteer ?? store.steerMode ?? -1 }

    private var conducao: some View {
        VStack(spacing: 14) {
            segSection("MODO DE CONDUÇÃO", options: [(0, "HEV"), (1, "Prior. EV"), (3, "EV Puro")],
                       selected: mode, tint: DS.green) { v in
                pendMode = v; Task { await store.setDriveMode(v) }
            }
            if mode == 0 {
                segSection("SUB-MODO HEV", options: [(1, "Inteligente"), (2, "Prioritário")],
                           selected: reserve, tint: DS.teal) { v in
                    pendReserve = v; Task { await store.setPowerReserve(v) }
                }
                if reserve == 2 { socRow }
            }
            segSection("REGENERAÇÃO", options: [(0, "Normal"), (1, "Alto"), (2, "Baixo")],
                       selected: regen, tint: DS.teal) { v in
                pendRegen = v; Task { await store.setRegen(v) }
            }
            VStack(spacing: 8) {
                microLabel("TERRENO")
                let opts: [(Int, String)] = [(0, "Normal"), (1, "Sport"), (2, "Eco"), (3, "Neve"),
                                             (4, "Areia"), (5, "Lama"), (11, "AWD")]
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(opts, id: \.0) { v, label in
                        segChip(label, on: terrain == v, tint: DS.orange, h: 38) {
                            pendTerrain = v; Task { await store.setTerrain(v) }
                        }
                    }
                }
            }
            segSection("DIREÇÃO", options: [(2, "Conforto"), (0, "Normal"), (1, "Sport")],
                       selected: steer, tint: DS.blue) { v in
                pendSteer = v; Task { await store.setSteer(v) }
            }
            HStack(spacing: 8) {
                segChip("One-Pedal", on: store.onePedalOn, tint: DS.green, h: 44) {
                    Task { await store.setOnePedal(!store.onePedalOn) }
                }
                segChip("ESP", on: store.espOn, tint: DS.green, h: 44) {
                    Task { await store.setEsp(!store.espOn) }
                }
            }
        }
        .onAppear { if store.chargeSocTarget >= 20 { socTarget = Double(store.chargeSocTarget) } }
        .onChange(of: store.intOrNil("drive_mode")) { _, v in if v == pendMode { pendMode = nil } }
        .onChange(of: store.powerReserve) { _, v in if v == pendReserve { pendReserve = nil } }
        .onChange(of: store.intOrNil("regen_level")) { _, v in if v == pendRegen { pendRegen = nil } }
        .onChange(of: store.terrainMode) { _, v in if v == pendTerrain { pendTerrain = nil } }
        .onChange(of: store.steerMode) { _, v in if v == pendSteer { pendSteer = nil } }
        .onChange(of: store.chargeSocTarget) { _, v in if !editingSoc && v >= 20 { socTarget = Double(v) } }
    }

    private func segSection(_ title: String, options: [(Int, String)], selected: Int,
                            tint: Color, onPick: @escaping (Int) -> Void) -> some View {
        VStack(spacing: 8) {
            microLabel(title)
            HStack(spacing: 6) {
                ForEach(options, id: \.0) { v, label in
                    segChip(label, on: selected == v, tint: tint, h: 40) { onPick(v) }
                }
            }
        }
    }

    private func segChip(_ label: String, on: Bool, tint: Color, h: CGFloat,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(on ? tint : DS.text2)
                .frame(maxWidth: .infinity).frame(height: h)
                .background(on ? tint.opacity(0.15) : DS.panel2, in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11)
                    .stroke(on ? tint.opacity(0.4) : DS.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var socRow: some View {
        VStack(spacing: 4) {
            HStack {
                Text("Manter bateria em").font(.system(size: 10.5)).foregroundStyle(DS.muted)
                Spacer()
                Text("\(Int(socTarget))%")
                    .font(.system(size: 12, weight: .bold)).monospacedDigit().foregroundStyle(DS.teal)
            }
            Slider(value: $socTarget, in: 20...80, step: 5) { editing in
                editingSoc = editing
                if !editing { Task { await store.setChargeSocTarget(Int(socTarget)) } }
            }
            .tint(DS.teal)
        }
    }

    // Tile de comando com máquina 2b
    private enum TileSt { case idle, sending, confirmed, failed }

    private func tileState(_ prefix: String) -> TileSt {
        guard let cp, cp.action.hasPrefix(prefix) else { return .idle }
        switch cp.phase {
        case "sent", "running": return .sending
        case "done":            return cp.ok == true ? .confirmed : .failed
        case "timeout":         return .failed
        default:                return .idle
        }
    }

    @ViewBuilder
    private func cmdTile(action: String, icon: String, tint: Color, title: String, sub: String?,
                         sendingTitle: String, h: CGFloat, compact: Bool = false,
                         dimmed: Bool = false) -> some View {
        let st: TileSt = {
            guard let cp, cp.action == action else { return .idle }
            switch cp.phase {
            case "sent", "running": return .sending
            case "done":            return cp.ok == true ? .confirmed : .failed
            case "timeout":         return .failed
            default:                return .idle
            }
        }()
        let (shownIcon, shownTitle, shownSub, fg): (String, String, String?, Color) = {
            switch st {
            case .sending:   return ("clock", sendingTitle, "aguardando o carro", DS.yellow)
            case .confirmed: return ("checkmark", confirmedText(action), nil, DS.green)
            case .failed:    return ("xmark", "Falhou · tocar p/ tentar", nil, DS.red)
            case .idle:      return (icon, title, sub, tint)
            }
        }()
        let bg: Color = {
            switch st {
            case .sending: return DS.yellow.opacity(0.10); case .confirmed: return DS.green.opacity(0.10)
            case .failed: return DS.red.opacity(0.10); case .idle: return DS.panel2
            }
        }()
        let stroke: Color = {
            switch st {
            case .sending: return DS.yellow.opacity(0.4); case .confirmed: return DS.green.opacity(0.4)
            case .failed: return DS.red.opacity(0.45); case .idle: return DS.border
            }
        }()
        Button {
            store.fireCommand(action)
        } label: {
            Group {
                if compact {
                    VStack(spacing: 5) {
                        Image(systemName: shownIcon).font(.system(size: 16))
                            .symbolEffect(.pulse, options: .repeating, isActive: st == .sending)
                        Text(shownTitle).font(.system(size: 9.5, weight: .semibold))
                            .lineLimit(1).minimumScaleFactor(0.6)
                    }
                } else {
                    HStack(spacing: 9) {
                        Image(systemName: shownIcon).font(.system(size: 18))
                            .symbolEffect(.pulse, options: .repeating, isActive: st == .sending)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(shownTitle).font(.system(size: 12, weight: .semibold))
                                .lineLimit(1).minimumScaleFactor(0.7)
                            if let shownSub {
                                Text(shownSub).font(.system(size: 9.5)).opacity(0.7)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                }
            }
            .foregroundStyle(fg)
            .frame(maxWidth: .infinity).frame(height: h)
            .background(bg, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(dimmed)
        .opacity(dimmed ? 0.45 : 1)
    }

    private func plainTile(icon: String, tint: Color, title: String, h: CGFloat,
                           compact: Bool, dimmed: Bool, sending: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: sending ? "clock" : icon).font(.system(size: 16))
                    .symbolEffect(.pulse, options: .repeating, isActive: sending)
                Text(title).font(.system(size: 9.5, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            .foregroundStyle(sending ? DS.yellow : tint)
            .frame(maxWidth: .infinity).frame(height: h)
            .background(sending ? DS.yellow.opacity(0.10) : DS.panel2, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13)
                .stroke(sending ? DS.yellow.opacity(0.4) : DS.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(dimmed)
        .opacity(dimmed ? 0.45 : 1)
    }

    // Toast de comando (persistente enquanto aguarda; sucesso/falha temporário)
    @ViewBuilder
    private var toastView: some View {
        if let cp, inFlight, let sentAt {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack(spacing: 6) {
                    Image(systemName: "clock").font(.system(size: 11)).foregroundStyle(DS.yellow)
                    Text("\(Self.verb(cp.action)) · enviado há \(Swift.max(0, Int(Date().timeIntervalSince(sentAt)))) s")
                        .font(.system(size: 11, weight: .medium)).monospacedDigit()
                        .foregroundStyle(DS.text)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(DS.yellow.opacity(0.3), lineWidth: 1))
            }
        } else if let toast {
            HStack(spacing: 6) {
                Image(systemName: toast.fail ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 11)).foregroundStyle(toast.fail ? DS.red : DS.green)
                Text(toast.text)
                    .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(DS.text)
                if let retry = toast.retry {
                    Button("Tentar") { store.fireCommand(retry); self.toast = nil }
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(DS.red)
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke((toast.fail ? DS.red : DS.green).opacity(0.35), lineWidth: 1))
        }
    }

    private func onProgress() {
        guard let cp else { return }
        switch cp.phase {
        case "sent":
            sentAt = cp.ts
            setToast(nil)
        case "done", "timeout":
            if cp.ok == true {
                let lat = sentAt.map { " · \(Fmt.dec1(cp.ts.timeIntervalSince($0))) s" } ?? ""
                setToast(CtlToast(fail: false, text: confirmedText(cp.action) + lat, retry: nil), after: 2.5)
            } else {
                setToast(CtlToast(fail: true, text: "Carro não respondeu", retry: cp.action), after: 8)
            }
        default: break
        }
    }

    private func setToast(_ t: CtlToast?, after: TimeInterval = 0) {
        toastWork?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { toast = t }
        if t != nil, after > 0 {
            let work = DispatchWorkItem { withAnimation(.easeIn(duration: 0.25)) { toast = nil } }
            toastWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: work)
        }
    }

    private func confirmedText(_ action: String) -> String {
        switch action {
        case "lock_close":    return "Travado"
        case "lock_open":     return "Destravado"
        case "windows_open":  return "Vidros abertos"
        case "windows_close": return "Vidros fechados"
        case "trunk_open":    return "Porta-malas aberto"
        case "sunroof_open":  return "Teto aberto"
        case "sunroof_close": return "Teto fechado"
        case "engine_on":     return "Motor ligado"
        case "engine_off":    return "Motor desligado"
        default:              return "Feito"
        }
    }

    private static func verb(_ action: String) -> String {
        switch action {
        case "lock_close":    return "Travar"
        case "lock_open":     return "Destravar"
        case "windows_open":  return "Abrir vidros"
        case "windows_close": return "Fechar vidros"
        case "trunk_open":    return "Porta-malas"
        case "sunroof_open":  return "Abrir teto"
        case "sunroof_close": return "Fechar teto"
        case "engine_on":     return "Ligar motor"
        case "engine_off":    return "Desligar motor"
        default:              return action
        }
    }

    private func microLabel(_ t: String) -> some View {
        HStack {
            Text(t).font(.system(size: 8.5, weight: .bold)).tracking(1).foregroundStyle(DS.muted)
            Spacer()
        }
    }
}
