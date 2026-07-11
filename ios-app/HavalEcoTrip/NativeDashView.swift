//
//  NativeDashView.swift
//  Aba Painel — visão do carro parado: localização, trava/motor (ícones),
//  energia (bateria + tanque por nível), clima, e cards colapsáveis de pneus,
//  portas e vidros (abrem sozinhos em anomalia) + hodômetro/12V/manutenção.
//

import SwiftUI
import MapKit

struct NativeDashView: View {
    @ObservedObject private var store = CarStore.shared
    @StateObject private var maint = MaintenanceStore()
    @StateObject private var health = HealthScoreStore()
    @ObservedObject private var trips = TripsLoader.shared
    @StateObject private var cfg = ConfigStore()
    @State private var busy = false
    @State private var showPreclimat = false
    @State private var showMaint = false
    @State private var showLock = false
    @State private var showEngine = false
    @State private var showNotifCenter = false
    @State private var showArrival = false
    @State private var showWindows = false
    @State private var showTrunk = false
    @State private var showHazard = false
    @State private var showParking = false
    @State private var showShare = false
    @State private var showTimeline = false
    @State private var showAssistant = false
    // Feedback visual da troca de limite de carga (Haptic Touch no card):
    // pendingLimit = valor selecionado aguardando o carro confirmar (amarelo);
    // limitFeedback: 0=nenhum · 1=confirmado (verde) · 2=recusado (vermelho).
    @State private var pendingLimit: Int? = nil
    @State private var limitFeedback = 0
    @State private var limitTimeout: DispatchWorkItem? = nil
    @State private var showChargeTarget = false
    @State private var showLeaveBy = false
    @State private var showFuelCalib = false
    @State private var showHealth = false
    @State private var showDestCost = false
    @AppStorage("dash_hero_style") private var heroStyle = "padrao"

    private let tankL = 55.0   // capacidade aprox. do tanque (H6 PHEV) p/ o medidor

