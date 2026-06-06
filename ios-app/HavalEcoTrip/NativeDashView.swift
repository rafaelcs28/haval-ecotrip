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
    @StateObject private var trips = TripsLoader()
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
    @State private var mapCam: MapCameraPosition = .automatic
    // Feedback visual da troca de limite de carga (Haptic Touch no card):
    // pendingLimit = valor selecionado aguardando o carro confirmar (amarelo);
    // limitFeedback: 0=nenhum · 1=confirmado (verde) · 2=recusado (vermelho).
    @State private var pendingLimit: Int? = nil
    @State private var limitFeedback = 0
    @State private var limitTimeout: DispatchWorkItem? = nil

    private let tankL = 55.0   // capacidade aprox. do tanque (H6 PHEV) p/ o medidor

    private func f0(_ v: Double) -> String { String(format: "%.0f", v) }
    private func f1(_ v: Double) -> String { String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",") }
    private func brl(_ v: Double) -> String { Fmt.brl(v) }
    private static let grp: NumberFormatter = {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.groupingSeparator = "."; f.maximumFractionDigits = 0; return f
    }()
    private func miles(_ v: Double) -> String { Self.grp.string(from: NSNumber(value: v)) ?? f0(v) }

    // Aberturas separadas (chave 'on' = aberto)
    private func openList(_ map: [(String, String)]) -> [String] { map.filter { store.str($0.0) == "on" }.map { $0.1 } }
    private var doorsMap: [(String, String)] { [("door_fl","Diant. esq."),("door_fr","Diant. dir."),("door_rl","Tras. esq."),("door_rr","Tras. dir."),("door_trunk","Porta-malas")] }
    private var windowsMap: [(String, String)] { [("window_fl","Vidro diant. esq."),("window_fr","Vidro diant. dir."),("window_rl","Vidro tras. esq."),("window_rr","Vidro tras. dir."),("sunroof","Teto solar")] }

    var body: some View {
        ScrollView {
            VStack(spacing: 11) {
                header
                statusCard
                if store.isCharging { chargingCard } else { HStack(spacing: 14) { batteryCard; fuelCard } }
                climateCard
                openingsCard
                locationCard
                revisaoCard
                arrivalCard
                tripCard
            }
            .padding(16)
        }
        .background(DS.bg.ignoresSafeArea())
        .onAppear { store.start(); Task { await maint.load() }; Task { await trips.load() } }
        .sheet(isPresented: $showPreclimat) { PreclimatSheet() }
        .sheet(isPresented: $showMaint) { MaintenanceSheet(store: maint) }
        .sheet(isPresented: $showNotifCenter) { NotificationsCenterSheet() }
        .sheet(isPresented: $showArrival) { ArrivalSheet(trips: trips.trips) }
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
            Button { showNotifCenter = true } label: {
                Image(systemName: "bell.fill").font(.system(size: 15)).foregroundStyle(DS.text)
            }
            Circle().fill(store.carOnline ? DS.green : DS.red).frame(width: 9, height: 9)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
    }

    private var lastUpdateText: String {
        let ms = store.num("last_apk_ms")
        guard ms > 0 else { return "" }
        let age = Date().timeIntervalSince1970 - ms / 1000
        if age < 60 { return "há \(Int(max(0, age)))s" }
        if age < 3600 { return "há \(Int(age/60))min" }
        if age < 86400 { return "há \(Int(age/3600))h" }
        return "há \(Int(age/86400))d"
    }

    // MARK: trava + motor (ícones com confirmação ancorada) + hodômetro/12V ao lado
    private var statusCard: some View {
        let winOpen = ["window_fl","window_fr","window_rl","window_rr"].contains { store.str($0) == "on" }
        return DSCard {
            HStack {
                iconButton(icon: store.isLocked ? "lock.fill" : "lock.open.fill",
                           tint: store.isLocked ? DS.green : DS.orange,
                           caption: !store.lockKnown ? "—" : (store.isLocked ? "Trancado" : "Destranc.")) {
                    showLock = true
                }
                .popover(isPresented: $showLock) {
                    confirmPopover(title: store.isLocked ? "Destravar carro?" : "Travar carro?",
                                   confirm: store.isLocked ? "Destravar" : "Travar", danger: store.isLocked,
                                   name: store.isLocked ? "lock_open" : "lock_close", binding: $showLock)
                }
                Spacer()
                iconButton(icon: "power", tint: store.engineOn ? DS.green : DS.muted,
                           caption: store.engineOn ? "Ligado" : "Desligado") {
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
                iconButton(icon: "exclamationmark.triangle.fill", tint: DS.yellow, caption: "Pisca") {
                    showHazard = true
                }
                .popover(isPresented: $showHazard) {
                    confirmPopoverAction(title: "Piscar o pisca-alerta para localizar o carro?",
                                         confirm: "Piscar", danger: false, binding: $showHazard) {
                        _ = await store.setHazard(true)
                        try? await Task.sleep(nanoseconds: 6_000_000_000)   // pisca ~6s e apaga
                        _ = await store.setHazard(false)
                    }
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
                Button(confirm) { binding.wrappedValue = false; busy = true; Task { _ = await store.action(name); busy = false } }
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

    private func iconButton(icon: String, tint: Color, caption: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 15, weight: .medium)).foregroundStyle(tint)
                    .frame(width: 38, height: 38).background(DS.panel2).clipShape(Circle())
                    .overlay(Circle().stroke(DS.border, lineWidth: 1))
                Text(caption).font(.system(size: 9.5, weight: .medium)).foregroundStyle(DS.muted)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .buttonStyle(.plain).disabled(busy)
    }

    // MARK: energia
    private func batteryIcon(_ soc: Double) -> String {
        switch soc { case ..<13: return "battery.0percent"; case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"; case ..<88: return "battery.75percent"; default: return "battery.100percent" }
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
        // Estado visual do limite: pendente (amarelo) → confirmado (verde) / recusado (vermelho).
        let markerFrac: Double? = pendingLimit.map { Double($0)/100 } ?? (limit > 0 ? limit/100 : nil)
        let accent: Color = pendingLimit != nil ? DS.yellow
            : (limitFeedback == 1 ? DS.green : (limitFeedback == 2 ? DS.red : DS.muted))
        let markerColor: Color = pendingLimit != nil ? DS.yellow
            : (limitFeedback == 1 ? DS.green : (limitFeedback == 2 ? DS.red : Color.white.opacity(0.85)))
        let badgeLabel: String = {
            if let p = pendingLimit { return "Aplicando limite \(p)%…" }
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
                    Label("\(p)%", systemImage: (pendingLimit ?? Int(limit)) == p ? "checkmark" : "bolt")
                }
            }
        }
        // Carro confirmou: o limite reportado virou o valor pedido.
        .onChange(of: store.num("charge_limit_pct")) { newVal in
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
                if store.batt12vPct > 0 { rightMetric("12V", "\(f0(store.batt12vPct))%") }
            }
        }
    }

    // MARK: mini-mapa da localização do carro
    @ViewBuilder private var locationCard: some View {
        if store.hasGps {
            DSCard {
                VStack(alignment: .leading, spacing: 8) {
                    Map(position: $mapCam, interactionModes: []) {
                        Annotation("", coordinate: store.coordinate) { CarMarker(size: 28, heading: store.heading) }
                    }
                    .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
                    .frame(height: 130)
                    .overlay(Color.black.opacity(0.28))   // escurece o mapa
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .allowsHitTesting(false)
                    .onAppear { recenterMap() }
                    .onChange(of: store.lat) { _, _ in recenterMap() }
                    .onChange(of: store.lng) { _, _ in recenterMap() }
                    if !store.address.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "location.fill").font(.caption2).foregroundStyle(DS.green)
                            Text(store.address).font(.caption).foregroundStyle(DS.muted).lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    // Recentraliza o mini-mapa na posição atual do carro (chamado quando o GPS muda).
    private func recenterMap() {
        guard store.hasGps else { return }
        withAnimation(.easeInOut(duration: 0.5)) {
            mapCam = .region(MKCoordinateRegion(center: store.coordinate,
                                                latitudinalMeters: 700, longitudinalMeters: 700))
        }
    }

    private func tyreCell(_ pk: String, _ tk: String, _ label: String) -> some View {
        let p = store.num(pk), t = store.num(tk)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(p <= 0 ? "—" : f0(p)).font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(p > 0 && p < 28 ? DS.red : DS.text).monospacedDigit()
                Text("psi").font(.system(size: 11)).foregroundStyle(DS.muted)
                if t > 0 { Text("· \(f0(t))°").font(.system(size: 11)).foregroundStyle(DS.muted) }
            }
            Text(label.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(DS.muted)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Pneus + Portas + Vidros/Teto num card só — fechado mostra só o resumo;
    // abre sozinho se houver anomalia (pneu <28 psi ou porta/vidro/teto aberto).
    private var openingsCard: some View {
        let ps = ["tyre_pressure_fl","tyre_pressure_fr","tyre_pressure_rl","tyre_pressure_rr"].map { store.num($0) }
        let tyreLow = ps.contains { $0 > 0 && $0 < 28 }
        let tyreTxt = ps.allSatisfy { $0 <= 0 } ? "s/ dados" : ps.map { $0 <= 0 ? "—" : f0($0) }.joined(separator: "/")
        let openDoors = openList(doorsMap)
        let openWins  = openList(windowsMap)
        let anomaly = tyreLow || !openDoors.isEmpty || !openWins.isEmpty
        let tint = anomaly ? DS.yellow : DS.muted
        // Resumo com glifos de carro (porta/vidro), não emoji de casa.
        let summaryView = AnyView(
            HStack(spacing: 5) {
                Text("🛞 \(tyreTxt)").font(.caption).foregroundStyle(tint).lineLimit(1)
                Text("·").font(.caption).foregroundStyle(tint)
                CarDoorGlyph(color: openDoors.isEmpty ? tint : DS.orange)
                Text(openDoors.isEmpty ? "ok" : "\(openDoors.count)").font(.caption).foregroundStyle(openDoors.isEmpty ? tint : DS.orange)
                Text("·").font(.caption).foregroundStyle(tint)
                CarWindowGlyph(color: openWins.isEmpty ? tint : DS.orange)
                Text(openWins.isEmpty ? "ok" : "\(openWins.count)").font(.caption).foregroundStyle(openWins.isEmpty ? tint : DS.orange)
            }
        )
        return CollapsibleCard(icon: "car.side.fill", title: "Pneus & Aberturas", summary: "", alert: anomaly, summaryView: summaryView) {
            VStack(alignment: .leading, spacing: 10) {
                HStack { tyreCell("tyre_pressure_fl","tyre_temp_fl","Diant. Esq."); tyreCell("tyre_pressure_fr","tyre_temp_fr","Diant. Dir.") }
                HStack { tyreCell("tyre_pressure_rl","tyre_temp_rl","Tras. Esq.");  tyreCell("tyre_pressure_rr","tyre_temp_rr","Tras. Dir.") }
                Divider().background(DS.border)
                ForEach(doorsMap, id: \.0) { k, label in stateRow(label, store.str(k) == "on") }
                ForEach(windowsMap, id: \.0) { k, label in stateRow(label, store.str(k) == "on") }
            }
        }
    }

    private func stateRow(_ label: String, _ open: Bool) -> some View {
        HStack {
            Text(label).font(.system(size: 14)).foregroundStyle(DS.text)
            Spacer()
            Text(open ? "Aberto" : "Fechado").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(open ? DS.yellow : DS.muted)
        }
    }

    // MARK: revisão (botão → popup com tudo)
    private var revisaoCard: some View {
        let next = maint.items.first
        return DSCard {
            Button { showMaint = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "wrench.and.screwdriver.fill").font(.subheadline).foregroundStyle(DS.muted)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Revisão").font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.text)
                        Text(next.map { "\($0.label ?? "Próxima") · \(maintWhen($0))" } ?? "Ver histórico e custos")
                            .font(.caption).foregroundStyle(DS.muted)
                    }
                    Spacer()
                    if let n = next { Circle().fill(n.statusColor).frame(width: 9, height: 9) }
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(DS.muted)
                }
            }.buttonStyle(.plain)
        }
    }

    private func maintWhen(_ m: MaintItem) -> String {
        if let km = m.remaining_km { return km <= 0 ? "vencida" : "faltam \(miles(km)) km" }
        if let d = m.remaining_days { return d <= 0 ? "vencida" : "faltam \(f0(d)) dias" }
        return ""
    }

    // MARK: SOC na chegada
    private var arrivalCard: some View {
        DSCard {
            Button { showArrival = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "location.fill.viewfinder").font(.title3).foregroundStyle(DS.teal)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SOC na chegada").font(.subheadline.weight(.semibold)).foregroundStyle(DS.text)
                        Text("Prever bateria + ETA até um destino").font(.caption).foregroundStyle(DS.muted)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(DS.muted)
                }
            }
        }
    }

    // MARK: viagem em andamento (ou última)
    @ViewBuilder private var tripCard: some View {
        if store.tripActive {
            DSCard(title: "Viagem em andamento", icon: "car.fill") {
                tripMetrics(distKm: store.tripDistKm, timeSec: Double(store.tripTimeSec),
                            netKwh: store.tripNetKwh, fuelL: store.tripFuelL)
            }
        } else if let t = trips.trips.first {
            DSCard(title: "Última viagem", icon: "car.fill") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(lastTripDate(t)).font(.caption).foregroundStyle(DS.muted).frame(maxWidth: .infinity, alignment: .leading)
                    tripMetrics(distKm: t.distKm, timeSec: t.timeSec, netKwh: t.netKwh, fuelL: t.fuelL)
                }
            }
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

