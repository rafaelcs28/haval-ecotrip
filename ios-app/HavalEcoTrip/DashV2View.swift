//
//  DashV2View.swift
//  Painel v2 — redesign "Energia como hero" (design-v2/README.md, frame 1a).
//  V1 (NativeDashView) permanece intacta; troca via flag ui_v2.
//

import SwiftUI

enum UIv2 {
    // v2 shipada (build 2607030410+); flag segue existindo pra voltar à v1 na Config.
    static let defaultOn = true
}

struct DashV2View: View {
    @ObservedObject private var store = CarStore.shared
    @ObservedObject private var trips = TripsLoader.shared
    @StateObject private var maint = MaintenanceStore()
    @StateObject private var health = HealthScoreStore()

    @State private var showLock = false
    @State private var showWindows = false
    @State private var showTrunk = false
    @State private var showEngine = false
    @State private var showHazard = false
    @State private var showPreclimat = false
    @State private var showLeaveBy = false
    @State private var showHealth = false
    @State private var showMaint = false
    @State private var showArrival = false
    @State private var showParking = false
    @State private var showRange = false
    @State private var showShare = false
    @State private var showDestCost = false
    @State private var showTimeline = false
    @State private var showAssistant = false
    @State private var showNotifCenter = false
    @State private var showChargeTarget = false
    @State private var showFuelCalib = false
    @StateObject private var cfg = ConfigStore()
    @State private var anomalySince: Date?
    @State private var toast: CmdToast?
    @State private var toastDismiss: DispatchWorkItem?
    @State private var cmdSentAt: Date?

    struct CmdToast {
        let fail: Bool
        let text: String
        let retryAction: String?
        let latency: String?
    }

    // Override de estado pra preview no sim (DEBUG):
    // xcrun simctl spawn booted defaults write br.com.consorciolimpagyn.havalecotrip v2_preview anomalia|dormindo|dirigindo
    @AppStorage("v2_preview") private var previewRaw: String = ""

    private let tankL = 55.0

    private var pv: String {
        #if DEBUG
        previewRaw
        #else
        ""
        #endif
    }

    // MARK: estados derivados (matriz 3a–3d)