    private func f0(_ v: Double) -> String { String(format: "%.0f", v) }
    private func f1(_ v: Double) -> String { String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",") }
    private func brl(_ v: Double) -> String { Fmt.brl(v) }
    private static let grp: NumberFormatter = {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.groupingSeparator = "."; f.maximumFractionDigits = 0; return f
    }()
    private func miles(_ v: Double) -> String { Self.grp.string(from: NSNumber(value: v)) ?? f0(v) }

    var body: some View {
        ScrollView {
            VStack(spacing: 11) {
                header
                if store.onWifiFallback { fallbackBanner }
                else if store.isOffline { offlineBanner }
                if let cp = store.commandProgress { commandBanner(cp) }
                carHero
                if heroStyle != "padrao" {
                    if store.isCharging { chargingCard }
                    else { HStack(spacing: 14) { batteryCard; fuelCard } }
                }   // no padrão, bateria/tanque/carga vivem todos dentro do herói
                if heroStyle == "padrao" { climateCard }   // no desenho, temp/odômetro/12V vivem dentro do herói + card de bateria
                LiveRouteBanner()
                locationCard
                HStack(spacing: 11) { revisaoCard; healthCard }
                tripCard
            }
            .padding(16)
        }
        .background(DS.bg.ignoresSafeArea())
        .onAppear { store.start(); Task { await maint.load() }; Task { await trips.load() }; Task { await health.load() } }
        .sheet(isPresented: $showPreclimat) { PreclimatSheet() }
        .sheet(isPresented: $showMaint) { MaintenanceSheet(store: maint) }
        .sheet(isPresented: $showNotifCenter) { NotificationsCenterSheet() }
        .sheet(isPresented: $showArrival) { ArrivalSheet(trips: trips.trips) }
        .sheet(isPresented: $showParking) { ParkingSheet() }
        .sheet(isPresented: $showChargeTarget) { ChargeTargetSheet(cfg: cfg) }
        .sheet(isPresented: $showLeaveBy) { LeaveBySheet() }
        .sheet(isPresented: $showShare) { ShareStatusSheet() }
        .sheet(isPresented: $showTimeline) { EventsTimelineSheet() }
        .sheet(isPresented: $showAssistant) { AssistantSheet() }
        .sheet(isPresented: $showFuelCalib) { FuelCalibSheet(currentL: store.fuelL, store: store) }
        .sheet(isPresented: $showHealth) { HealthScoreSheet() }
        .sheet(isPresented: $showDestCost) { DestinationsCostSheet() }
    }

    // MARK: banner de fallback — nuvem GWM/4G fora, telemetria viva pelo WiFi do carro
    private var fallbackBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi").font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.teal)
            VStack(alignment: .leading, spacing: 1) {
                Text("Ao vivo via WiFi").font(.caption.weight(.semibold)).foregroundStyle(DS.text)
                Text("Nuvem 4G fora — trava/motor/pneus podem estar congelados").font(.system(size: 10)).foregroundStyle(DS.muted)
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(DS.teal.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DS.teal.opacity(0.45), lineWidth: 1))
    }

    // MARK: banner offline — nada fresco do APK nem da GWM; valores são os últimos vistos
    private var offlineBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash").font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.muted)
            VStack(alignment: .leading, spacing: 1) {
                Text("Offline").font(.caption.weight(.semibold)).foregroundStyle(DS.text)
                Text("Sem conexão com o carro — dados \(ageText(store.dataAgeSec))").font(.system(size: 10)).foregroundStyle(DS.muted)
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(DS.panel2))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DS.border, lineWidth: 1))
    }

    // MARK: andamento de comando — confirmação ao vivo via resultCode da GWM
    private func cmdLabel(_ action: String) -> String {
        switch action {
        case "lock_open":     return "Destravar"
        case "lock_close":    return "Travar"
        case "engine_on":     return "Ligar motor"
        case "engine_off":    return "Desligar motor"
        case "windows_open":  return "Abrir vidros"
        case "windows_close": return "Fechar vidros"
        case "trunk_open":    return "Porta-malas"
        default:              return "Comando"
        }
    }

    @ViewBuilder
    private func commandBanner(_ cp: CarStore.CommandProgress) -> some View {
        let label = cmdLabel(cp.action)
        let (icon, tint, text): (String, Color, String) = {
            switch cp.phase {
            case "sent":    return ("paperplane.fill", DS.muted, "\(label) · enviando ao carro…")
            case "running": return ("hourglass",       DS.yellow, "\(label) · processando no carro…")
            case "done":
                if cp.ok == true {
                    return ("checkmark.circle.fill", DS.green, "\(label) · confirmado pelo carro")
                } else if let rc = cp.resultCode {
                    return ("xmark.circle.fill", DS.red, "\(label) · recusado pelo carro (cód \(rc))")
                } else {
                    return ("wifi.exclamationmark", DS.red, "\(label) · falha ao enviar — tente de novo")
                }
            case "timeout": return ("exclamationmark.triangle.fill", DS.yellow, "\(label) · sem resposta do carro")
            default:        return ("circle", DS.muted, label)
            }
        }()
        HStack(spacing: 8) {
            if cp.phase == "running" || cp.phase == "sent" {
                ProgressView().scaleEffect(0.7).frame(width: 16, height: 16)
            } else {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(tint)
            }
            Text(text).font(.caption.weight(.semibold)).foregroundStyle(DS.text).lineLimit(1).minimumScaleFactor(0.7)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(tint.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint.opacity(0.45), lineWidth: 1))
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.easeInOut(duration: 0.2), value: cp)
    }

    private func ageText(_ sec: Double) -> String {
        guard sec >= 0 else { return "indisponíveis" }
        if sec < 60   { return "de há \(Int(sec))s" }
        if sec < 3600 { return "de há \(Int(sec/60))min" }
        if sec < 86400 { return "de há \(Int(sec/3600))h" }
        return "de há \(Int(sec/86400))d"
    }

    // MARK: localização + central de notificações + versão do carro
    private var header: some View {
        let apkVer = store.str("car_app_version")
        return HStack(spacing: 8) {
            Text("Haval Hub").font(.title3.weight(.bold)).foregroundStyle(DS.text)
            Spacer(minLength: 6)
            if store.lanConnected { DSChip(text: "LAN", color: DS.teal, filled: true) }
            if !apkVer.isEmpty {
                Text("carro v\(apkVer)").font(.system(size: 9)).foregroundStyle(DS.muted).lineLimit(1)
            }
            Button { showAssistant = true } label: {
                Image(systemName: "sparkles").font(.system(size: 15)).foregroundStyle(DS.teal)
            }
            Button { showTimeline = true } label: {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 15)).foregroundStyle(DS.text)
            }
            Button { showNotifCenter = true } label: {
                Image(systemName: "bell.fill").font(.system(size: 15)).foregroundStyle(DS.text)
            }
            Circle().fill(store.carOnline ? DS.green : DS.red).frame(width: 9, height: 9)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
    }

    // MARK: herói do carro — render real do H6 com estado ao vivo + fileira de comandos
    private var heroState: CarHeroState {
        CarHeroState(
            locked: store.lockKnown ? store.isLocked : nil,
            charging: store.isCharging,
            acOn: store.acOn,
            doors: ["door_fl","door_fr","door_rl","door_rr"].map { store.str($0) == "on" },
            windows: ["window_fl","window_fr","window_rl","window_rr"].map { store.str($0) == "on" },
            sunroof: store.str("sunroof") == "on",
            trunk: store.str("door_trunk") == "on",
            tyres: ["tyre_pressure_fl","tyre_pressure_fr","tyre_pressure_rl","tyre_pressure_rr"].map { store.num($0) }
        )
    }
    private var statusData: CarStatusData {
        let doorNames: [(String, String)] = [
            ("door_fl", "DE"), ("door_fr", "DD"),
            ("door_rl", "TE"), ("door_rr", "TD"),
            ("door_trunk", "Mala")
        ]
        let winNames: [(String, String)] = [
            ("window_fl", "DE"), ("window_fr", "DD"),
            ("window_rl", "TE"), ("window_rr", "TD"),
            ("sunroof", "Teto")
        ]
        let openDoors = doorNames.filter { store.str($0.0) == "on" }.map { $0.1 }
        let openWindows = winNames.filter { store.str($0.0) == "on" }.map { $0.1 }
        return CarStatusData(
            locked: store.lockKnown ? store.isLocked : nil,
            charging: store.isCharging,
            engineOn: store.engineOn,
            socPct: store.socPct,
            rangeEvKm: store.rangeEvKm,
            chargePowerKw: store.chargePowerKw,
            openDoors: openDoors,
            openWindows: openWindows,
            tyres: ["tyre_pressure_fl","tyre_pressure_fr","tyre_pressure_rl","tyre_pressure_rr"].map { store.num($0) },
            tyreTemps: ["tyre_temp_fl","tyre_temp_fr","tyre_temp_rl","tyre_temp_rr"].map { store.num($0) },
            chargeSessionKwh: store.chargeSessionKwh,
            chargeRemainingMin: store.chargeRemainingMin,
            chargeLimitPct: store.num("charge_limit_pct"),
            chargeTargetPct: Int(store.num("charge_custom_target")),
            fuelL: store.fuelL,
            rangeIceKm: store.rangeIceKm,
            priceKwh: store.priceKwh,
            priceGas: store.priceGas,
            tankL: tankL
        )
    }
    private var carHero: some View {
        let on = store.engineOn
        // no estilo "padrão" toda a energia (bateria/tanque/carga) vive dentro do herói;
        // aí o card ganha o Haptic Touch pra trocar limite/alvo de carga a qualquer hora.
        let merged = heroStyle == "padrao"
        return DSCard(bg: on ? DS.green.opacity(0.14) : nil, borderColor: on ? DS.green.opacity(0.55) : nil, compact: true) {
            VStack(alignment: .leading, spacing: 4) {
                if heroStyle == "padrao" {
                    CarStatusInfoView(data: statusData)
                } else {
                    if !store.address.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "location.fill").font(.system(size: 10)).foregroundStyle(DS.green)
                            Text(store.address).font(.system(size: 11)).foregroundStyle(DS.muted).lineLimit(1)
                        }
                    }
                    HStack(alignment: .center, spacing: 10) {
                        CarHeroView(state: heroState,
                                    onLock: { showLock = true },
                                    onTrunk: { showTrunk = true })
                            .frame(width: 140, height: 170)
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            heroMiniCard("Interna", "\(f0(store.insideTemp))°",
                                         "thermometer.medium", DS.text)
                            heroMiniCard("Externa", "\(f0(store.outsideTemp))°",
                                         "thermometer.sun.fill", DS.orange)
                            heroMiniCard("Km", store.odometerKm > 0 ? "\(miles(store.odometerKm))" : "—",
                                         "gauge.with.dots.needle.bottom.50percent", DS.text)
                            heroMiniCard(store.batt12vV > 0 ? "\(f1(store.batt12vV))V" : "12V",
                                         store.batt12vPct > 0 ? "\(f0(store.batt12vPct))%" : "—",
                                         "minus.plus.batteryblock.fill",
                                         store.batt12vPct > 0 ? volt12Color(store.batt12vPct) : DS.muted)
                        }
                    }
                }
                carControls
            }
        }
        .if(merged) { v in
            v.contextMenu { chargeLimitMenu }
                .onChange(of: store.num("charge_limit_pct")) { _, newVal in
                    if let p = pendingLimit, Int(newVal) == p {
                        limitTimeout?.cancel(); limitTimeout = nil
                        pendingLimit = nil; limitFeedback = 1; clearLimitFeedbackLater()
                    }
                }
        }
    }

    // Temp interna/externa acima do desenho do carro (AC saiu daqui).
    private var heroTempStrip: some View {
        HStack(spacing: 8) {
            heroTempPill(icon: "thermometer.medium", value: f0(store.insideTemp), label: "int")
            heroTempPill(icon: "thermometer.sun", value: f0(store.outsideTemp), label: "ext")
        }
    }

    // Mini-card pro grid 2x2 ao lado do PNG (Interna/Externa/Km/12V).
    private func heroMiniCard(_ label: String, _ value: String, _ icon: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10)).foregroundStyle(DS.muted)
                Text(label).font(.system(size: 10)).foregroundStyle(DS.muted)
            }
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .monospacedDigit().foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.65)
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(DS.panel2.opacity(0.6)))
    }
    private func heroTempPill(icon: String, value: String, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(DS.muted)
            Text("\(value)°").font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(DS.text)
            Text(label).font(.system(size: 9)).foregroundStyle(DS.muted)
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Capsule().fill(DS.panel2.opacity(0.85)))
        .overlay(Capsule().stroke(DS.border, lineWidth: 1))
    }

    // Hodômetro logo abaixo do porta-malas (centro inferior do desenho).
    private var heroOdometer: some View {
        HStack(spacing: 4) {
            Image(systemName: "gauge.with.dots.needle.bottom.50percent").font(.system(size: 11)).foregroundStyle(DS.muted)
            Text(store.odometerKm > 0 ? "\(miles(store.odometerKm)) km" : "—")
                .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(DS.text)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(DS.panel2.opacity(0.85)))
        .overlay(Capsule().stroke(DS.border, lineWidth: 1))
        .padding(.bottom, 2)
    }

    @ViewBuilder private var chargeLimitMenu: some View {
        let limit = store.num("charge_limit_pct")
        let customTarget = Int(store.num("charge_custom_target"))
        Text("Limite de carga (SOC)")
        ForEach([50,60,70,80,90,100], id: \.self) { p in
            Button { selectChargeLimit(p) } label: {
                Label("\(p)%", systemImage: customTarget == 0 && (pendingLimit ?? Int(limit)) == p ? "checkmark" : "bolt")
            }
        }
        Divider()
        Button { showChargeTarget = true } label: {
            Label(customTarget > 0 ? "Alvo personalizado: \(customTarget)%" : "Alvo personalizado…",
                  systemImage: customTarget > 0 ? "checkmark" : "slider.horizontal.3")
        }
    }

    // MARK: fileira de comandos (trava/motor/clima/vidros/malas/pisca) com confirmação ancorada
    private var carControls: some View {
        let winOpen = ["window_fl","window_fr","window_rl","window_rr"].contains { store.str($0) == "on" }
        return HStack {
                iconButton(icon: store.isLocked ? "lock.fill" : "lock.open.fill",
                           tint: store.isLocked ? DS.green : DS.orange,
                           caption: !store.lockKnown ? "—" : (store.isLocked ? "Trancado" : "Destranc."),
                           frozen: store.isFrozen("lock_state")) {
                    showLock = true
                }
                .popover(isPresented: $showLock) {
                    confirmPopover(title: store.isLocked ? "Destravar carro?" : "Travar carro?",
                                   confirm: store.isLocked ? "Destravar" : "Travar", danger: store.isLocked,
                                   name: store.isLocked ? "lock_open" : "lock_close", binding: $showLock)
                }
                Spacer()
                iconButton(icon: "power", tint: store.engineOn ? DS.green : DS.muted,
                           caption: store.engineOn ? "Ligado" : "Desligado",
                           frozen: store.isFrozen("engine_state")) {
                    showEngine = true
                }
                .popover(isPresented: $showEngine) {
                    confirmPopover(title: store.engineOn ? "Desligar motor?" : "Ligar motor?",
                                   confirm: store.engineOn ? "Desligar" : "Ligar", danger: store.engineOn,
                                   name: store.engineOn ? "engine_off" : "engine_on", binding: $showEngine)
                }
                Spacer()
                iconButton(icon: "fan.fill", tint: DS.blue, caption: "Clima") { showPreclimat = true }
                Spacer()
                iconButton(icon: "macwindow", tint: DS.teal, caption: winOpen ? "Fechar" : "Vidros") {
                    showWindows = true
                }
                .popover(isPresented: $showWindows) {
                    confirmPopover(title: winOpen ? "Fechar os vidros?" : "Abrir os vidros?",
                                   confirm: winOpen ? "Fechar" : "Abrir", danger: false,
                                   name: winOpen ? "windows_close" : "windows_open", binding: $showWindows)
                }
                Spacer()
                iconButton(icon: "suitcase.fill", tint: DS.muted, caption: "Malas") {
                    showTrunk = true
                }
                .popover(isPresented: $showTrunk) {
                    confirmPopover(title: "Abrir o porta-malas?", confirm: "Abrir", danger: false,
                                   name: "trunk_open", binding: $showTrunk)
                }
                Spacer()
                iconButton(icon: "light.beacon.max.fill", tint: DS.yellow, caption: "Achar") {
                    showHazard = true
                }
                .popover(isPresented: $showHazard) {
                    confirmPopoverAction(title: "Piscar os faróis e buzinar para localizar o carro?",
                                         confirm: "Piscar e buzinar", danger: false, binding: $showHazard) {
                        _ = await store.action("find_car_honk")
                    }
                }
            }
    }

    private func rightMetric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value).font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(DS.text).lineLimit(1).minimumScaleFactor(0.6)
            Text(label.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(DS.muted)
        }
    }

    private func confirmPopover(title: String, confirm: String, danger: Bool, name: String, binding: Binding<Bool>) -> some View {
        VStack(spacing: 14) {
            Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(DS.text).multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button("Cancelar") { binding.wrappedValue = false }
                    .frame(maxWidth: .infinity).frame(height: 44).foregroundStyle(DS.text).background(DS.panel2).clipShape(RoundedRectangle(cornerRadius: 11))
                Button(confirm) { binding.wrappedValue = false; store.fireCommand(name) }
                    .frame(maxWidth: .infinity).frame(height: 44).foregroundStyle(.black).background(danger ? DS.red : DS.green).clipShape(RoundedRectangle(cornerRadius: 11)).font(.system(size: 15, weight: .bold))
            }
        }
        .padding(18).frame(width: 280).background(DS.panel)
        .presentationCompactAdaptation(.popover)
    }

    // Igual ao confirmPopover, mas executa uma ação custom (não um /api/action/<name>).
    private func confirmPopoverAction(title: String, confirm: String, danger: Bool,
                                      binding: Binding<Bool>, action: @escaping () async -> Void) -> some View {
        VStack(spacing: 14) {
            Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(DS.text).multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button("Cancelar") { binding.wrappedValue = false }
                    .frame(maxWidth: .infinity).frame(height: 44).foregroundStyle(DS.text).background(DS.panel2).clipShape(RoundedRectangle(cornerRadius: 11))
                Button(confirm) { binding.wrappedValue = false; busy = true; Task { await action(); busy = false } }
                    .frame(maxWidth: .infinity).frame(height: 44).foregroundStyle(.black).background(danger ? DS.red : DS.green).clipShape(RoundedRectangle(cornerRadius: 11)).font(.system(size: 15, weight: .bold))
            }
        }
        .padding(18).frame(width: 280).background(DS.panel)
        .presentationCompactAdaptation(.popover)
    }

    private func iconButton(icon: String, tint: Color, caption: String, frozen: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: icon).font(.system(size: 15, weight: .medium)).foregroundStyle(frozen ? DS.muted : tint)
                        .frame(width: 38, height: 38).background(DS.panel2).clipShape(Circle())
                        .overlay(Circle().stroke(DS.border, lineWidth: 1))
                    if frozen {
                        Image(systemName: "snowflake").font(.system(size: 9, weight: .bold)).foregroundStyle(DS.blue)
                            .padding(2).background(DS.panel2).clipShape(Circle()).offset(x: 4, y: -2)
                    }
                }
                Text(caption).font(.system(size: 9.5, weight: .medium)).foregroundStyle(DS.muted)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .buttonStyle(.plain).disabled(busy).opacity(frozen ? 0.7 : 1)
    }

    // MARK: energia
    private func batteryIcon(_ soc: Double) -> String {
        switch soc { case ..<13: return "battery.0percent"; case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"; case ..<88: return "battery.75percent"; default: return "battery.100percent" }
    }
    private func volt12Color(_ p: Double) -> Color {
        if p >= 90 { return DS.green }
        if p >= 80 { return DS.orange }
        if p >= 70 { return DS.yellow }
        return DS.red
    }
    private var batteryCard: some View {
        let soc = store.socPct
        let tint: Color = soc < 20 ? DS.red : (soc < 50 ? DS.yellow : DS.green)
        return DSCard {
            VStack(alignment: .leading, spacing: 10) {
                LevelBadge(icon: batteryIcon(soc), fraction: soc/100, value: f0(soc), unit: "%", label: "Bateria", tint: tint)
                HStack {
                    Text("\(f0(store.rangeEvKm)) km EV").font(.caption).foregroundStyle(DS.muted)
                    Spacer()
                    if store.priceKwh > 0 { Text("\(brl(store.priceKwh))/kWh").font(.caption).foregroundStyle(DS.green) }
                }
            }
        }
    }

    // Recarregando: bateria expandida (esconde tanque) + dados da carga atual.
    // O tick branco na barra mostra o limite de carga configurado; segurar o card
    // (Haptic Touch) abre o menu pra trocar o limite sem ir em Configurações.
    private var chargingCard: some View {
        let soc = store.socPct
        let limit = store.num("charge_limit_pct")
        let customTarget = Int(store.num("charge_custom_target"))   // 0 = corte por software desligado
        // Com alvo custom ativo, o marcador/limite exibido é o ALVO (não o preset
        // nativo, que fica em 100 enquanto carrega e cai pro freio só no corte).
        let effLimit: Double = customTarget > 0 ? Double(customTarget) : limit
        // Estado visual do limite: pendente (amarelo) → confirmado (verde) / recusado (vermelho).
        let markerFrac: Double? = pendingLimit.map { Double($0)/100 } ?? (effLimit > 0 ? effLimit/100 : nil)
        let accent: Color = pendingLimit != nil ? DS.yellow
            : (limitFeedback == 1 ? DS.green : (limitFeedback == 2 ? DS.red : DS.muted))
        let markerColor: Color = pendingLimit != nil ? DS.yellow
            : (limitFeedback == 1 ? DS.green : (limitFeedback == 2 ? DS.red : Color.white.opacity(0.85)))
        let badgeLabel: String = {
            if let p = pendingLimit { return "Aplicando limite \(p)%…" }
            if customTarget > 0 { return "Bateria · alvo \(customTarget)% (corte automático)" }
            if limitFeedback == 1 { return "Limite \(f0(limit))% confirmado" }
            if limitFeedback == 2 { return "Limite não aplicado — tente de novo" }
            return limit > 0 && limit < 100 ? "Bateria · limite \(f0(limit))%" : "Bateria"
        }()
        return DSCard(title: "Carregando", icon: "bolt.fill") {
            VStack(alignment: .leading, spacing: 12) {
                LevelBadge(icon: batteryIcon(soc), fraction: soc/100, value: f0(soc), unit: "%",
                           label: badgeLabel, tint: DS.green,
                           markerFraction: markerFrac, markerColor: markerColor, labelColor: accent)
                HStack {
                    DSMetric(value: f1(store.chargePowerKw), unit: "kW", label: "Potência", color: DS.green)
                    DSMetric(value: f1(store.chargeSessionKwh), unit: "kWh", label: "Sessão", color: DS.teal)
                    DSMetric(value: store.chargeRemainingMin > 0 ? "\(store.chargeRemainingMin)" : "—", unit: "min", label: "Faltam")
                    DSMetric(value: f0(store.rangeEvKm), unit: "km", label: "Autonomia")
                }
            }
        }
        .contextMenu {
            Text("Limite de carga (SOC)")
            ForEach([50,60,70,80,90,100], id: \.self) { p in
                Button { selectChargeLimit(p) } label: {
                    Label("\(p)%", systemImage: customTarget == 0 && (pendingLimit ?? Int(limit)) == p ? "checkmark" : "bolt")
                }
            }
            Divider()
            Button { showChargeTarget = true } label: {
                Label(customTarget > 0 ? "Alvo personalizado: \(customTarget)%" : "Alvo personalizado…",
                      systemImage: customTarget > 0 ? "checkmark" : "slider.horizontal.3")
            }
        }
        // Carro confirmou: o limite reportado virou o valor pedido.
        .onChange(of: store.num("charge_limit_pct")) { _, newVal in
            if let p = pendingLimit, Int(newVal) == p {
                limitTimeout?.cancel(); limitTimeout = nil
                pendingLimit = nil; limitFeedback = 1; clearLimitFeedbackLater()
            }
        }
    }

    // Seleciona um novo limite: marca como pendente (amarelo), envia ao carro e
    // arma um timeout — se o carro não confirmar, marca como recusado (vermelho).
    private func selectChargeLimit(_ p: Int) {
        if Int(store.num("charge_limit_pct")) == p { return }   // já é o limite atual
        limitTimeout?.cancel()
        pendingLimit = p
        limitFeedback = 0
        Task { await cfg.setChargeLimit(p) }
        let work = DispatchWorkItem {
            if pendingLimit == p { pendingLimit = nil; limitFeedback = 2; clearLimitFeedbackLater() }
        }
        limitTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
    }
    private func clearLimitFeedbackLater() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { limitFeedback = 0 }
    }

    private var fuelCard: some View {
        let frac = min(1, store.fuelL / tankL)
        let tint: Color = frac < 0.15 ? DS.red : (frac < 0.35 ? DS.yellow : DS.orange)
        return DSCard {
            VStack(alignment: .leading, spacing: 10) {
                LevelBadge(icon: "fuelpump.fill", fraction: frac, value: f0(store.fuelL), unit: "L", label: "Tanque", tint: tint)
                HStack {
                    Text("\(f0(store.rangeIceKm)) km térmico").font(.caption).foregroundStyle(DS.muted)
                    Spacer()
                    if store.priceGas > 0 { Text("\(brl(store.priceGas))/L").font(.caption).foregroundStyle(DS.orange) }
                }
            }
        }
        .onLongPressGesture { showFuelCalib = true }
    }

    // MARK: clima (compacto)
    private var climateCard: some View {
        let acActive = store.acOn
        return DSCard {
            HStack(spacing: 8) {
                Image(systemName: acActive ? "snowflake" : "thermometer.medium")
                    .font(.title3).foregroundStyle(acActive ? DS.blue : DS.muted)
                Text("\(f0(store.insideTemp))°").font(.system(size: 19, weight: .semibold, design: .rounded)).foregroundStyle(DS.text)
                Text("int").font(.caption).foregroundStyle(DS.muted)
                Text("·").foregroundStyle(DS.muted)
                Text("\(f0(store.outsideTemp))°").font(.system(size: 16, weight: .medium)).foregroundStyle(DS.text)
                Text("ext").font(.caption).foregroundStyle(DS.muted)
                if acActive { DSChip(text: "AC", color: DS.blue, filled: true) }
                Spacer()
                rightMetric("Hodômetro", store.odometerKm > 0 ? "\(miles(store.odometerKm)) km" : "—")
                if store.batt12vPct > 0 {
                    let v12 = store.batt12vV
                    rightMetric("12V", v12 > 0 ? "\(f0(store.batt12vPct))% · \(f1(v12))V" : "\(f0(store.batt12vPct))%")
                }
            }
        }
    }

    // MARK: localização + ações (mapa agora vive só na aba Drive). Destino, estacionamento,
    // autonomia e compartilhar status em botões grandes.
    private var locationCard: some View {
        DSCard(compact: true) {
            HStack {
                    iconButton(icon: "location.north.fill", tint: DS.teal, caption: "Destino") { showArrival = true }
                    Spacer()
                    iconButton(icon: "parkingsign", tint: DS.green, caption: "Estacionei") { showParking = true }
                    Spacer()
                    iconButton(icon: "square.and.arrow.up", tint: DS.blue, caption: "Compartilhar") { showShare = true }
                    Spacer()
                    iconButton(icon: "clock.arrow.circlepath", tint: DS.teal, caption: "Saída") { showLeaveBy = true }
                    Spacer()
                    iconButton(icon: "dollarsign.arrow.circlepath", tint: DS.green, caption: "Custo") { showDestCost = true }
            }
        }
    }

    // MARK: revisão (botão → popup com tudo)
    private var revisaoCard: some View {
        let next = maint.items.first
        return DSCard {
            Button { showMaint = true } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "wrench.and.screwdriver.fill").font(.subheadline).foregroundStyle(DS.muted)
                        Text("Revisão").font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.text)
                            .lineLimit(1).minimumScaleFactor(0.8)
                        Spacer(minLength: 4)
                        if let n = next { Circle().fill(n.statusColor).frame(width: 9, height: 9) }
                    }
                    Text(next.map { "\($0.label ?? "Próxima") · \(maintWhen($0))" } ?? "Ver histórico e custos")
                        .font(.caption).foregroundStyle(DS.muted)
                        .lineLimit(2).minimumScaleFactor(0.85).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
                }
            }.buttonStyle(.plain)
        }
    }

    // MARK: saúde consolidada do carro (botão → sheet com breakdown)
    private var healthCard: some View {
        DSCard {
            Button { showHealth = true } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "heart.text.square.fill").font(.subheadline).foregroundStyle(DS.green)
                        Text("Saúde do carro").font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.text)
                            .lineLimit(1).minimumScaleFactor(0.8)
                        Spacer(minLength: 4)
                        if let s = health.data?.total {
                            Text("\(s)").font(.system(size: 14, weight: .bold, design: .rounded)).monospacedDigit()
                                .foregroundStyle(healthTint(s))
                        }
                    }
                    Text("Bateria 12V, pneus, consumo e manutenção")
                        .font(.caption).foregroundStyle(DS.muted)
                        .lineLimit(2).minimumScaleFactor(0.85).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
                }
            }.buttonStyle(.plain)
        }
    }

    private func healthTint(_ s: Int) -> Color {
        s >= 85 ? DS.green : s >= 70 ? DS.teal : s >= 50 ? DS.yellow : DS.red
    }

    private func maintWhen(_ m: MaintItem) -> String {
        if let km = m.remaining_km { return km <= 0 ? "vencida" : "faltam \(miles(km)) km" }
        if let d = m.remaining_days { return d <= 0 ? "vencida" : "faltam \(f0(d)) dias" }
        return ""
    }

    // MARK: viagem em andamento (ou última)
    @ViewBuilder private var tripCard: some View {
        if store.tripActive {
            Button { TabRouter.shared.go(.drive) } label: {
                DSCard(title: "Viagem em andamento", icon: "car.fill") {
                    VStack(alignment: .leading, spacing: 10) {
                        tripMetrics(distKm: store.tripDistKm, timeSec: Double(store.tripTimeSec),
                                    netKwh: store.tripNetKwh, fuelL: store.tripFuelL)
                        tripCardHint("Ver ao vivo no Drive")
                    }
                }
            }.buttonStyle(.plain)
        } else if let t = trips.trips.first {
            Button { trips.focusTripId = t.id; TabRouter.shared.go(.viagens) } label: {
                DSCard(title: "Última viagem", icon: "car.fill") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(lastTripDate(t)).font(.caption).foregroundStyle(DS.muted).frame(maxWidth: .infinity, alignment: .leading)
                        tripMetrics(distKm: t.distKm, timeSec: t.timeSec, netKwh: t.netKwh, fuelL: t.fuelL)
                        tripCardHint("Ver detalhes em Viagens")
                    }
                }
            }.buttonStyle(.plain)
        }
    }

    private func tripCardHint(_ s: String) -> some View {
        HStack(spacing: 4) {
            Spacer()
            Text(s).font(.caption2).foregroundStyle(DS.muted)
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(DS.muted)
        }
    }

    private func tripMetrics(distKm: Double, timeSec: Double, netKwh: Double, fuelL: Double) -> some View {
        let cons = distKm > 0.5 ? netKwh / distKm * 100 : 0
        let h = Int(timeSec) / 3600, m = (Int(timeSec) % 3600) / 60
        return HStack {
            DSMetric(value: f1(distKm), unit: "km", label: "Distância", color: DS.teal)
            DSMetric(value: h > 0 ? "\(h)h \(m)min" : "\(m) min", label: "Tempo")
            DSMetric(value: f1(netKwh), unit: "kWh", label: "Energia", color: DS.green)
            DSMetric(value: cons > 0 ? f1(cons) : "—", unit: "kWh/100", label: "Consumo")
        }
    }

    private static let tripDF: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR"); f.dateFormat = "d MMM · HH:mm"; return f }()
    private func lastTripDate(_ t: Trip) -> String { Self.tripDF.string(from: t.date) }
}

