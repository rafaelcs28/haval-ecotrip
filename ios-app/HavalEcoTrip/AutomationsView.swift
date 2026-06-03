//
//  AutomationsView.swift
//  Tela de Automações — cria/edita regras que RODAM NO CARRO (autônomas).
//  Fonte da verdade pra edição: bridge (/api/rules, offline-first via SyncedList).
//  Ao salvar, o bridge relaya a lista pro carro (MQTT retido) e o APK executa.
//
//  Gatilho: chegar/sair de um Local Conhecido (geofence) ou horário.
//  Ação: vidro, teto solar (fechar), cortina (0=fechada..100=aberta) ou avançado
//  (qualquer chave do carro = valor). Condições opcionais (AND) sobre o estado.
//

import SwiftUI
import Combine
import MapKit
import CoreLocation

// MARK: - Model

struct AutoRule: Identifiable {
    let raw: [String: Any]
    var id: String { (raw["id"] as? String) ?? UUID().uuidString }
    var name: String { (raw["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Automação" }
    var enabled: Bool { (raw["enabled"] as? Bool) ?? true }
    private var trigger: [String: Any] { (raw["trigger"] as? [String: Any]) ?? [:] }
    private var action: [String: Any] { (raw["action"] as? [String: Any]) ?? [:] }

    var summary: String {
        let t: String
        switch trigger["type"] as? String {
        case "geofence":
            let edge = (trigger["edge"] as? String) == "exit" ? "Ao sair" : "Ao chegar"
            t = "\(edge) (\(Int((trigger["radius_m"] as? Double) ?? 50))m)"
        case "time":
            let m = (trigger["hhmm"] as? Int) ?? 0
            t = String(format: "Às %02d:%02d", m / 60, m % 60)
        default: t = "Gatilho"
        }
        let a: String
        switch action["type"] as? String {
        case "window":  a = ((action["status"] as? Int) == 2 ? "abrir vidro" : "fechar vidro")
        case "skylight": a = "fechar teto"
        case "shade":   a = "cortina \((action["level"] as? Int) ?? 0)"
        case "request": a = "\(action["key"] as? String ?? "")=\(action["value"] as? String ?? "")"
        default: a = "ação"
        }
        return "\(t) → \(a)"
    }
}

@MainActor
final class RulesLoader: ObservableObject {
    let sync = SyncedList(name: "rules", path: "/api/rules", idKeys: ["id"], incremental: true, tombstoneKey: "rules")
    @Published var loading = false
    private var bag: AnyCancellable?
    init() { bag = sync.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() } }

    var rules: [AutoRule] { sync.items.map(AutoRule.init).sorted { $0.name < $1.name } }

    func load() async { loading = sync.items.isEmpty; await sync.sync(); loading = false }

    func upsert(_ rule: [String: Any]) async {
        let id = (rule["id"] as? String) ?? "rule_\(Int(Date().timeIntervalSince1970 * 1000))"
        var r = rule; r["id"] = id
        await sync.mutate(localId: id, apply: { _ in r }, method: "POST", opPath: "/api/rules", body: r)
        await sync.sync()   // pega o item novo (server seta _updated_ms)
    }

    func delete(_ id: String) async {
        await sync.mutate(localId: id, apply: { $0 }, method: "DELETE", opPath: "/api/rules/\(id)", body: nil)
    }

    func toggle(_ rule: AutoRule) async {
        var r = rule.raw; r["enabled"] = !rule.enabled
        await upsert(r)
    }
}

// MARK: - Lista

struct AutomationsSheet: View {
    @ObservedObject var cfg: ConfigStore
    @StateObject private var loader = RulesLoader()
    @Environment(\.dismiss) private var dismiss
    @State private var editing: [String: Any]? = nil
    @State private var showEditor = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    Button {
                        editing = nil; showEditor = true
                    } label: {
                        Label("Nova automação", systemImage: "plus.circle.fill")
                            .font(.system(size: 15, weight: .bold)).foregroundStyle(.black)
                            .frame(maxWidth: .infinity).frame(height: 46)
                            .background(DS.green).clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    if loader.rules.isEmpty && !loader.loading {
                        Text("Nenhuma automação ainda.\nO carro executa sozinho, mesmo sem o celular.")
                            .multilineTextAlignment(.center).font(.subheadline)
                            .foregroundStyle(DS.muted).padding(.top, 30)
                    }

                    ForEach(loader.rules) { r in
                        ruleCard(r)
                    }
                }
                .padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .overlay { if loader.loading && loader.rules.isEmpty { ProgressView().tint(DS.green) } }
            .navigationTitle("Automações").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Concluído") { dismiss() } } }
            .sheet(isPresented: $showEditor) {
                RuleEditorSheet(cfg: cfg, existing: editing) { rule in
                    Task { await loader.upsert(rule) }
                }
            }
            .task { await cfg.loadPlaces(); await cfg.loadAutomationPlaces(); await loader.load() }
        }
    }

    private func ruleCard(_ r: AutoRule) -> some View {
        DSCard {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(r.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.text)
                    Text(r.summary).font(.caption).foregroundStyle(DS.muted).lineLimit(2)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { r.enabled }, set: { _ in Task { await loader.toggle(r) } }))
                    .labelsHidden().tint(DS.green)
            }
            .contentShape(Rectangle())
            .onTapGesture { editing = r.raw; showEditor = true }
            .swipeActions { }   // placeholder
        }
        .contextMenu {
            Button(role: .destructive) { Task { await loader.delete(r.id) } } label: {
                Label("Excluir", systemImage: "trash")
            }
        }
    }
}

