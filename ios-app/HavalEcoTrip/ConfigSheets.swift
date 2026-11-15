//
//  ConfigSheets.swift
//  Sheets de Configurações: Notificações (catálogo completo do PWA),
//  Locais conhecidos (CRUD + vínculo) e Veículo (limite/nome/chassi).
//

import SwiftUI
import UIKit
import CoreLocation
import MapKit

// MARK: - Notificações (catálogo completo)
struct NotificationsSheet: View {
    @ObservedObject var cfg: ConfigStore
    @Environment(\.dismiss) private var dismiss

    // item: chave do toggle, rótulo, (opcional) chave numérica + faixa + unidade,
    // (opcional) chave de lista de locais.
    struct Item { let key: String; let label: String; var num: String? = nil; var range: ClosedRange<Int> = 1...60; var unit: String = "min"; var places: String? = nil }
    struct Group { let title: String; let items: [Item] }

    private let groups: [Group] = [
        Group(title: "Recarga", items: [
            Item(key: "charge_start", label: "Início de recarga"),
            Item(key: "charge_end", label: "Fim de recarga"),
            Item(key: "charge_ending", label: "Recarga acabando", num: "charge_ending_min", range: 1...30),
            Item(key: "charge_live", label: "Ao vivo na tela bloqueada"),
            Item(key: "charge_stopped", label: "Parou antes do limite"),
            Item(key: "charge_slow", label: "Recarga lenta (queda de potência)"),
        ]),
        Group(title: "Carro", items: [
            Item(key: "door_open", label: "Porta aberta"), Item(key: "door_close", label: "Porta fechada"),
            Item(key: "trunk_open", label: "Porta-malas aberto"), Item(key: "trunk_close", label: "Porta-malas fechado"),
            Item(key: "engine_on", label: "Motor ligado"), Item(key: "engine_off", label: "Motor desligado"),
            Item(key: "lock_forgotten", label: "Esqueceu destravado", num: "lock_forgotten_min", range: 1...30),
            Item(key: "window_forgotten", label: "Vidro esquecido aberto", num: "window_forgotten_min", range: 1...30),
            Item(key: "trunk_forgotten", label: "Porta-malas esquecido", num: "trunk_forgotten_min", range: 1...30),
        ]),
        Group(title: "Viagem e locais", items: [
            Item(key: "trip_end", label: "Fim de viagem"),
            Item(key: "trip_summary_narrated", label: "Resumo narrado pela Lari", num: "trip_summary_min_km", range: 1...100, unit: "km"),
            Item(key: "geofence_arrival", label: "Chegada a um local", places: "geofence_arrival_places"),
            Item(key: "geofence_departure", label: "Saída de um local", places: "geofence_departure_places"),
        ]),
        Group(title: "Bateria e SOC", items: [
            Item(key: "batt12_low", label: "Bateria 12V baixa"),
            Item(key: "batt12_trend", label: "Bateria 12V em queda (tendência)"),
            Item(key: "soc_low_idle", label: "SOC baixo parado", num: "soc_low_idle_pct", range: 5...50, unit: "%"),
            Item(key: "soc_arrival", label: "SOC baixo na chegada", num: "soc_arrival_pct", range: 10...60, unit: "%", places: "soc_arrival_places"),
            Item(key: "soc_full_long", label: "SOC cheio por muito tempo"),
        ]),
        Group(title: "Manutenção e anomalias", items: [
            Item(key: "maintenance_soon", label: "Revisão próxima"),
            Item(key: "maintenance_overdue", label: "Revisão vencida"),
            Item(key: "anomaly_detected", label: "Anomalia detectada"),
        ]),
        Group(title: "Pneus", items: [
            Item(key: "tyre_low", label: "Pressão baixa"), Item(key: "tyre_high", label: "Pressão alta"),
            Item(key: "tyre_drop", label: "Queda de pressão na viagem", num: "tyre_drop_psi", range: 1...10, unit: "psi"),
        ]),
        Group(title: "Clima", items: [
            Item(key: "ac_on_parked", label: "AC ligado parado", num: "ac_on_parked_min", range: 1...30),
        ]),
        Group(title: "Outros", items: [
            Item(key: "refuel_detected", label: "Abastecimento detectado"),
            Item(key: "daily_summary", label: "Resumo diário (20h)"),
            Item(key: "weekly_summary", label: "Resumo semanal (dom 20h)"),
            Item(key: "app_update", label: "Atualização do app"),
        ]),
    ]
    private let laItems: [(String, String)] = [("la_charge","Recarga"),("la_preclimat","Pré-climatização"),("la_trip","Viagem"),("la_motor","Motor ligado"),("la_security","Segurança"),("la_infra","Monitoramento (infra)"),("la_parking","Voltar ao carro"),("preclimat_steps","Passos da pré-climatização")]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    DSCard(title: "Live Activities", icon: "bolt.badge.clock") {
                        VStack(spacing: 4) {
                            ForEach(laItems, id: \.0) { k, label in
                                Toggle(label, isOn: Binding(get: { cfg.laPrefs[k] ?? true }, set: { v in Task { await cfg.setLa(k, v) } })).tint(DS.green).font(.system(size: 14))
                            }
                            Divider().overlay(DS.border)
                            Button { Task { await cfg.relaunchLA() } } label: {
                                Label("Reativar Live Activities", systemImage: "arrow.clockwise").font(.system(size: 14, weight: .semibold))
                                    .frame(maxWidth: .infinity).frame(height: 42).foregroundStyle(.black).background(DS.green).clipShape(RoundedRectangle(cornerRadius: 11))
                            }
                            Text("Use se uma viagem/recarga em andamento não mostrou o card.").font(.caption2).foregroundStyle(DS.muted)
                        }
                    }
                    ForEach(groups, id: \.title) { g in
                        DSCard(title: g.title, icon: "bell.fill") {
                            VStack(spacing: 6) {
                                ForEach(g.items, id: \.key) { item in itemRow(item) }
                            }
                        }
                    }
                    securityCard()
                    if cfg.laPrefs["la_parking"] ?? true { parkingCard() }
                }.padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Notificações").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Concluído") { dismiss() } } }
        }
        .task { await cfg.loadAll(); await cfg.loadPlaces() }
    }

    @ViewBuilder private func itemRow(_ item: Item) -> some View {
        let on = cfg.pushPrefs[item.key] ?? false
        VStack(spacing: 6) {
            Toggle(item.label, isOn: Binding(get: { on }, set: { v in Task { await cfg.setPush(item.key, v) } })).tint(DS.green).font(.system(size: 14))
            if on, let numKey = item.num {
                let v = cfg.pushNums[numKey] ?? item.range.lowerBound
                HStack {
                    Text("Limite").font(.caption).foregroundStyle(DS.muted)
                    Spacer()
                    Stepper("\(v) \(item.unit)", value: Binding(get: { v }, set: { nv in Task { await cfg.setPushNum(numKey, nv) } }), in: item.range)
                        .labelsHidden()
                    Text("\(v) \(item.unit)").font(.system(size: 13, weight: .bold)).foregroundStyle(DS.text).frame(minWidth: 56, alignment: .trailing)
                }
            }
            if on, let placesKey = item.places { placesPicker(placesKey) }
        }
        .padding(.vertical, 2)
    }

    private static let dayLabels = ["Dom","Seg","Ter","Qua","Qui","Sex","Sáb"]

    @ViewBuilder private func securityCard() -> some View {
        let on = cfg.pushPrefs["security_departure"] ?? false
        DSCard(title: "Segurança", icon: "shield.lefthalf.filled") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Saída suspeita (janela de horário)", isOn: Binding(get: { on }, set: { v in Task { await cfg.setPush("security_departure", v) } }))
                    .tint(DS.green).font(.system(size: 14))
                Text("Alerta se o carro deixar um local monitorado dentro da janela — independe do motor.")
                    .font(.caption2).foregroundStyle(DS.muted)
                if on {
                    placesPicker("security_departure_places")
                    Text("DIAS").font(.system(size: 9, weight: .semibold)).foregroundStyle(DS.muted)
                    FlowChipsSelect(options: (0...6).map { ("\($0)", Self.dayLabels[$0]) }, selected: Set(cfg.securityDays.map(String.init))) { id in
                        guard let d = Int(id) else { return }
                        var s = Set(cfg.securityDays)
                        if s.contains(d) { s.remove(d) } else { s.insert(d) }
                        Task { await cfg.setSecurityDays(Array(s)) }
                    }
                    Text("Vazio = todos os dias.").font(.caption2).foregroundStyle(DS.muted)
                    HStack {
                        DatePicker("De", selection: timeBinding("security_from", "00:00"), displayedComponents: .hourAndMinute)
                            .labelsHidden()
                        Text("até").font(.caption).foregroundStyle(DS.muted)
                        DatePicker("Até", selection: timeBinding("security_to", "05:00"), displayedComponents: .hourAndMinute)
                            .labelsHidden()
                        Spacer()
                    }
                }
            }.padding(.vertical, 2)
        }
    }

    @ViewBuilder private func parkingCard() -> some View {
        DSCard(title: "Voltar ao carro", icon: "parkingsign") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Mostra distância e rumo até o carro estacionado quando você se afasta mais de 100 m dele.")
                    .font(.caption2).foregroundStyle(DS.muted)
                placesPicker("la_parking_suppress_places")
                Text("Locais marcados NÃO abrem o card (ex.: casa, trabalho). Deixe vazio pra sempre abrir.")
                    .font(.caption2).foregroundStyle(DS.muted)
            }.padding(.vertical, 2)
        }
    }

    private func timeBinding(_ key: String, _ def: String) -> Binding<Date> {
        Binding(
            get: { Self.dateFromHHMM(cfg.pushStrs[key] ?? def) },
            set: { d in Task { await cfg.setPushStr(key, Self.hhmm(d)) } }
        )
    }
    private static func dateFromHHMM(_ s: String) -> Date {
        let p = s.split(separator: ":").compactMap { Int($0) }
        return Calendar.current.date(bySettingHour: p.first ?? 0, minute: p.count > 1 ? p[1] : 0, second: 0, of: Date()) ?? Date()
    }
    private static func hhmm(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    private func placesPicker(_ key: String) -> some View {
        let selected = Set(cfg.placeLists[key] ?? [])
        return VStack(alignment: .leading, spacing: 6) {
            Text("LOCAIS").font(.system(size: 9, weight: .semibold)).foregroundStyle(DS.muted)
            if cfg.places.isEmpty {
                Text("Cadastre locais em Configurações → Locais conhecidos.").font(.caption2).foregroundStyle(DS.muted)
            } else {
                FlowChipsSelect(options: cfg.places.map { ($0.id, $0.name) }, selected: selected) { id in
                    var s = selected
                    if s.contains(id) { s.remove(id) } else { s.insert(id) }
                    Task { await cfg.setPlaceList(key, Array(s)) }
                }
            }
        }.padding(.leading, 4)
    }
}