struct FuelCalibSheet: View {
    let currentL: Double
    let store: CarStore
    @Environment(\.dismiss) private var dismiss
    @State private var inputText = ""
    @State private var saving = false
    @State private var error: String? = nil

    @State private var added: Double = 20
    @State private var price: Double = 6.29

    private var addedL: Double? { added > 0 && added <= 55 ? added : nil }
    private var resultL: Double { min(55, currentL + added) }
    private let tankCap: Double = 55
    private var curPct: Int { Int((currentL / tankCap * 100).rounded()) }
    private var resultPct: Int { Int((resultL / tankCap * 100).rounded()) }
    private var totalCost: Double { added * price }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Hero
                    VStack(spacing: 4) {
                        Text("\(curPct)%")
                            .font(.system(size: 92, weight: .ultraLight, design: .rounded))
                            .foregroundStyle(DS.orange).monospacedDigit()
                        Text("~\(Fmt.dec1(currentL)) L no tanque")
                            .font(.system(size: 13)).foregroundStyle(DS.text2)
                    }
                    .padding(.top, 8)

                    // Steppers
                    VStack(spacing: 0) {
                        stepperRow("Abasteci agora", "\(Fmt.dec1(added)) L", down: { added = max(1, (added - 1).rounded()) }, up: { added = min(55, (added + 1).rounded()) })
                        Divider().overlay(DS.divider)
                        stepperRow("Preço", Fmt.brl(price), down: { price = max(0.5, ((price - 0.10) * 100).rounded() / 100) }, up: { price = min(15, ((price + 0.10) * 100).rounded() / 100) })
                    }
                    .background(DS.panel2).clipShape(RoundedRectangle(cornerRadius: 15))

