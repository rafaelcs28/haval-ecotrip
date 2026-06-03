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
            .task { await cfg.loadPlaces(); await loader.load() }
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
    @State private var trigKind = 0          // 0=chegar, 1=sair, 2=horário
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

    struct Cond: Identifiable { let id = UUID(); var field = "car.basic.vehicle_speed"; var cmp = "=="; var value = "" }

    private let condFields: [(String, String)] = [
        ("Velocidade km/h", "car.basic.vehicle_speed"),
        ("SOC %", "car.ev_info.soc_of_battery"),
        ("Trava", "car.basic.door_lock_status"),
        ("Marcha", "car.basic.gear_status"),
        ("Carregando", "car.ev_info.charging_state"),
        ("Power mode", "car.basic.power_mode"),
    ]
    private let winTargets = ["Motorista", "Passageiro", "Tras. esq.", "Tras. dir.", "Todas"]
    private let weekdays = ["D", "S", "T", "Q", "Q", "S", "S"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Nome") {
                    TextField("Ex: Cortina na portaria", text: $name)
                }

                Section("Quando") {
                    Picker("Gatilho", selection: $trigKind) {
                        Text("Ao chegar").tag(0); Text("Ao sair").tag(1); Text("Em horário").tag(2)
                    }.pickerStyle(.segmented)

                    if trigKind <= 1 {
                        if cfg.places.isEmpty {
                            Text("Cadastre um Local Conhecido primeiro (Config › Locais conhecidos).")
                                .font(.caption).foregroundStyle(.orange)
                        } else {
                            Picker("Local", selection: $placeId) {
                                Text("Selecione…").tag("")
                                ForEach(cfg.places) { p in Text(p.name).tag(p.id) }
                            }
                            HStack { Text("Raio"); Slider(value: $radius, in: 20...300, step: 10); Text("\(Int(radius)) m").foregroundStyle(DS.muted) }
                        }
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
                    ForEach($conditions) { $c in
                        VStack(spacing: 6) {
                            Picker("Campo", selection: $c.field) {
                                ForEach(condFields, id: \.1) { Text($0.0).tag($0.1) }
                            }
                            HStack {
                                Picker("", selection: $c.cmp) {
                                    ForEach(["==", "!=", ">", "<", ">=", "<="], id: \.self) { Text($0).tag($0) }
                                }.pickerStyle(.menu)
                                TextField("valor", text: $c.value).keyboardType(.decimalPad)
                            }
                        }
                    }
                    Button { conditions.append(Cond()) } label: { Label("Adicionar condição", systemImage: "plus") }
                    if !conditions.isEmpty {
                        Button(role: .destructive) { conditions.removeLast() } label: { Text("Remover última") }
                    }
                } header: { Text("Condições (E) — opcional") }
                  footer: { Text("Todas precisam ser verdadeiras no momento do gatilho.") }

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
        }
    }

    private var isValid: Bool {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if trigKind <= 1 && placeId.isEmpty { return false }
        if actKind == 3 && advKey.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        return true
    }

    private func save() {
        var rule: [String: Any] = ["name": name, "enabled": true, "debounce_s": Int(debounce)]
        if let e = existing, let id = e["id"] as? String { rule["id"] = id }

        // Trigger
        if trigKind <= 1 {
            if let p = cfg.places.first(where: { $0.id == placeId }) {
                rule["trigger"] = ["type": "geofence", "lat": p.lat, "lng": p.lng,
                                   "radius_m": radius, "edge": trigKind == 1 ? "exit" : "enter"]
            }
        } else {
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

        // Conditions
        let items = conditions.filter { !$0.value.isEmpty }.map {
            ["field": $0.field, "cmp": $0.cmp, "value": $0.value]
        }
        if !items.isEmpty { rule["conditions"] = ["op": "AND", "items": items] }

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
                   let p = cfg.places.min(by: { abs($0.lat - lat) + abs($0.lng - lng) < abs($1.lat - lat) + abs($1.lng - lng) }) {
                    placeId = p.id
                }
            case "time":
                trigKind = 2
                let m = (t["hhmm"] as? Int) ?? 0
                time = Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
                days = Set((t["days"] as? [Int]) ?? [])
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
        if let c = e["conditions"] as? [String: Any], let items = c["items"] as? [[String: Any]] {
            conditions = items.map { Cond(field: ($0["field"] as? String) ?? "car.basic.vehicle_speed",
                                          cmp: ($0["cmp"] as? String) ?? "==", value: ($0["value"] as? String) ?? "") }
        }
    }
}