// Chips multi-seleção (locais)
struct FlowChipsSelect: View {
    let options: [(String, String)]
    let selected: Set<String>
    let toggle: (String) -> Void
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 6)], spacing: 6) {
            ForEach(options, id: \.0) { id, name in
                let on = selected.contains(id)
                Button { toggle(id) } label: {
                    Text(name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        .frame(maxWidth: .infinity).frame(height: 34)
                        .foregroundStyle(on ? .black : DS.text).background(on ? DS.green : DS.panel2)
                        .clipShape(Capsule())
                }
            }
        }
    }
}

// MARK: - Locais conhecidos
private struct PendingChargeLocationLink: Identifiable {
    let id = UUID()
    let location: ChargeLocationCandidate
    let knownPlaceId: String?
    let knownPlaceName: String?
}

struct KnownPlacesSheet: View {
    @ObservedObject var cfg: ConfigStore
    @ObservedObject private var car = CarStore.shared
    @StateObject private var completer = AddressCompleter()
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var newRadius = 200.0
    @State private var search = ""
    @State private var coord: (Double, Double)? = nil
    @State private var addrLabel = ""
    @State private var showMap = false
    @State private var chargeLocations: [ChargeLocationCandidate] = []
    @State private var chargeLocationsFailed = false
    @State private var chargeLocationMessage = ""
    @State private var pendingLink: PendingChargeLocationLink?
    @State private var editingPlaceId: String?

