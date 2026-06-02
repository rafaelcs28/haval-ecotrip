//
//  ConfigSheets.swift
//  Sheets de Configurações: Notificações (catálogo completo do PWA),
//  Locais conhecidos (CRUD + vínculo) e Veículo (limite/nome/chassi).
//

import SwiftUI
import CoreLocation

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
            Item(key: "geofence_arrival", label: "Chegada a um local", places: "geofence_arrival_places"),
            Item(key: "geofence_departure", label: "Saída de um local", places: "geofence_departure_places"),
        ]),
        Group(title: "Bateria e SOC", items: [
            Item(key: "batt12_low", label: "Bateria 12V baixa"),
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
            Item(key: "app_update", label: "Atualização do app"),
        ]),
    ]
    private let laItems: [(String, String)] = [("la_charge","Recarga"),("la_preclimat","Pré-climatização"),("la_trip","Viagem"),("la_motor","Motor ligado"),("la_security","Segurança"),("preclimat_steps","Passos da pré-climatização")]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    DSCard(title: "Live Activities", icon: "bolt.badge.clock") {
                        VStack(spacing: 4) {
                            ForEach(laItems, id: \.0) { k, label in
                                Toggle(label, isOn: Binding(get: { cfg.laPrefs[k] ?? true }, set: { v in Task { await cfg.setLa(k, v) } })).tint(DS.green).font(.system(size: 14))
                            }
                        }
                    }
                    ForEach(groups, id: \.title) { g in
                        DSCard(title: g.title, icon: "bell.fill") {
                            VStack(spacing: 6) {
                                ForEach(g.items, id: \.key) { item in itemRow(item) }
                            }
                        }
                    }
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
struct KnownPlacesSheet: View {
    @ObservedObject var cfg: ConfigStore
    @ObservedObject private var car = CarStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var newRadius = 200.0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    DSCard(title: "Adicionar local", icon: "plus.circle") {
                        VStack(spacing: 10) {
                            TextField("Nome", text: $newName).foregroundStyle(DS.text)
                                .padding(9).background(DS.panel2).clipShape(RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(DS.border, lineWidth: 1))
                            HStack { Text("Raio").font(.caption).foregroundStyle(DS.muted); Spacer(); Text("\(Int(newRadius)) m").font(.system(size: 13, weight: .bold)).foregroundStyle(DS.text) }
                            Slider(value: $newRadius, in: 50...2000, step: 50).tint(DS.green)
                            Text(car.hasGps ? "Usa a posição atual do carro" : "Carro sem GPS — não dá pra adicionar agora").font(.caption2).foregroundStyle(DS.muted)
                            Button {
                                guard !newName.isEmpty, car.hasGps else { return }
                                Task { await cfg.addPlace(name: newName, lat: car.lat, lng: car.lng, radius: newRadius); newName = "" }
                            } label: {
                                Text("Adicionar").font(.system(size: 15, weight: .bold)).frame(maxWidth: .infinity).frame(height: 46)
                                    .foregroundStyle(.black).background((newName.isEmpty || !car.hasGps) ? DS.muted : DS.green).clipShape(RoundedRectangle(cornerRadius: 12))
                            }.disabled(newName.isEmpty || !car.hasGps)
                        }
                    }
                    ForEach(cfg.places) { p in PlaceRow(place: p, cfg: cfg) }
                }.padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Locais conhecidos").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Concluído") { dismiss() } } }
        }
        .task { await cfg.loadPlaces() }
    }
}

private struct PlaceRow: View {
    let place: KnownPlace
    let cfg: ConfigStore
    @State private var name = ""
    @State private var radius = 200.0
    @State private var loaded = false
    @State private var editing = false

    var body: some View {
        DSCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "mappin.circle.fill").foregroundStyle(DS.green)
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
                    HStack(spacing: 10) {
                        Button("Cancelar") { editing = false; name = place.name; radius = place.radiusM }.foregroundStyle(DS.muted)
                        Spacer()
                        Button("Salvar") { Task { await cfg.updatePlace(place.id, name: name, radius: radius); editing = false } }.font(.system(size: 14, weight: .bold)).foregroundStyle(DS.green)
                    }
                } else {
                    Button("Editar") { editing = true }.font(.caption).foregroundStyle(DS.blue)
                }
            }
        }
        .onAppear { if !loaded { name = place.name; radius = place.radiusM; loaded = true } }
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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    DSCard(title: "Limite de carga (SOC)", icon: "bolt.fill") {
                        let limit = Int(car.num("charge_limit_pct"))
                        HStack(spacing: 6) {
                            ForEach([50,60,70,80,90,100], id: \.self) { p in
                                let on = limit == p
                                Button { Task { await cfg.setChargeLimit(p) } } label: {
                                    Text("\(p)").font(.system(size: 13, weight: .bold)).frame(maxWidth: .infinity).frame(height: 38)
                                        .foregroundStyle(on ? .black : DS.text).background(on ? DS.green : DS.panel2).clipShape(RoundedRectangle(cornerRadius: 9))
                                }
                            }
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
        .task { await cfg.loadVehicle(); if !loaded { model = cfg.modelName; chassi = cfg.chassi; loaded = true } }
    }
    private func field(_ ph: String, text: Binding<String>) -> some View {
        TextField(ph, text: text).foregroundStyle(DS.text).autocorrectionDisabled().textInputAutocapitalization(.never)
            .padding(10).background(DS.panel2).clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(DS.border, lineWidth: 1))
    }
}