// MARK: - Editor

struct RuleEditorSheet: View {
    @ObservedObject var cfg: ConfigStore
    let existing: [String: Any]?
    let onSave: ([String: Any]) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var trigKind = 0          // 0=chegar, 1=sair, 2=horário, 3=estado
    @State private var trigField = "car.basic.vehicle_speed"
    @State private var trigCustomKey = ""
    @State private var trigCmp = ">="
    @State private var trigValue = "10"
    @State private var condOp = "AND"
    @State private var placeId = ""
    @State private var radius = 50.0
    @State private var time = Date()
    @State private var days = Set<Int>()     // 0=Dom..6=Sáb (vazio = todo dia)
    @State private var actKind = 0           // 0=vidro,1=teto,2=cortina,3=avançado
    @State private var winTarget = 0         // 0..3 ou 4=todas
    @State private var winOpen = false       // false=fechar(1), true=abrir(2)
    @State private var shadeLevel = 0.0      // 0=fechada..100=aberta
    @State private var advKey = ""
    @State private var advValue = ""
    @State private var debounce = 120.0
    @State private var conditions: [Cond] = []
    @State private var showPlacePicker = false
    @State private var pickerAutoSelectTrigger = false

    struct Cond: Identifiable {
        let id = UUID()
        var type = "compare"     // "compare" | "recent" | "visited"
        var field = "car.basic.vehicle_speed"; var customKey = ""; var cmp = "=="; var value = ""
        var placeIds: [String] = []; var withinMin = 5.0   // "visited": 1+ locais (OU)
        var withinSec = 60.0; var negate = false   // "recent"
    }

    private let condFields: [(String, String)] = [
        ("Velocidade km/h", "car.basic.vehicle_speed"),
        ("SOC %", "car.ev_info.soc_of_battery"),
        ("Trava", "car.basic.door_lock_status"),
        ("Marcha", "car.basic.gear_status"),
        ("Carregando", "car.ev_info.charging_state"),
        ("Motor (rpm)", "car.basic.engine_speed"),
        ("Power mode", "car.basic.power_mode"),
        ("Limpador diant.", "car.basic.front_wipwer_status"),
        ("Chuva (intens.)", "rain_intensity"),
        ("Outro (chave)", "__custom__"),
    ]
    private let winTargets = ["Motorista", "Passageiro", "Tras. esq.", "Tras. dir.", "Todas"]
    private let weekdays = ["D", "S", "T", "Q", "Q", "S", "S"]
    // Locais conhecidos (recarga/trajeto) + de automação — automação só LÊ os conhecidos.
    private var allPlaces: [KnownPlace] { cfg.places + cfg.automationPlaces }