    private var effective: (Double, Double)? { coord ?? (car.hasGps ? (car.lat, car.lng) : nil) }
    private var unlinkedChargeLocations: [ChargeLocationCandidate] {
        ChargeLocationCandidate.unlinked(chargeLocations)
    }
    private var locText: String {
        if coord != nil { return addrLabel.isEmpty ? "Ponto escolhido" : addrLabel }
        return car.hasGps ? "Posição atual do carro" : "Sem local — busque ou escolha no mapa"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    DSCard(title: "Adicionar local", icon: "plus.circle") {
                        VStack(spacing: 10) {
                            field("Nome (Casa, Trabalho…)", $newName)
                            field("Buscar endereço ou estabelecimento", $search, icon: "magnifyingglass")
                                .onChange(of: search) { _, q in
                                    coord = nil
                                    if q.count >= 3 { completer.update(q, near: car.coordinate) } else { completer.clear() }
                                }
                            if !completer.results.isEmpty {
                                VStack(spacing: 0) {
                                    ForEach(completer.results.prefix(5), id: \.self) { s in
                                        Button { pick(s) } label: {
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(s.title).font(.subheadline).foregroundStyle(DS.text)
                                                if !s.subtitle.isEmpty { Text(s.subtitle).font(.caption2).foregroundStyle(DS.muted).lineLimit(1) }
                                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 7).padding(.horizontal, 8)
                                        }
                                        Divider().background(DS.border)
                                    }
                                }.background(DS.panel2).clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            HStack(spacing: 6) {
                                Image(systemName: "mappin.circle.fill").font(.caption).foregroundStyle(coord != nil ? DS.green : DS.muted)
                                Text(locText).font(.caption).foregroundStyle(DS.muted).lineLimit(1)
                                Spacer()
                                Button { showMap = true } label: { Label("No mapa", systemImage: "map.fill").font(.caption.weight(.semibold)).foregroundStyle(DS.teal) }
                            }
                            HStack { Text("Raio").font(.caption).foregroundStyle(DS.muted); Spacer(); Text("\(Int(newRadius)) m").font(.system(size: 13, weight: .bold)).foregroundStyle(DS.text) }
                            Slider(value: $newRadius, in: 50...2000, step: 50).tint(DS.green)
                            Button {
                                guard !newName.isEmpty, let c = effective else { return }
                                Task { await cfg.addPlace(name: newName, lat: c.0, lng: c.1, radius: newRadius); reset() }
                            } label: {
                                Text("Adicionar").font(.system(size: 15, weight: .bold)).frame(maxWidth: .infinity).frame(height: 46)
                                    .foregroundStyle(.black).background((newName.isEmpty || effective == nil) ? DS.muted : DS.green).clipShape(RoundedRectangle(cornerRadius: 12))
                            }.disabled(newName.isEmpty || effective == nil)
                        }
                    }
                    if !unlinkedChargeLocations.isEmpty {
                        DSCard(title: "Locais de recarga para vincular", icon: "bolt.badge.clock") {
                            VStack(spacing: 12) {
                                ForEach(unlinkedChargeLocations) { location in
                                    HStack(spacing: 10) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(location.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.text)
                                            Text(location.canCreateKnownPlace ? "Coordenadas disponíveis" : "Sem coordenadas · escolha um local existente")
                                                .font(.caption2).foregroundStyle(DS.muted)
                                        }
                                        Spacer()
                                        Menu {
                                            ForEach(cfg.places) { place in
                                                Button(place.name) {
                                                    pendingLink = PendingChargeLocationLink(
                                                        location: location,
                                                        knownPlaceId: place.id,
                                                        knownPlaceName: place.name
                                                    )
                                                }
                                            }
                                            if location.canCreateKnownPlace {
                                                Divider()
                                                Button("Criar local conhecido") {
                                                    pendingLink = PendingChargeLocationLink(
                                                        location: location,
                                                        knownPlaceId: nil,
                                                        knownPlaceName: nil
                                                    )
                                                }
                                            }
                                        } label: {
                                            Label("Vincular", systemImage: "link")
                                                .font(.caption.weight(.semibold)).foregroundStyle(DS.teal)
                                        }
                                    }
                                    if location.id != unlinkedChargeLocations.last?.id { Divider().overlay(DS.border) }
                                }
                            }
                        }
                    }
                    if chargeLocationsFailed {
                        Text("Não foi possível carregar os locais usados nas recargas.")
                            .font(.caption).foregroundStyle(DS.red).frame(maxWidth: .infinity, alignment: .leading)
                    } else if !chargeLocationMessage.isEmpty {
                        Text(chargeLocationMessage)
                            .font(.caption).foregroundStyle(DS.teal).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(cfg.places) { p in
                        PlaceRow(place: p, cfg: cfg, startEditing: editingPlaceId == p.id)
                    }
                }.padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Locais conhecidos").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Concluído") { dismiss() } } }
            .sheet(isPresented: $showMap) {
                MapPickerSheet(start: effective.map { .init(latitude: $0.0, longitude: $0.1) } ?? car.coordinate,
                               initial: coord.map { .init(latitude: $0.0, longitude: $0.1) }) { c, nm in
                    coord = (c.latitude, c.longitude); addrLabel = nm; completer.clear(); search = ""
                    if newName.isEmpty { newName = nm }
                }
            }
            .alert(item: $pendingLink) { pending in
                Alert(
                    title: Text(pending.knownPlaceId == nil ? "Criar local conhecido?" : "Vincular locais?"),
                    message: Text(confirmationMessage(pending)),
                    primaryButton: .default(Text("Confirmar")) {
                        Task { await confirm(pending) }
                    },
                    secondaryButton: .cancel()
                )
            }
        }
        .task {
            await cfg.loadPlaces()
            await reloadChargeLocations()
        }
    }

    @ViewBuilder private func field(_ ph: String, _ text: Binding<String>, icon: String? = nil) -> some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon).font(.caption).foregroundStyle(DS.muted) }
            TextField(ph, text: text).foregroundStyle(DS.text).autocorrectionDisabled()
        }
        .padding(9).background(DS.panel2).clipShape(RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(DS.border, lineWidth: 1))
    }

    private func pick(_ s: MKLocalSearchCompletion) {
        let label = s.title
        completer.clear(); search = s.title
        Task {
            if let r = await completer.resolve(s) {
                coord = (r.0.latitude, r.0.longitude); addrLabel = label
                if newName.isEmpty { newName = label }
            }
        }
    }

    private func reset() { newName = ""; search = ""; coord = nil; addrLabel = ""; completer.clear() }

    private func confirmationMessage(_ pending: PendingChargeLocationLink) -> String {
        if let name = pending.knownPlaceName {
            return "Vincular “\(pending.location.name)” ao local conhecido “\(name)”?"
        }
        return "Criar “\(pending.location.name)” como local conhecido com raio de 200 m?"
    }

    private func reloadChargeLocations() async {
        guard let loaded = await cfg.loadChargeLocations() else {
            chargeLocationsFailed = true
            return
        }
        chargeLocations = loaded
        chargeLocationsFailed = false
    }

    private func confirm(_ pending: PendingChargeLocationLink) async {
        chargeLocationMessage = ""
        if let knownPlaceId = pending.knownPlaceId {
            let ok = await cfg.linkChargeLocation(pending.location.id, to: knownPlaceId)
            guard ok else {
                chargeLocationMessage = "Não foi possível salvar o vínculo."
                return
            }
            editingPlaceId = knownPlaceId
        } else {
            guard let newId = await cfg.createKnownPlace(from: pending.location, radius: 200) else {
                chargeLocationMessage = "Não foi possível criar o local conhecido."
                return
            }
            editingPlaceId = newId
        }
        chargeLocationMessage = "Vínculo salvo. Configure o provedor e o carregador abaixo."
        await reloadChargeLocations()
    }
}