    private var isSleeping: Bool {
        pv == "dormindo" || (store.connected && !store.carOnline && store.dataAgeSec >= 60)
    }
    private var isDriving: Bool {
        pv == "dirigindo" || store.tripActive ||
        (store.engineOn && (store.gear == "D" || store.gear == "R" || store.speedKmh > 1))
    }
    private var openingsNow: [String] {
        pv == "anomalia" ? ["Porta tras. esq.", "Porta-malas"] : store.openings
    }
    private var unlockedAnomaly: Bool {
        pv == "anomalia" || (store.lockKnown && !store.isLocked && !store.engineOn)
    }
    private var hasAnomaly: Bool {
        !isDriving && (unlockedAnomaly || !openingsNow.isEmpty)
    }
    private var tyres: [Double] {
        pv == "anomalia" ? [36, 36, 33, 36] : [store.tyreFL, store.tyreFR, store.tyreRL, store.tyreRR]
    }
    private var tyreLowIdx: Int? {
        let t = tyres
        guard t.allSatisfy({ $0 > 0 }), let mx = t.max() else { return nil }
        if let i = t.firstIndex(where: { $0 < 32 || $0 <= mx - 3 }) { return i }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                headerRow
                if store.onWifiFallback { netBanner("wifi", DS.teal, "Ao vivo via WiFi",
                    "Nuvem 4G fora — trava/motor/pneus podem estar congelados") }
                else if store.isOffline { netBanner("wifi.slash", DS.red, "Offline",
                    "Sem dados frescos — valores são os últimos vistos") }
                LiveRouteBanner()
                if hasAnomaly { anomalyCard }
                Group {
                    heroEnergia
                    barsBlock
                    stateChips
                    if store.isCharging && !isDriving { chargingCardV2 }
                    if isDriving { tripLiveCard }
                    miniMetrics
                }
                .saturation(isSleeping ? 0.7 : 1)
                .brightness(isSleeping ? -0.13 : 0)
                if isSleeping { sleepInfoRow }
                actionsGrid
                quickRow
                if !isDriving { lastTripRow }
                HStack(spacing: 10) { saudeTile; saidaTile }
                if tyreLowIdx != nil { tyreBand }
                silentGroup
            }
            .padding(.horizontal, 18)
            .padding(.top, 6)
            .padding(.bottom, 16)
        }
        .background(DS.bg.ignoresSafeArea())
        .overlay(alignment: .bottom) {
            if let t = displayedToast { toastView(t).padding(.horizontal, 18).padding(.bottom, 8) }
        }
        .onChange(of: store.commandProgress?.ts) { _, _ in
            onCommandProgress()
        }
        .onAppear {
            store.start()
            if hasAnomaly { anomalySince = anomalySince ?? Date() }
            Task { await trips.load() }
            Task { await maint.load() }
            Task { await health.load() }
            #if DEBUG
            // Auto-abre sheet: defaults write ... dash_sheet -string saude
            let d = UserDefaults.standard
            if let k = d.string(forKey: "dash_sheet") {
                d.removeObject(forKey: "dash_sheet")
                Task {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    switch k {
                    case "saude": showHealth = true
                    case "preclima": showPreclimat = true
                    case "leaveby": showLeaveBy = true
                    case "maint": showMaint = true
                    case "arrival": showArrival = true
                    case "parking": showParking = true
                    case "range": showRange = true
                    case "share": showShare = true
                    case "destcost": showDestCost = true
                    case "timeline": showTimeline = true
                    case "assistant": showAssistant = true
                    case "notif": showNotifCenter = true
                    case "chargetarget": showChargeTarget = true
                    case "fuelcalib": showFuelCalib = true
                    default: break
                    }
                }
            }
            #endif
        }
        .onChange(of: hasAnomaly) { _, now in
            anomalySince = now ? (anomalySince ?? Date()) : nil
        }
        .sheet(isPresented: $showPreclimat) { PreclimaV2View() }
        .sheet(isPresented: $showLeaveBy) { LeaveBySheet() }
        .sheet(isPresented: $showHealth) { HealthScoreSheet() }
        .sheet(isPresented: $showMaint) { MaintenanceSheet(store: maint) }
        .sheet(isPresented: $showArrival) { ArrivalSheet(trips: trips.trips) }
        .sheet(isPresented: $showParking) { ParkingSheet() }
        .sheet(isPresented: $showRange) { RangeSheet() }
        .sheet(isPresented: $showShare) { ShareStatusSheet() }
        .sheet(isPresented: $showDestCost) { DestinationsCostSheet() }
        .sheet(isPresented: $showTimeline) { EventsTimelineSheet() }
        .sheet(isPresented: $showAssistant) { AssistantSheet() }
        .sheet(isPresented: $showNotifCenter) { NotificationsCenterSheet() }
        .sheet(isPresented: $showChargeTarget) { ChargeTargetSheet(cfg: cfg) }
        .sheet(isPresented: $showFuelCalib) { FuelCalibSheet(currentL: store.fuelL, store: store) }
    }

    // MARK: header — endereço + LiveChip

    private var headerRow: some View {
        HStack(spacing: 8) {
            if !store.address.isEmpty {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 13)).foregroundStyle(DS.muted)
                Text(store.address)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(DS.text2)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Button { showAssistant = true } label: {
                Image(systemName: "sparkles").font(.system(size: 14)).foregroundStyle(DS.teal)
            }
            Button { showTimeline = true } label: {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 14)).foregroundStyle(DS.text2)
            }
            Button { showNotifCenter = true } label: {
                Image(systemName: "bell.fill").font(.system(size: 14)).foregroundStyle(DS.text2)
            }
            LiveChipV2(preview: pv)
        }
        .padding(.top, 4)
    }

    private func netBanner(_ icon: String, _ tint: Color, _ title: String, _ sub: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.text)
                Text(sub).font(.system(size: 10)).foregroundStyle(DS.muted)
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint.opacity(0.4), lineWidth: 1))
    }

    // MARK: máquina de estados de comando (2b)

    enum CmdTileState { case idle, sending, confirmed, failed }

    private func cmdState(_ prefix: String) -> CmdTileState {
        if prefix == "lock" {
            switch pv {
            case "enviando":   return .sending
            case "confirmado": return .confirmed
            case "falhou":     return .failed
            default: break
            }
        }
        guard let cp = store.commandProgress, cp.action.hasPrefix(prefix) else { return .idle }
        switch cp.phase {
        case "sent", "running": return .sending
        case "done":            return cp.ok == true ? .confirmed : .failed
        case "timeout":         return .failed
        default:                return .idle
        }
    }

    /// Rótulo do novo estado no tile confirmado.
    private func confirmedLabel(_ prefix: String) -> String {
        if pv == "confirmado" && prefix == "lock" { return "Travado" }
        switch store.commandProgress?.action {
        case "lock_close":    return "Travado"
        case "lock_open":     return "Destravado"
        case "windows_open":  return "Abertos"
        case "windows_close": return "Fechados"
        case "trunk_open":    return "Aberto"
        case "engine_on":     return "Ligado"
        case "engine_off":    return "Desligado"
        default:              return "OK"
        }
    }

    /// Verbo da ação pro toast de falha ("Carro não respondeu · Travar").
    private static func verb(_ action: String) -> String {
        switch action {
        case "lock_close":    return "Travar"
        case "lock_open":     return "Destravar"
        case "windows_open":  return "Abrir vidros"
        case "windows_close": return "Fechar vidros"
        case "trunk_open":    return "Porta-malas"
        case "engine_on":     return "Ligar motor"
        case "engine_off":    return "Desligar motor"
        default:              return action
        }
    }

    /// Estado confirmado por extenso pro toast de sucesso.
    private static func confirmedText(_ action: String) -> String {
        switch action {
        case "lock_close":    return "Travado"
        case "lock_open":     return "Destravado"
        case "windows_open":  return "Vidros abertos"
        case "windows_close": return "Vidros fechados"
        case "trunk_open":    return "Porta-malas aberto"
        case "engine_on":     return "Motor ligado"
        case "engine_off":    return "Motor desligado"
        default:              return "Feito"
        }
    }

    private func onCommandProgress() {
        guard let cp = store.commandProgress else { return }
        switch cp.phase {
        case "sent":
            cmdSentAt = cp.ts
            setToast(nil)
        case "done", "timeout":
            if cp.ok == true {
                let lat = cmdSentAt.map {
                    String(format: "%.1f s", cp.ts.timeIntervalSince($0)).replacingOccurrences(of: ".", with: ",")
                }
                setToast(CmdToast(fail: false, text: "\(Self.confirmedText(cp.action)) · o carro confirmou",
                                  retryAction: nil, latency: lat), dismissAfter: 2.5)
            } else {
                setToast(CmdToast(fail: true, text: "Carro não respondeu · \(Self.verb(cp.action))",
                                  retryAction: cp.action, latency: nil), dismissAfter: 8)
            }
        default: break
        }
    }

    private func setToast(_ t: CmdToast?, dismissAfter: TimeInterval = 0) {
        toastDismiss?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { toast = t }
        if t != nil, dismissAfter > 0 {
            let work = DispatchWorkItem { withAnimation(.easeIn(duration: 0.25)) { toast = nil } }
            toastDismiss = work
            DispatchQueue.main.asyncAfter(deadline: .now() + dismissAfter, execute: work)
        }
    }

    private var displayedToast: CmdToast? {
        if pv == "falhou" {
            return CmdToast(fail: true, text: "Carro não respondeu · Travar", retryAction: "lock_close", latency: nil)
        }
        if pv == "confirmado" {
            return CmdToast(fail: false, text: "Travado · o carro confirmou", retryAction: nil, latency: "2,1 s")
        }
        return toast
    }

    private func toastView(_ t: CmdToast) -> some View {
        HStack(spacing: 9) {
            Image(systemName: t.fail ? "xmark" : "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(t.fail ? DS.red : DS.green)
            Text(t.text)
                .font(.system(size: 12.5, weight: .medium)).foregroundStyle(DS.text)
                .lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 8)
            if let a = t.retryAction {
                Button {
                    setToast(nil)
                    store.fireCommand(a)
                } label: {
                    Text("Tentar")
                        .font(.system(size: 12.5, weight: .bold)).foregroundStyle(DS.green)
                }
                .buttonStyle(.plain)
            } else if let lat = t.latency {
                Text(lat).font(.system(size: 11)).foregroundStyle(DS.muted)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(t.fail ? DS.red.opacity(0.4) : DS.green.opacity(0.35), lineWidth: 1))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: card de anomalia (3b) — promovido acima do hero

    private var anomalyMinutes: Int {
        if pv == "anomalia" { return 12 }
        guard let s = anomalySince else { return 0 }
        return Int(Date().timeIntervalSince(s) / 60)
    }

    private var anomalyCard: some View {
        HStack(spacing: 12) {
            Image("car_h6")
                .resizable().scaledToFit()
                .frame(width: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(unlockedAnomaly
                     ? (anomalyMinutes > 0 ? "DESTRAVADO · HÁ \(anomalyMinutes) MIN" : "DESTRAVADO")
                     : "ABERTO")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(DS.red).tracking(1)
                Text(openingsNow.isEmpty ? "Carro destravado" : anomalyDesc)
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.text)
                    .lineLimit(2).minimumScaleFactor(0.8)
            }
            Spacer(minLength: 8)
            if unlockedAnomaly {
                Button {
                    store.fireCommand("lock_close")
                } label: {
                    Text("Travar")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 15).padding(.vertical, 8)
                        .background(DS.red)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 12)
        .background(
            LinearGradient(colors: [DS.red.opacity(0.14), DS.panel],
                           startPoint: .topLeading, endPoint: .init(x: 0.62, y: 0.62))
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(DS.red.opacity(0.35), lineWidth: 1))
    }

    private var anomalyDesc: String {
        let o = openingsNow
        if o.count == 1 { return "\(o[0]) aberta" }
        if o.count <= 3 { return o.joined(separator: " e ") + " abertos" }
        return "\(o.count) aberturas no carro"
    }

    // MARK: card viagem em curso (3d)

    private var tripLiveCard: some View {
        let mock = pv == "dirigindo" && !store.tripActive
        let speed = mock ? 72.0 : store.speedKmh
        let dist = mock ? 8.2 : store.tripDistKm
        let mins = mock ? 18 : store.tripTimeSec / 60
        let cons: Double = mock ? 13.9 : (dist > 0.3 ? store.tripNetKwh / dist * 100 : 0)
        let arr = store.arrivalRaw
        let arrName = arr?["name"] as? String ?? ""
        let arrClock = arr?["etaClock"] as? String ?? ""
        let arrDist = (arr?["distKm"] as? Double) ?? ((arr?["distKm"] as? Int).map(Double.init) ?? 0)
        return Button { TabRouter.shared.go(.drive) } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    BreatheDot(color: DS.green)
                    Text("VIAGEM EM CURSO · \(mins) MIN")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(DS.green).tracking(1)
                    Spacer()
                    if !arrName.isEmpty {
                        Text("→ \(arrName)\(arrClock.isEmpty ? "" : " · chega \(arrClock)")")
                            .font(.system(size: 10.5)).foregroundStyle(DS.text2)
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    tripBig(Fmt.int(speed), "km/h")
                    Spacer()
                    tripBig(Fmt.dec1(dist), "km")
                    Spacer()
                    tripBig(cons > 0 ? Fmt.dec1(cons) : "—", "kWh/100")
                }
                if arrDist > 0, dist > 0 {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(DS.panel2)
                            Capsule().fill(DS.green)
                                .frame(width: max(6, g.size.width * min(1, dist / (dist + arrDist))))
                        }
                    }
                    .frame(height: 4)
                }
                Text("Acompanhar no Drive →")
                    .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(DS.green)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(
                LinearGradient(colors: [DS.green.opacity(0.14), DS.panel],
                               startPoint: .topLeading, endPoint: .init(x: 0.62, y: 0.62))
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(DS.green.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func tripBig(_ value: String, _ unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit().foregroundStyle(DS.text)
            Text(unit).font(.system(size: 10.5)).foregroundStyle(DS.muted)
        }
    }

    // MARK: linha dormindo (3c)

    private var sleepInfoRow: some View {
        let ts = pv == "dormindo"
            ? "17:58"
            : Date().addingTimeInterval(-max(0, store.dataAgeSec))
                .formatted(date: .omitted, time: .shortened)
        return Text("Última leitura \(ts) · comandos acordam o carro")
            .font(.system(size: 11.5)).foregroundStyle(DS.text2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 13).padding(.vertical, 10)
            .background(DS.panel)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(DS.border, lineWidth: 1))
    }

    // MARK: faixa de pneus (anomalia amarela, 3b)

    private var tyreBand: some View {
        let names = ["DIANT. ESQ.", "DIANT. DIR.", "TRAS. ESQ.", "TRAS. DIR."]
        let low = tyreLowIdx
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("PNEUS\(low != nil ? " · \(names[low!]) BAIXO" : "")")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(DS.yellow).tracking(1)
                Spacer()
                Text(freshness).font(.system(size: 9)).foregroundStyle(DS.muted)
            }
            HStack {
                ForEach(0..<4, id: \.self) { i in
                    VStack(spacing: 3) {
                        Text(names[i])
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(i == low ? DS.yellow : DS.muted).tracking(0.5)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Text(Fmt.int(tyres[i]))
                            .font(.system(size: 17, weight: i == low ? .bold : .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(i == low ? DS.yellow : DS.text)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
        .background(DS.yellow.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(DS.yellow.opacity(0.35), lineWidth: 1))
    }

    // MARK: hero de energia

    private var heroEnergia: some View {
        HStack(alignment: .lastTextBaseline, spacing: 0) {
            Text(Fmt.int(store.socPct))
                .font(.system(size: hasAnomaly ? 74 : 88, weight: .ultraLight, design: .default))
                .tracking(-4)
                .monospacedDigit()
                .foregroundStyle(DS.text)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text("%")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(DS.muted)
                .padding(.leading, 2)
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(Fmt.int(store.rangeEvKm)) km elétricos")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DS.green)
                Text("\(Fmt.int(store.rangeEvKm + store.rangeIceKm)) km total")
                    .font(.system(size: 12))
                    .foregroundStyle(DS.muted)
            }
        }
        .padding(.top, -6)
    }

    // MARK: barras SOC + combustível

    // Alvo por software (ex.: 97%) tem prioridade — o carro fica em 100 e o bridge corta.
    private var effectiveLimit: Double {
        let custom = store.num("charge_custom_target")
        return custom > 0 ? custom : store.num("charge_limit_pct")
    }

    private var barsBlock: some View {
        let limit = effectiveLimit
        let fuelFrac = min(1, max(0, store.fuelL / tankL))
        return VStack(alignment: .leading, spacing: 8) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.panel2)
                    Capsule().fill(DS.greenGrad)
                        .frame(width: max(6, g.size.width * min(1, store.socPct / 100)))
                    if store.isCharging, limit > 0, limit < 100 {
                        RoundedRectangle(cornerRadius: 1).fill(DS.yellow)
                            .frame(width: 2, height: 16)
                            .offset(x: g.size.width * (limit / 100) - 1)
                    }
                }
            }
            .frame(height: 10)
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Capsule().fill(DS.panel2)
                        .overlay(alignment: .leading) {
                            Capsule().fill(DS.orange).frame(width: max(3, 72 * fuelFrac))
                        }
                        .frame(width: 72, height: 5)
                    Text("COMBUSTÍVEL \(Fmt.int(fuelFrac * 100))% · \(Fmt.int(store.rangeIceKm)) km")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(DS.muted).tracking(0.5)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                .contentShape(Rectangle())
                .onLongPressGesture { showFuelCalib = true }
                Spacer(minLength: 8)
                if store.isCharging {
                    Button { showChargeTarget = true } label: {
                        Text(limit > 0 && limit < 100 ? "LIMITE \(Fmt.int(limit))%" : "LIMITE")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(DS.muted).tracking(0.5)
                            .fixedSize()
                    }
                    .buttonStyle(.plain)
                    .layoutPriority(1)
                }
            }
        }
    }

    // MARK: chips de estado (vocabulário 2d)

    private var stateChips: some View {
        HStack(spacing: 7) {
            if isDriving {
                chipV2(drivingGearLabel, .neutral)
                if !store.driveModeLabel.isEmpty || pv == "dirigindo" {
                    chipV2(pv == "dirigindo" && store.driveModeLabel.isEmpty ? "Modo EV" : store.driveModeLabel,
                           .outline(DS.green))
                }
                if store.acOn || pv == "dirigindo" {
                    chipV2(store.driverTemp > 0 ? "AC \(Fmt.dec1(store.driverTemp))°" : "AC", .tint(DS.teal))
                }
            } else {
                if !store.gearDisplay.isEmpty { chipV2(store.gearDisplay, .neutral) }
                chipV2(store.engineOn ? "Motor ligado" : "Desligado", store.engineOn ? .tint(DS.orange) : .neutral)
                if store.lockKnown || unlockedAnomaly {
                    chipV2(unlockedAnomaly ? "Destravado" : (store.isLocked ? "Travado" : "Destravado"),
                           unlockedAnomaly || !store.isLocked ? .tint(DS.red) : .tint(DS.green))
                }
                if !openingsNow.isEmpty { chipV2("\(openingsNow.count) aberta\(openingsNow.count > 1 ? "s" : "")", .tint(DS.red)) }
                if store.isCharging { chipV2("Carregando", .outline(DS.green)) }
                if store.acOn { chipV2("AC", .tint(DS.teal)) }
            }
            Spacer()
        }
    }

    private var drivingGearLabel: String {
        let g = store.gearDisplay.isEmpty ? "D" : store.gearDisplay
        if let n = store.intOrNil("gear_ecm"), n > 0 { return "\(g) · \(n)ª" }
        return g
    }

    private enum ChipStyle { case neutral, tint(Color), outline(Color) }

    @ViewBuilder
    private func chipV2(_ text: String, _ style: ChipStyle) -> some View {
        let (fg, bg, stroke): (Color, Color, Color) = {
            switch style {
            case .neutral:        return (DS.text2, DS.panel2, .clear)
            case .tint(let c):    return (c, c.opacity(0.12), c.opacity(0.3))
            case .outline(let c): return (c, .clear, c.opacity(0.5))
            }
        }()
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 11).padding(.vertical, 6)
            .foregroundStyle(fg)
            .background(bg)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(stroke, lineWidth: 1))
    }

    // MARK: card carregando

    private var chargingCardV2: some View {
        let mins = store.chargeRemainingMin
        let limit = effectiveLimit
        return HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    BreatheDot(color: DS.green)
                    Text("CARREGANDO")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(DS.green).tracking(1.1)
                }
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(Fmt.dec1(store.chargePowerKw))
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit().foregroundStyle(DS.text)
                    Text("kW").font(.system(size: 13)).foregroundStyle(DS.muted)
                }
                Text("+\(Fmt.dec1(store.chargeSessionKwh)) kWh nesta sessão")
                    .font(.system(size: 12)).foregroundStyle(DS.text2)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if mins > 0 {
                    Text(mins >= 60 ? "\(mins / 60)h\(String(format: "%02d", mins % 60))" : "\(mins) min")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .monospacedDigit().foregroundStyle(DS.text)
                }
                if limit > 0 {
                    Text("ATÉ \(Fmt.int(limit))%")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(DS.muted).tracking(1)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 13)
        .background(
            LinearGradient(colors: [DS.green.opacity(0.16), DS.panel],
                           startPoint: .topLeading, endPoint: .init(x: 0.62, y: 0.62))
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(DS.green.opacity(0.3), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contextMenu { chargeLimitMenu }
    }

    @ViewBuilder private var chargeLimitMenu: some View {
        let limit = Int(store.num("charge_limit_pct"))
        let customTarget = Int(store.num("charge_custom_target"))
        Text("Limite de carga (SOC)")
        ForEach([50, 60, 70, 80, 90, 100], id: \.self) { p in
            Button {
                if p != limit { Task { await cfg.setChargeLimit(p) } }
            } label: {
                Label("\(p)%", systemImage: customTarget == 0 && limit == p ? "checkmark" : "bolt")
            }
        }
        Divider()
        Button { showChargeTarget = true } label: {
            Label(customTarget > 0 ? "Alvo personalizado: \(customTarget)%" : "Alvo personalizado…",
                  systemImage: customTarget > 0 ? "checkmark" : "slider.horizontal.3")
        }
    }

    // MARK: mini-métricas (grid 4) com frescor

    private var miniMetrics: some View {
        HStack(spacing: 8) {
            miniCell("CABINE", tempStr(store.insideTemp), freshness)
            miniCell("EXTERNA", tempStr(store.outsideTemp), freshness)
            if isDriving {
                let kw = pv == "dirigindo" && store.motorPowerKw == 0 ? 14.2 : store.motorPowerKw
                miniCell("POTÊNCIA", Fmt.dec1(kw), "kW", tint: DS.orange)
                if let score = liveScore {
                    miniCell("SCORE", "\(score)", "ao vivo", tint: DS.green)
                } else {
                    miniCell("BATERIA 12V", store.batt12vV > 0 ? Fmt.dec1(store.batt12vV) : "—", "V")
                }
            } else {
                miniCell("ODÔMETRO", Fmt.int(store.odometerKm), "km")
                miniCell("BATERIA 12V", store.batt12vV > 0 ? Fmt.dec1(store.batt12vV) : "—",
                         isSleeping ? freshness : "V")
            }
        }
    }

    /// Score ao vivo se o APK publicar no current_trip (campo score/liveScore); mock no preview.
    private var liveScore: Int? {
        if pv == "dirigindo" && !store.tripActive { return 92 }
        for k in ["score", "liveScore", "drive_score"] {
            switch store.trip?[k] { case let i as Int: return i; case let d as Double: return Int(d); default: continue }
        }
        return nil
    }

    private func tempStr(_ v: Double) -> String { v != 0 ? Fmt.int(v) + "°" : "—" }

    private var freshness: String {
        if pv == "dormindo" { return "há 42 min" }
        let age = store.dataAgeSec
        if store.carOnline || (age >= 0 && age < 60) { return "agora" }
        if age < 0 { return "—" }
        let min = Int(age / 60)
        if min < 60 { return "há \(min) min" }
        return "há \(min / 60) h"
    }

    private func miniCell(_ label: String, _ value: String, _ sub: String, tint: Color = DS.text) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(DS.muted).tracking(0.8)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit().foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(sub)
                .font(.system(size: 8.5)).foregroundStyle(DS.muted)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(DS.panel)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(DS.border, lineWidth: 1))
    }

    // MARK: ações (grid 3×2)

    private var actionsGrid: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
        let lockAlert = hasAnomaly && unlockedAnomaly
        return LazyVGrid(columns: cols, spacing: 8) {
            actionTile("lock.fill", lockAlert ? "Travar" : (store.isLocked ? "Destravar" : "Travar"),
                       lockAlert ? DS.red : DS.green, state: cmdState("lock"),
                       confirmed: confirmedLabel("lock"),
                       alert: lockAlert, dimmed: isDriving) { tapCommand("lock") { showLock = true } }
                .popover(isPresented: $showLock, arrowEdge: .top) {
                    confirmPop(store.isLocked ? "Destravar o carro?" : "Travar o carro?") {
                        popBtn(store.isLocked ? "Destravar" : "Travar", DS.green) {
                            showLock = false
                            store.fireCommand(store.isLocked ? "lock_open" : "lock_close")
                        }
                    }
                }
            actionTile("arrow.down.square", "Vidros", DS.blue,
                       state: cmdState("windows"), confirmed: confirmedLabel("windows")) {
                tapCommand("windows") { showWindows = true }
            }
                .popover(isPresented: $showWindows, arrowEdge: .top) {
                    confirmPop("Vidros") {
                        popBtn("Abrir vidros", DS.blue) {
                            showWindows = false; store.fireCommand("windows_open")
                        }
                        popBtn("Fechar vidros", DS.blue) {
                            showWindows = false; store.fireCommand("windows_close")
                        }
                    }
                }
            actionTile("snowflake", store.acOn && isDriving ? "Clima ligado" : "Clima", DS.teal,
                       state: .idle, active: store.acOn && isDriving) { showPreclimat = true }
            actionTile("car.side.rear.open.fill", "Porta-malas", DS.text2,
                       state: cmdState("trunk"), confirmed: confirmedLabel("trunk"),
                       dimmed: isDriving) { tapCommand("trunk") { showTrunk = true } }
                .popover(isPresented: $showTrunk, arrowEdge: .top) {
                    confirmPop("Abrir o porta-malas?") {
                        popBtn("Abrir", DS.text2) {
                            showTrunk = false; store.fireCommand("trunk_open")
                        }
                    }
                }
            actionTile("engine.combustion.fill", "Motor", DS.orange,
                       state: cmdState("engine"), confirmed: confirmedLabel("engine"),
                       dimmed: isDriving) { tapCommand("engine") { showEngine = true } }
                .popover(isPresented: $showEngine, arrowEdge: .top) {
                    confirmPop(store.engineOn ? "Desligar o motor?" : "Ligar o motor remotamente?") {
                        popBtn(store.engineOn ? "Desligar" : "Ligar", DS.orange) {
                            showEngine = false
                            store.fireCommand(store.engineOn ? "engine_off" : "engine_on")
                        }
                    }
                }
            actionTile("light.beacon.max.fill", "Encontrar", DS.text2,
                       state: .idle, dimmed: isDriving) { showHazard = true }
                .popover(isPresented: $showHazard, arrowEdge: .top) {
                    confirmPop("Localizar o carro") {
                        popBtn("Só piscar", DS.yellow) {
                            showHazard = false
                            store.fireCommand("find_car")
                        }
                        popBtn("Piscar e buzinar", DS.orange) {
                            showHazard = false
                            store.fireCommand("find_car_honk")
                        }
                    }
                }
        }
    }

    // Balão de confirmação ancorado no tile (popover compacto no iPhone).
    private func confirmPop<Content: View>(_ title: String,
                                           @ViewBuilder buttons: () -> Content) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.text)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            buttons()
        }
        .padding(14)
        .frame(width: 210)
        .presentationCompactAdaptation(.popover)
        .preferredColorScheme(.dark)
    }

    private func popBtn(_ label: String, _ tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity).padding(.vertical, 8)
                .background(tint, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // Atalhos de localização/planejamento (paridade com o locationCard da v1).
    private var quickRow: some View {
        HStack(spacing: 8) {
            quickTile("location.north.fill", "Destino", DS.teal) { showArrival = true }
            quickTile("parkingsign", "Estacionei", DS.green) { showParking = true }
            quickTile("map.fill", "Alcance", DS.orange) { showRange = true }
            quickTile("square.and.arrow.up", "Compartilhar", DS.blue) { showShare = true }
            quickTile("dollarsign.arrow.circlepath", "Custo", DS.green) { showDestCost = true }
        }
    }

    private func quickTile(_ icon: String, _ label: String, _ tint: Color,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 15)).foregroundStyle(tint)
                Text(label)
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(DS.text2)
                    .lineLimit(1).minimumScaleFactor(0.65)
            }
            .frame(maxWidth: .infinity).frame(height: 52)
            .background(DS.panel)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(DS.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// Tocar num tile falhado = retry direto; senão abre a confirmação normal.
    private func tapCommand(_ prefix: String, fallback: () -> Void) {
        if cmdState(prefix) == .failed, let a = store.commandProgress?.action, a.hasPrefix(prefix) {
            setToast(nil)
            store.fireCommand(a)
        } else {
            fallback()
        }
    }

    private func actionTile(_ icon: String, _ label: String, _ tint: Color,
                            state: CmdTileState, confirmed: String = "OK",
                            alert: Bool = false, active: Bool = false,
                            dimmed: Bool = false, action: @escaping () -> Void) -> some View {
        let (shownIcon, shownLabel, fg): (String, String, Color) = {
            switch state {
            case .sending:   return ("clock", "Enviando…", DS.yellow)
            case .confirmed: return ("checkmark", confirmed, DS.green)
            case .failed:    return ("xmark", "Falhou", DS.red)
            case .idle:      return (icon, label, tint)
            }
        }()
        let bg: Color = {
            switch state {
            case .sending:   return DS.yellow.opacity(0.10)
            case .confirmed: return DS.green.opacity(0.10)
            case .failed:    return DS.red.opacity(0.10)
            case .idle:      return alert ? DS.red.opacity(0.10) : active ? DS.teal.opacity(0.10) : DS.panel
            }
        }()
        let stroke: Color = {
            switch state {
            case .sending:   return DS.yellow.opacity(0.4)
            case .confirmed: return DS.green.opacity(0.4)
            case .failed:    return DS.red.opacity(0.45)
            case .idle:      return alert ? DS.red.opacity(0.4) : active ? DS.teal.opacity(0.4) : DS.border
            }
        }()
        return Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: shownIcon)
                    .font(.system(size: 19))
                    .foregroundStyle(fg)
                    .symbolEffect(.pulse, options: .repeating, isActive: state == .sending)
                Text(shownLabel)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(state == .idle ? (alert ? DS.red : DS.text) : fg)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity).frame(height: 62)
            .background(bg)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .opacity(dimmed ? 0.45 : 1)
        .animation(.easeInOut(duration: 0.2), value: state == .sending)
    }

    // MARK: última viagem

    @ViewBuilder
    private var lastTripRow: some View {
        if let t = trips.trips.first {
            Button { TabRouter.shared.selected = 3 } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("ÚLTIMA VIAGEM · \(t.date.formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(DS.muted).tracking(0.8)
                        Text(tripName(t))
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.text)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text("\(Fmt.dec1(t.distKm)) km · \(Int(t.timeSec / 60)) min · \(Fmt.dec1(t.consumo)) kWh/100")
                        .font(.system(size: 11)).foregroundStyle(DS.text2)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(DS.muted)
                }
                .padding(.horizontal, 13).padding(.vertical, 11)
                .background(DS.panel)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DS.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    private func tripName(_ t: Trip) -> String {
        if let n = t.rawName { return n }
        let a = t.knownStart ?? "Origem", b = t.knownEnd ?? "Destino"
        return "\(a) → \(b)"
    }

    // MARK: saúde + planejar saída

    private var saudeTile: some View {
        Button { showHealth = true } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text("SAÚDE")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(DS.muted).tracking(0.8)
                HStack(spacing: 6) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 14)).foregroundStyle(DS.green)
                    if let s = health.data?.total {
                        HStack(alignment: .firstTextBaseline, spacing: 1) {
                            Text("\(s)").font(.system(size: 20, weight: .semibold, design: .rounded))
                                .monospacedDigit().foregroundStyle(DS.text)
                            Text("/100").font(.system(size: 11)).foregroundStyle(DS.muted)
                        }
                    } else {
                        Text("—").font(.system(size: 20, weight: .semibold)).foregroundStyle(DS.muted)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 13).padding(.vertical, 11)
            .background(DS.panel)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DS.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var saidaTile: some View {
        Button { showLeaveBy = true } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text("SAÍDA")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(DS.muted).tracking(0.8)
                HStack(spacing: 6) {
                    Image(systemName: "clock.badge.checkmark")
                        .font(.system(size: 14)).foregroundStyle(DS.teal)
                    Text("Planejar saída")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.text)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(DS.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 13).padding(.vertical, 11)
            .background(DS.panel)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DS.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: grupo silencioso (pneus + manutenção)

    private var silentGroup: some View {
        VStack(spacing: 0) {
            if tyreLowIdx == nil {
                silentRow("Pneus", tyresSummary) { showHealth = true }
                Rectangle().fill(DS.divider).frame(height: 1).padding(.horizontal, 13)
            }
            silentRow("Manutenção", maintSummary) { showMaint = true }
        }
        .background(DS.panel)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DS.border, lineWidth: 1))
    }

    private var tyresSummary: String {
        let t = [store.tyreFL, store.tyreFR, store.tyreRL, store.tyreRR]
        guard t.allSatisfy({ $0 > 0 }) else { return "—" }
        return t.map { Fmt.int($0) }.joined(separator: " · ") + " psi"
    }

    private var maintSummary: String {
        guard let n = maint.items.first else { return "em dia" }
        return n.label ?? "próxima revisão"
    }

    private func silentRow(_ title: String, _ detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(DS.text2)
                Text("— \(detail)").font(.system(size: 11)).foregroundStyle(DS.muted)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(DS.muted)
            }
            .padding(.horizontal, 13).padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - LiveChip (estados de conexão 2c)