                    // Preview
                    HStack(spacing: 6) {
                        Text("\(curPct)%").foregroundStyle(DS.text2)
                        Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(DS.muted)
                        Text("~\(resultPct)%").foregroundStyle(DS.orange)
                        Text("·").foregroundStyle(DS.muted)
                        Text(Fmt.brl(totalCost)).foregroundStyle(DS.text)
                    }
                    .font(.system(size: 15, weight: .semibold)).monospacedDigit()
                    .padding(.vertical, 12).frame(maxWidth: .infinity)
                    .background(DS.panel).clipShape(RoundedRectangle(cornerRadius: 15))

                    if let e = error {
                        Text(e).font(.system(size: 12)).foregroundStyle(DS.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // CTA
                    Button { Task { await save() } } label: {
                        HStack(spacing: 8) {
                            if saving { ProgressView().tint(.black) }
                            Text(saving ? "Registrando…" : "Registrar abastecimento")
                                .font(.system(size: 15, weight: .bold))
                        }
                        .frame(maxWidth: .infinity).frame(height: 42)
                        .foregroundStyle(.black).background(DS.green).clipShape(Capsule())
                    }
                    .disabled(saving || addedL == nil)

                    Text("Sensor antes do abastecimento: \(Fmt.dec1(currentL)) L. Corrige o nível do tanque no bridge.")
                        .font(.system(size: 10.5)).foregroundStyle(DS.muted)
                        .multilineTextAlignment(.center).padding(.top, 2)
                }.padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Corrigir abastecimento")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
            }
            .onAppear { if store.priceGas > 0 { price = store.priceGas } }
        }
    }

    private func stepperRow(_ label: String, _ value: String, down: @escaping () -> Void, up: @escaping () -> Void) -> some View {
        HStack {
            Text(label).font(.system(size: 13)).foregroundStyle(DS.text2)
            Spacer()
            Text(value).font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.text).monospacedDigit()
            HStack(spacing: 8) {
                Button(action: down) {
                    Image(systemName: "minus").font(.system(size: 14, weight: .bold)).foregroundStyle(DS.blue)
                        .frame(width: 34, height: 30).background(DS.panel).clipShape(RoundedRectangle(cornerRadius: 9))
                }
                Button(action: up) {
                    Image(systemName: "plus").font(.system(size: 14, weight: .bold)).foregroundStyle(DS.orange)
                        .frame(width: 34, height: 30).background(DS.panel).clipShape(RoundedRectangle(cornerRadius: 9))
                }
            }
            .padding(.leading, 8)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func save() async {
        guard let added = addedL else { return }
        let actual = currentL + added
        guard actual <= 55 else { error = "Total excede capacidade do tanque (55 L)"; return }
        saving = true
        let ok = await store.command("/api/fuel-calibrate", body: ["actual_l": actual])
        saving = false
        if ok { dismiss() } else { error = "Falha ao comunicar com o bridge" }
    }
}