private struct PlaceRow: View {
    let place: KnownPlace
    let cfg: ConfigStore
    let startEditing: Bool
    @State private var name = ""
    @State private var radius = 200.0
    @State private var loaded = false
    @State private var editing = false
    @State private var coord: (Double, Double)? = nil
    @State private var showMap = false
    @State private var meterEnabled = false
    @State private var providerId = ""
    @State private var chargerId = ""
    @State private var chargerName = ""
    @State private var tariff = ""
    @State private var providers: [ChargeMeterProvider] = []
    @State private var chargers: [ChargeMeterCharger] = []
    @State private var meterError = ""
    @State private var saving = false

    private var effective: (Double, Double) { coord ?? (place.lat, place.lng) }
    private var requiresTariff: Bool {
        providers.first(where: { $0.id == providerId })?.requiresTariff ?? (providerId.lowercased() == "zeeda")
    }

    var body: some View {
        DSCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "mappin.circle.fill").foregroundStyle(coord != nil ? DS.teal : DS.green)
                    if editing {
                        TextField("Nome", text: $name).foregroundStyle(DS.text)
                    } else {
                        Text(place.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.text)
                    }
                    Spacer()
                    Button { Task { await cfg.deletePlace(place.id) } } label: { Image(systemName: "trash").foregroundStyle(DS.red) }.buttonStyle(.plain)
                }
                if editing {
                    HStack { Text("Raio").font(.caption).foregroundStyle(DS.muted); Spacer(); Text("\(Int(radius)) m").font(.system(size: 13, weight: .bold)).foregroundStyle(DS.text) }
                    Slider(value: $radius, in: 50...2000, step: 50).tint(DS.green)
                    Button { showMap = true } label: {
                        Label(coord != nil ? "Local ajustado no mapa ✓" : "Editar local no mapa", systemImage: "map.fill")
                            .font(.caption.weight(.semibold)).foregroundStyle(coord != nil ? DS.teal : DS.blue)
                    }
                    Divider().overlay(DS.border)
                    Toggle("Preencher recargas pelo carregador", isOn: $meterEnabled)
                        .tint(DS.green).font(.system(size: 14))
                    if meterEnabled {
                        meterMenu(
                            title: "Provedor",
                            value: providers.first(where: { $0.id == providerId })?.name ?? providerId,
                            empty: "Nenhum provedor disponível"
                        ) {
                            ForEach(providers) { provider in
                                Button(provider.name) { selectProvider(provider) }
                            }
                        }
                        meterMenu(
                            title: "Carregador",
                            value: chargerName,
                            empty: providerId.isEmpty ? "Escolha o provedor" : "Nenhum carregador disponível"
                        ) {
                            ForEach(chargers) { charger in
                                Button(charger.name) { chargerId = charger.id; chargerName = charger.name }
                            }
                        }
                        if requiresTariff {
                            TextField("Tarifa (R$/kWh)", text: $tariff)
                                .keyboardType(.decimalPad).foregroundStyle(DS.text)
                                .padding(9).background(DS.panel2).clipShape(RoundedRectangle(cornerRadius: 9))
                            Text("Zeeda: custo calculado pela tarifa vigente.")
                                .font(.caption2).foregroundStyle(DS.muted)
                        } else if !providerId.isEmpty {
                            Text("Energia e valor vêm da sessão do provedor.")
                                .font(.caption2).foregroundStyle(DS.muted)
                        }
                    }
                    if !meterError.isEmpty {
                        Text(meterError).font(.caption2).foregroundStyle(DS.red)
                    }
                    HStack(spacing: 10) {
                        Button("Cancelar") { editing = false; loadState() }.foregroundStyle(DS.muted)
                        Spacer()
                        Button(saving ? "Salvando…" : "Salvar") { save() }
                            .disabled(saving).font(.system(size: 14, weight: .bold)).foregroundStyle(DS.green)
                    }
                } else {
                    if let meter = place.chargeMeter, meter.enabled {
                        Text("\(meter.chargerName) · \(meter.provider == "zeeda" ? "tarifa R$ \(String(format: "%.2f", meter.currentPricePerKwh ?? 0))" : "valor do provedor")")
                            .font(.caption2).foregroundStyle(DS.teal)
                    }
                    Button("Editar") { beginEditing() }.font(.caption).foregroundStyle(DS.blue)
                }
            }
        }
        .onAppear {
            if !loaded { loadState(); loaded = true }
            if startEditing { beginEditing() }
        }
        .onChange(of: startEditing) { _, shouldEdit in
            if shouldEdit { beginEditing() }
        }
        .sheet(isPresented: $showMap) {
            MapPickerSheet(start: .init(latitude: effective.0, longitude: effective.1),
                           initial: .init(latitude: effective.0, longitude: effective.1)) { c, _ in
                coord = (c.latitude, c.longitude)
            }
        }
    }

    private func loadState() {
        name = place.name
        radius = place.radiusM
        coord = nil
        meterEnabled = place.chargeMeter?.enabled ?? false
        providerId = place.chargeMeter?.provider ?? ""
        chargerId = place.chargeMeter?.chargerId ?? ""
        chargerName = place.chargeMeter?.chargerName ?? ""
        tariff = place.chargeMeter?.currentPricePerKwh.map { String(format: "%.2f", $0).replacingOccurrences(of: ".", with: ",") } ?? ""
        meterError = ""
    }

    private func loadCatalog() async {
        providers = await cfg.loadChargeMeterProviders()
        if !providerId.isEmpty { chargers = await cfg.loadChargeMeterChargers(provider: providerId) }
    }

    private func beginEditing() {
        editing = true
        loadState()
        Task { await loadCatalog() }
    }

    private func selectProvider(_ provider: ChargeMeterProvider) {
        providerId = provider.id
        chargerId = ""
        chargerName = ""
        chargers = []
        Task { chargers = await cfg.loadChargeMeterChargers(provider: provider.id) }
    }

    private func save() {
        saving = true
        meterError = ""
        Task {
            var meter = place.chargeMeter
            do {
                if meterEnabled {
                    meter = try (meter ?? ChargeMeterConfig()).updating(
                        enabled: true,
                        provider: providerId,
                        chargerId: chargerId,
                        chargerName: chargerName,
                        priceText: tariff,
                        effectiveFromMs: Int64(Date().timeIntervalSince1970 * 1000)
                    )
                } else if var existing = meter {
                    existing.enabled = false
                    meter = existing
                }
                let ok = await cfg.updatePlace(place.id, name: name, radius: radius, lat: coord?.0, lng: coord?.1, chargeMeter: meter)
                saving = false
                if ok { editing = false; coord = nil } else { meterError = "Não foi possível salvar no Bridge." }
            } catch {
                saving = false
                meterError = error.localizedDescription
            }
        }
    }

    private func meterMenu<Content: View>(title: String, value: String, empty: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title).font(.caption).foregroundStyle(DS.muted)
            Spacer()
            Menu(content: content) {
                Text(value.isEmpty ? empty : value).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.text)
            }
        }
        .padding(9).background(DS.panel2).clipShape(RoundedRectangle(cornerRadius: 9))
    }
}