struct LiveChipV2: View {
    @ObservedObject private var store = CarStore.shared
    var preview: String = ""

    var body: some View {
        if preview == "dirigindo" {
            chip(icon: nil, dot: DS.green, text: "AO VIVO", fg: DS.green,
                 bg: DS.green.opacity(0.12), stroke: DS.green.opacity(0.3), pulse: false, breathe: true)
        } else if preview == "dormindo" {
            chip(icon: "moon.fill", dot: nil, text: "DORMINDO · HÁ 42 MIN",
                 fg: DS.text2, bg: DS.panel2, stroke: DS.border, pulse: false)
        } else if !store.connected {
            chip(icon: nil, dot: DS.red, text: "BRIDGE FORA", fg: DS.red,
                 bg: DS.red.opacity(0.12), stroke: DS.red.opacity(0.35), pulse: true)
        } else if store.carOnline {
            chip(icon: nil, dot: DS.green, text: "AO VIVO", fg: DS.green,
                 bg: DS.green.opacity(0.12), stroke: DS.green.opacity(0.3), pulse: false, breathe: true)
        } else {
            let min = store.dataAgeSec >= 0 ? Int(store.dataAgeSec / 60) : 0
            chip(icon: "moon.fill", dot: nil,
                 text: min > 0 ? "DORMINDO · HÁ \(min) MIN" : "DORMINDO",
                 fg: DS.text2, bg: DS.panel2, stroke: DS.border, pulse: false)
        }
    }