    var body: some View {
        NavigationStack {
            Form {
                Section("Nome") {
                    TextField("Ex: Cortina na portaria", text: $name)
                }

                Section("Quando") {
                    Picker("Gatilho", selection: $trigKind) {
                        Text("Chegar").tag(0); Text("Sair").tag(1); Text("Horário").tag(2); Text("Estado").tag(3)
                    }.pickerStyle(.segmented)

                    if trigKind <= 1 {
                        if allPlaces.isEmpty {
                            Text("Cadastre um local primeiro (no iPad: Novo local pelo mapa, ou Config › Locais conhecidos).")
                                .font(.caption).foregroundStyle(.orange)
                        } else {
                            Picker("Local", selection: $placeId) {
                                Text("Selecione…").tag("")
                                ForEach(allPlaces) { p in Text(p.name).tag(p.id) }
                            }
                            Button { pickerAutoSelectTrigger = true; showPlacePicker = true } label: {
                                Label("Novo local pelo mapa", systemImage: "mappin.and.ellipse")
                            }
                            HStack { Text("Raio"); Slider(value: $radius, in: 5...300, step: 5); Text("\(Int(radius)) m").foregroundStyle(DS.muted) }
                        }
                    } else if trigKind == 3 {
                        Picker("Campo", selection: $trigField) {
                            ForEach(condFields, id: \.1) { Text($0.0).tag($0.1) }
                        }
                        if trigField == "__custom__" {
                            TextField("chave (car.xxx.yyy)", text: $trigCustomKey)
                                .autocorrectionDisabled().textInputAutocapitalization(.never)
                        }
                        HStack {
                            Picker("", selection: $trigCmp) {
                                ForEach(["==", "!=", ">", "<", ">=", "<="], id: \.self) { Text($0).tag($0) }
                            }.pickerStyle(.menu)
                            TextField("valor", text: $trigValue).keyboardType(.decimalPad)
                        }
                        Text("Dispara na borda: quando o estado passa a satisfazer (ex: velocidade ≥ 10, carregando = 1).")
                            .font(.caption).foregroundStyle(DS.muted)
                    } else {
                        DatePicker("Horário", selection: $time, displayedComponents: .hourAndMinute)
                        HStack(spacing: 6) {
                            ForEach(0..<7, id: \.self) { d in
                                let on = days.contains(d)
                                Text(weekdays[d]).font(.system(size: 13, weight: .bold))
                                    .frame(width: 34, height: 34)
                                    .background(on ? DS.green : DS.panel2).foregroundStyle(on ? .black : DS.text)
                                    .clipShape(Circle())
                                    .onTapGesture { if on { days.remove(d) } else { days.insert(d) } }
                            }
                        }
                        Text(days.isEmpty ? "Todos os dias" : "").font(.caption).foregroundStyle(DS.muted)
                    }
                }

                Section("Fazer") {
                    Picker("Ação", selection: $actKind) {
                        Text("Vidro").tag(0); Text("Teto").tag(1); Text("Cortina").tag(2); Text("Avançado").tag(3)
                    }.pickerStyle(.segmented)

                    switch actKind {
                    case 0:
                        Picker("Janela", selection: $winTarget) {
                            ForEach(0..<winTargets.count, id: \.self) { Text(winTargets[$0]).tag($0) }
                        }
                        Toggle("Abrir (desligado = fechar)", isOn: $winOpen)
                    case 1:
                        Text("Fecha o teto solar.").font(.caption).foregroundStyle(DS.muted)
                    case 2:
                        HStack { Text("Nível"); Slider(value: $shadeLevel, in: 0...100, step: 5)
                            Text(shadeLevel == 0 ? "fechada" : (shadeLevel == 100 ? "aberta" : "\(Int(shadeLevel))%")).foregroundStyle(DS.muted) }
                    default:
                        TextField("Chave (car.xxx.yyy)", text: $advKey).autocorrectionDisabled().textInputAutocapitalization(.never)
                        TextField("Valor", text: $advValue).autocorrectionDisabled().textInputAutocapitalization(.never)
                    }
                }

                Section {
                    if conditions.count > 1 {
                        Picker("Combinar", selection: $condOp) {
                            Text("Todas (E)").tag("AND"); Text("Qualquer (OU)").tag("OR")
                        }.pickerStyle(.segmented)
                    }
                    ForEach($conditions) { $c in
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("Tipo", selection: $c.type) {
                                Text("Estado").tag("compare")
                                Text("Recente").tag("recent")
                                Text("Local").tag("visited")
                            }.pickerStyle(.segmented)
                            if c.type == "compare" || c.type == "recent" {
                                Picker("Campo", selection: $c.field) {
                                    ForEach(condFields, id: \.1) { Text($0.0).tag($0.1) }
                                }
                                if c.field == "__custom__" {
                                    TextField("chave (car.xxx.yyy)", text: $c.customKey)
                                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                                }
                                HStack {
                                    Picker("", selection: $c.cmp) {
                                        ForEach(["==", "!=", ">", "<", ">=", "<="], id: \.self) { Text($0).tag($0) }
                                    }.pickerStyle(.menu)
                                    TextField("valor", text: $c.value).keyboardType(.decimalPad)
                                }
                                if c.type == "recent" {
                                    Toggle("NÃO ocorreu na janela", isOn: $c.negate)
                                    HStack { Text("Janela"); Slider(value: $c.withinSec, in: 5...600, step: 5); Text("\(Int(c.withinSec))s").foregroundStyle(DS.muted) }
                                }
                            } else {
                                Text("Passou por QUALQUER um (selecione 1+):").font(.caption).foregroundStyle(DS.muted)
                                ForEach(allPlaces) { p in
                                    Button {
                                        if c.placeIds.contains(p.id) { $c.placeIds.wrappedValue.removeAll { $0 == p.id } }
                                        else { $c.placeIds.wrappedValue.append(p.id) }
                                    } label: {
                                        HStack {
                                            Image(systemName: c.placeIds.contains(p.id) ? "checkmark.circle.fill" : "circle")
                                                .foregroundStyle(c.placeIds.contains(p.id) ? DS.green : DS.muted)
                                            Text(p.name).foregroundStyle(DS.text)
                                        }
                                    }
                                }
                                HStack { Text("Há no máximo"); Slider(value: $c.withinMin, in: 1...60, step: 1); Text("\(Int(c.withinMin)) min").foregroundStyle(DS.muted) }
                            }
                        }
                    }
                    .onDelete { conditions.remove(atOffsets: $0) }
                    Button { conditions.append(Cond()) } label: { Label("Adicionar condição", systemImage: "plus") }
                    Button { pickerAutoSelectTrigger = false; showPlacePicker = true } label: {
                        Label("Novo local pelo mapa", systemImage: "mappin.and.ellipse")
                    }
                } header: { Text("Condições (opcional)") }
                  footer: { Text("Tudo precisa ser verdadeiro no gatilho (ou qualquer um, se OU).") }

                Section("Avançado") {
                    HStack { Text("Intervalo mínimo"); Slider(value: $debounce, in: 0...600, step: 30); Text("\(Int(debounce))s").foregroundStyle(DS.muted) }
                }
            }
            .navigationTitle(existing == nil ? "Nova automação" : "Editar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar") { save() }.disabled(!isValid)
                }
            }
            .onAppear { loadExisting() }
            .sheet(isPresented: $showPlacePicker) {
                PlaceMapPicker(cfg: cfg) { newId in
                    if pickerAutoSelectTrigger { placeId = newId }
                }
            }
        }
    }

    private var isValid: Bool {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if trigKind <= 1 && placeId.isEmpty { return false }
        if trigKind == 3 {
            let key = trigField == "__custom__" ? trigCustomKey.trimmingCharacters(in: .whitespaces) : trigField
            if key.isEmpty || trigValue.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        }
        if actKind == 3 && advKey.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        return true
    }

    private func save() {
        var rule: [String: Any] = ["name": name, "enabled": true, "debounce_s": Int(debounce)]
        if let e = existing, let id = e["id"] as? String { rule["id"] = id }

        // Trigger
        switch trigKind {
        case 0, 1:
            if let p = allPlaces.first(where: { $0.id == placeId }) {
                rule["trigger"] = ["type": "geofence", "lat": p.lat, "lng": p.lng,
                                   "radius_m": radius, "edge": trigKind == 1 ? "exit" : "enter"]
            }
        case 3:
            let key = trigField == "__custom__" ? trigCustomKey.trimmingCharacters(in: .whitespaces) : trigField
            rule["trigger"] = ["type": "state", "field": key, "cmp": trigCmp, "value": trigValue]
        default:
            let cal = Calendar.current
            let h = cal.component(.hour, from: time), m = cal.component(.minute, from: time)
            rule["trigger"] = ["type": "time", "hhmm": h * 60 + m, "days": Array(days).sorted()]
        }

        // Action
        switch actKind {
        case 0:
            if winTarget == 4 { rule["action"] = ["type": "window", "all": true, "status": winOpen ? 2 : 1] }
            else { rule["action"] = ["type": "window", "window": winTarget, "status": winOpen ? 2 : 1] }
        case 1: rule["action"] = ["type": "skylight", "level": 0]
        case 2: rule["action"] = ["type": "shade", "level": Int(shadeLevel)]
        default: rule["action"] = ["type": "request", "key": advKey, "value": advValue]
        }

        // Conditions: estado do carro (compare) e/ou passagem por locais (visited).
        let items: [[String: Any]] = conditions.compactMap { c in
            if c.type == "visited" {
                let pts = c.placeIds.compactMap { id in allPlaces.first(where: { $0.id == id }) }
                    .map { ["lat": $0.lat, "lng": $0.lng, "radius_m": 30] as [String: Any] }
                guard !pts.isEmpty else { return nil }
                return ["type": "visited", "points": pts, "within_s": Int(c.withinMin * 60)]
            }
            let key = c.field == "__custom__" ? c.customKey.trimmingCharacters(in: .whitespaces) : c.field
            guard !key.isEmpty, !c.value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            if c.type == "recent" {
                return ["type": "recent", "field": key, "cmp": c.cmp, "value": c.value,
                        "within_s": Int(c.withinSec), "negate": c.negate]
            }
            return ["field": key, "cmp": c.cmp, "value": c.value]
        }
        if !items.isEmpty { rule["conditions"] = ["op": condOp, "items": items] }

        onSave(rule)
        dismiss()
    }

    private func loadExisting() {
        guard let e = existing else { return }
        name = (e["name"] as? String) ?? ""
        debounce = Double((e["debounce_s"] as? Int) ?? 120)
        if let t = e["trigger"] as? [String: Any] {
            switch t["type"] as? String {
            case "geofence":
                trigKind = (t["edge"] as? String) == "exit" ? 1 : 0
                radius = (t["radius_m"] as? Double) ?? 50
                // casa o local pelo lat/lng mais próximo
                if let lat = t["lat"] as? Double, let lng = t["lng"] as? Double,
                   let p = allPlaces.min(by: { abs($0.lat - lat) + abs($0.lng - lng) < abs($1.lat - lat) + abs($1.lng - lng) }) {
                    placeId = p.id
                }
            case "time":
                trigKind = 2
                let m = (t["hhmm"] as? Int) ?? 0
                time = Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
                days = Set((t["days"] as? [Int]) ?? [])
            case "state":
                trigKind = 3
                let key = (t["field"] as? String) ?? "car.basic.vehicle_speed"
                if condFields.contains(where: { $0.1 == key }) { trigField = key }
                else { trigField = "__custom__"; trigCustomKey = key }
                trigCmp = (t["cmp"] as? String) ?? ">="
                trigValue = (t["value"] as? String) ?? ""
            default: break
            }
        }
        if let a = e["action"] as? [String: Any] {
            switch a["type"] as? String {
            case "window": actKind = 0; winTarget = (a["all"] as? Bool) == true ? 4 : ((a["window"] as? Int) ?? 0); winOpen = (a["status"] as? Int) == 2
            case "skylight": actKind = 1
            case "shade": actKind = 2; shadeLevel = Double((a["level"] as? Int) ?? 0)
            case "request": actKind = 3; advKey = (a["key"] as? String) ?? ""; advValue = (a["value"] as? String) ?? ""
            default: break
            }
        }
        if let cg = e["conditions"] as? [String: Any], let items = cg["items"] as? [[String: Any]] {
            condOp = (cg["op"] as? String) ?? "AND"
            conditions = items.map { it in
                var c = Cond()
                let t = (it["type"] as? String) ?? "compare"
                if t == "visited" {
                    c.type = "visited"
                    c.withinMin = Double(((it["within_s"] as? Int) ?? 300) / 60)
                    let coords: [(Double, Double)]
                    if let pts = it["points"] as? [[String: Any]] {
                        coords = pts.compactMap { p in
                            guard let la = p["lat"] as? Double, let ln = p["lng"] as? Double else { return nil }
                            return (la, ln)
                        }
                    } else if let la = it["lat"] as? Double, let ln = it["lng"] as? Double {
                        coords = [(la, ln)]
                    } else { coords = [] }
                    c.placeIds = coords.compactMap { (la, ln) in
                        allPlaces.min(by: { abs($0.lat - la) + abs($0.lng - ln) < abs($1.lat - la) + abs($1.lng - ln) })?.id
                    }
                } else {
                    c.type = (t == "recent") ? "recent" : "compare"
                    let key = (it["field"] as? String) ?? "car.basic.vehicle_speed"
                    let known = condFields.contains(where: { $0.1 == key })
                    c.field = known ? key : "__custom__"; c.customKey = known ? "" : key
                    c.cmp = (it["cmp"] as? String) ?? "=="; c.value = (it["value"] as? String) ?? ""
                    c.withinSec = Double((it["within_s"] as? Int) ?? 60)
                    c.negate = (it["negate"] as? Bool) ?? false
                }
                return c
            }
        }
    }
}