// MARK: - Veículo
struct VehicleSheet: View {
    @ObservedObject var cfg: ConfigStore
    @ObservedObject private var car = CarStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var model = ""
    @State private var chassi = ""
    @State private var loaded = false
    @State private var showTarget = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    DSCard(title: "Limite de carga (SOC)", icon: "bolt.fill") {
                        let custom = Int(car.num("charge_custom_target"))
                        let limit = Int(car.num("charge_limit_pct"))
                        VStack(spacing: 10) {
                            HStack(spacing: 6) {
                                ForEach([50,60,70,80,90,100], id: \.self) { p in
                                    let on = custom == 0 && limit == p
                                    Button { Task { await cfg.setChargeLimit(p) } } label: {
                                        Text("\(p)").font(.system(size: 13, weight: .bold)).frame(maxWidth: .infinity).frame(height: 38)
                                            .foregroundStyle(on ? .black : DS.text).background(on ? DS.green : DS.panel2).clipShape(RoundedRectangle(cornerRadius: 9))
                                    }
                                }
                            }
                            Button { showTarget = true } label: {
                                HStack {
                                    Image(systemName: "slider.horizontal.3")
                                    Text(custom > 0 ? "Alvo personalizado: \(custom)%" : "Alvo personalizado…")
                                        .font(.system(size: 14, weight: .semibold))
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption2)
                                }
                                .foregroundStyle(custom > 0 ? DS.green : DS.text)
                                .padding(.horizontal, 12).frame(height: 40)
                                .frame(maxWidth: .infinity)
                                .background(DS.panel2).clipShape(RoundedRectangle(cornerRadius: 9))
                            }
                            Text("Para entre/acima dos presets (ex.: 97%). Carrega sem limite e corta no alvo — precisa do servidor online.")
                                .font(.caption2).foregroundStyle(DS.muted).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    DSCard(title: "Identificação", icon: "car.fill") {
                        VStack(spacing: 10) {
                            field("Nome / modelo", text: $model)
                            field("Chassi (VIN — lgw...)", text: $chassi)
                            Button { Task { let ok = await cfg.saveVehicle(model: model, chassi: chassi.lowercased()); cfg.toast = ok ? "✓ Salvo" : "✗ Verifique o chassi" } } label: {
                                Text("Salvar").font(.system(size: 15, weight: .bold)).frame(maxWidth: .infinity).frame(height: 46)
                                    .foregroundStyle(.black).background(DS.green).clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            Text("Alterar o chassi pode exigir reinício do servidor.").font(.caption2).foregroundStyle(DS.muted)
                        }
                    }
                }.padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Veículo").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Concluído") { dismiss() } } }
        }
        .sheet(isPresented: $showTarget) { ChargeTargetSheet(cfg: cfg) }
        .task { await cfg.loadVehicle(); if !loaded { model = cfg.modelName; chassi = cfg.chassi; loaded = true } }
    }
    private func field(_ ph: String, text: Binding<String>) -> some View {
        TextField(ph, text: text).foregroundStyle(DS.text).autocorrectionDisabled().textInputAutocapitalization(.never)
            .padding(10).background(DS.panel2).clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(DS.border, lineWidth: 1))
    }
}