    @ViewBuilder
    private func chip(icon: String?, dot: Color?, text: String, fg: Color,
                      bg: Color, stroke: Color, pulse: Bool, breathe: Bool = false) -> some View {
        HStack(spacing: 6) {
            if let dot {
                if breathe { BreatheDot(color: dot) }
                else if pulse { PulseDot(color: dot) }
                else { Circle().fill(dot).frame(width: 6, height: 6) }
            }
            if let icon { Image(systemName: icon).font(.system(size: 9)).foregroundStyle(fg) }
            Text(text)
                .font(.system(size: 9.5, weight: .bold)).tracking(0.8)
                .foregroundStyle(fg)
        }
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(bg)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(stroke, lineWidth: 1))
    }
}

// MARK: - Pontos animados (ecoBreathe / ecoPulse)

struct BreatheDot: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("reduce_anim") private var reduceAnim = false
    @State private var on = false
    var body: some View {
        Circle().fill(color).frame(width: 6, height: 6)
            .scaleEffect(on ? 1.35 : 1)
            .opacity(on ? 0.55 : 1)
            .onAppear {
                guard !reduceMotion, !reduceAnim else { return }
                withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

struct PulseDot: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("reduce_anim") private var reduceAnim = false
    @State private var on = false
    var body: some View {
        Circle().fill(color).frame(width: 6, height: 6)
            .opacity(on ? 0.35 : 1)
            .onAppear {
                guard !reduceMotion, !reduceAnim else { return }
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { on = true }
            }
    }
}