// MARK: - Seletor de local pelo mapa (iPhone) — busca endereço, arrasta o pino,
// ou centraliza no carro. Salva como local de AUTOMAÇÃO (separado dos conhecidos).
struct PlaceMapPicker: View {
    @ObservedObject var cfg: ConfigStore
    let onSaved: (String) -> Void
    @ObservedObject private var car = CarStore.shared
    @Environment(\.dismiss) private var dismiss

    private static let fallback = CLLocationCoordinate2D(latitude: -16.6869, longitude: -49.2648)
    @State private var camera: MapCameraPosition = .region(MKCoordinateRegion(
        center: PlaceMapPicker.fallback, span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)))
    @State private var center = PlaceMapPicker.fallback
    @State private var query = ""
    @State private var name = ""
    @State private var radius = 30.0
    @State private var saving = false

    var body: some View {
        NavigationStack {
            ZStack {
                Map(position: $camera)
                    .onMapCameraChange(frequency: .continuous) { ctx in center = ctx.region.center }
                    .ignoresSafeArea(edges: .bottom)
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 36)).foregroundStyle(.red).shadow(radius: 3).offset(y: -18)
                    .allowsHitTesting(false)
            }
            .safeAreaInset(edge: .top) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Buscar endereço", text: $query)
                        .autocorrectionDisabled().submitLabel(.search)
                        .onSubmit { Task { await search() } }
                    Button { centerOnCar() } label: { Image(systemName: "car.fill") }
                }
                .padding(10).background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12)).padding()
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    TextField("Nome do local (ex: Portaria)", text: $name).textFieldStyle(.roundedBorder)
                    HStack { Text("Raio"); Slider(value: $radius, in: 5...300, step: 5); Text("\(Int(radius)) m").foregroundStyle(.secondary) }
                    Button {
                        Task {
                            saving = true
                            if let id = await cfg.addAutomationPlace(name: name.trimmingCharacters(in: .whitespaces),
                                lat: center.latitude, lng: center.longitude, radius: radius), !id.isEmpty {
                                onSaved(id); dismiss()
                            }
                            saving = false
                        }
                    } label: { Text(saving ? "Salvando…" : "Salvar local").bold().frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                }
                .padding().background(.regularMaterial)
            }
            .navigationTitle("Novo local").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } } }
            .onAppear { centerOnCar() }
        }
    }

    private func recenter(_ c: CLLocationCoordinate2D, span: Double) {
        center = c
        camera = .region(MKCoordinateRegion(center: c, span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)))
    }
    private func centerOnCar() {
        if car.lat != 0, car.lng != 0 { recenter(CLLocationCoordinate2D(latitude: car.lat, longitude: car.lng), span: 0.01) }
    }
    private func search() async {
        let req = MKLocalSearch.Request(); req.naturalLanguageQuery = query
        if let resp = try? await MKLocalSearch(request: req).start(), let item = resp.mapItems.first {
            recenter(item.placemark.coordinate, span: 0.005)
            if name.isEmpty { name = item.name ?? "" }
        }
    }
}