// MARK: - Alvo de carga personalizado (corte por software)
// O carro só tem 6 presets (50/60/70/80/90/100). Este slider escolhe qualquer
// valor: o servidor carrega sem limite e, ao atingir o alvo, freia setando um
// preset abaixo do SOC atual (o carro encerra a carga). Útil pra parar logo
// abaixo de 97% — assim a regeneração volta a funcionar sem perder autonomia.
struct ChargeTargetSheet: View {
    @ObservedObject var cfg: ConfigStore
    @ObservedObject private var car = CarStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var target: Double = 97
    @State private var loaded = false

    private var active: Int { Int(car.num("charge_custom_target")) }

    private var subtitle: String {
        switch Int(target) {
        case ...74:  return "preserva mais a bateria"
        case 75...84: return "recomendado pro dia a dia"
        case 85...94: return "carga alta"
        default:      return "só antes de viagem longa"
        }
    }
    private let presets: [Int] = [70, 80, 90, 97, 99]
    private func presetLabel(_ p: Int) -> String { p >= 99 ? "viagem" : "\(p)" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Hero
                    VStack(spacing: 4) {
                        Text("\(Int(target))%")
                            .font(.system(size: 92, weight: .ultraLight, design: .rounded))
                            .foregroundStyle(DS.green).monospacedDigit()
                        Text(subtitle).font(.system(size: 13)).foregroundStyle(DS.text2)
                    }
                    .padding(.top, 8)

                    // Track desenhado à mão + gesto próprio.
                    //
                    // Antes havia um Slider nativo com opacity(0.02) por cima pra
                    // "capturar o gesto". Não funciona: o Slider do SwiftUI só arrasta
                    // pelo THUMB, e esse thumb é invisível — dava pra mover só acertando
                    // às cegas um alvo que não se vê (relatado em 05/08: "não consigo
                    // mover a barra"). A bolinha visível era decoração, sem gesto algum.
                    //
                    // Com DragGesture no track inteiro: arrasta de qualquer ponto e
                    // toque simples também posiciona — o que o nativo não faz.
                    GeometryReader { g in
                        let frac = CGFloat((target - 51) / 48)
                        ZStack(alignment: .leading) {
                            Capsule().fill(DS.panel3).frame(height: 10)
                            Capsule().fill(DS.greenGrad)
                                .frame(width: max(10, g.size.width * frac), height: 10)
                            // tick neutro no ponto médio (75%)
                            RoundedRectangle(cornerRadius: 1).fill(DS.text2.opacity(0.6))
                                .frame(width: 2, height: 14)
                                .offset(x: g.size.width * CGFloat((75.0 - 51) / 48) - 1)
                            Circle().fill(.white)
                                .frame(width: 22, height: 22)
                                .overlay(Circle().stroke(DS.green, lineWidth: 3))
                                .offset(x: max(0, min(g.size.width - 22, g.size.width * frac - 11)))
                        }
                        // Uma única frame que ocupa TODA a faixa: com `.frame(height:22)`
                        // seguido de `.frame(maxHeight:.infinity)` a área de toque ficava
                        // ambígua, e só a tira central de 22pt respondia.
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        // highPriorityGesture e NÃO gesture: dentro de um ScrollView, um
                        // DragGesture comum PERDE a disputa assim que o dedo desvia na
                        // vertical — daí "às vezes funciona, às vezes não" (05/08). Com
                        // prioridade alta, o arraste horizontal é sempre nosso.
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { v in
                                    let x = min(max(0, v.location.x), g.size.width)
                                    let novo = 51 + Double(x / max(1, g.size.width)) * 48
                                    let arred = novo.rounded()
                                    if arred != target {
                                        target = min(99, max(51, arred))
                                        // Um toque a cada 1% — dirigindo, você sente o
                                        // valor mudando sem precisar olhar a tela.
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.5)
                                    }
                                }
                        )
                    }
                    // 56pt: o dedo cobre ~45pt e ainda precisa de margem pra não exigir
                    // precisão. O visual continua com 22pt — só a área cresce.
                    .frame(height: 56)

                    // Presets
                    HStack(spacing: 8) {
                        ForEach(presets, id: \.self) { p in
                            let on = Int(target) == p
                            Button { target = Double(p) } label: {
                                Text(presetLabel(p))
                                    .font(.system(size: 13, weight: .bold))
                                    .frame(maxWidth: .infinity).frame(height: 36)
                                    .foregroundStyle(on ? .black : DS.text)
                                    .background(on ? DS.green : DS.panel)
                                    .clipShape(Capsule())
                                    .overlay(Capsule().stroke(on ? .clear : DS.border, lineWidth: 1))
                            }
                        }
                    }

                    // Impacto na carga atual
                    VStack(spacing: 0) {
                        impactRow("SOC agora", "\(Int(car.socPct))%", DS.text)
                        Divider().overlay(DS.divider)
                        impactRow("Alvo", "\(Int(target))%", DS.green)
                    }
                    .background(DS.panel2).clipShape(RoundedRectangle(cornerRadius: 15))

                    // CTA
                    Button {
                        Task { await cfg.setChargeTarget(Int(target)); dismiss() }
                    } label: {
                        Text("Aplicar \(Int(target))%").font(.system(size: 15, weight: .bold))
                            .frame(maxWidth: .infinity).frame(height: 42)
                            .foregroundStyle(.black).background(DS.green).clipShape(Capsule())
                    }
                    if active > 0 {
                        Button {
                            Task { await cfg.setChargeTarget(0); dismiss() }
                        } label: {
                            Text("Desligar (voltar aos presets)").font(.system(size: 14, weight: .semibold))
                                .frame(maxWidth: .infinity).frame(height: 40)
                                .foregroundStyle(DS.red).background(DS.panel2).clipShape(Capsule())
                        }
                    }

                    Text("Este alvo alimenta o marcador amarelo em todas as barras de SOC. Precisa do servidor online durante a recarga.")
                        .font(.system(size: 10.5)).foregroundStyle(DS.muted)
                        .multilineTextAlignment(.center).padding(.top, 2)
                }.padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Alvo personalizado").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() } } }
        }
        .onAppear { if !loaded { let a = Int(car.num("charge_custom_target")); if a >= 51 && a <= 99 { target = Double(a) }; loaded = true } }
    }

    private func impactRow(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack {
            Text(label).font(.system(size: 13)).foregroundStyle(DS.text2)
            Spacer()
            Text(value).font(.system(size: 15, weight: .semibold)).foregroundStyle(color).monospacedDigit()
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }
}