// Glifos vetoriais de carro pro resumo de aberturas (não há emoji de porta/vidro de carro).
struct CarDoorGlyph: View {
    var color: Color
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let body = Path(roundedRect: CGRect(x: w*0.14, y: h*0.16, width: w*0.72, height: h*0.7), cornerRadius: w*0.14)
            ctx.stroke(body, with: .color(color), lineWidth: 1.4)
            // janela da porta (parte de cima)
            let win = Path(roundedRect: CGRect(x: w*0.26, y: h*0.26, width: w*0.48, height: h*0.2), cornerRadius: w*0.05)
            ctx.fill(win, with: .color(color.opacity(0.45)))
            // maçaneta
            var handle = Path(); handle.move(to: CGPoint(x: w*0.56, y: h*0.6)); handle.addLine(to: CGPoint(x: w*0.72, y: h*0.6))
            ctx.stroke(handle, with: .color(color), lineWidth: 1.4)
        }
        .frame(width: 15, height: 15)
    }
}

struct CarWindowGlyph: View {
    var color: Color
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            // vidro lateral (trapézio arredondado)
            var p = Path()
            p.move(to: CGPoint(x: w*0.18, y: h*0.34))
            p.addLine(to: CGPoint(x: w*0.80, y: h*0.26))
            p.addLine(to: CGPoint(x: w*0.86, y: h*0.70))
            p.addLine(to: CGPoint(x: w*0.14, y: h*0.74))
            p.closeSubpath()
            ctx.fill(p, with: .color(color.opacity(0.35)))
            ctx.stroke(p, with: .color(color), lineWidth: 1.4)
        }
        .frame(width: 15, height: 15)
    }
}
