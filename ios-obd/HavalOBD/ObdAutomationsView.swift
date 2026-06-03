import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  Automações (versão Haval OBD / iPad) — autocontida.
//  Cria regras que RODAM NO CARRO (motor no APK). Edição via bridge /api/rules;
//  o bridge entrega ao carro por MQTT retido. Mesmas regras do app do iPhone.
//  Usa bridgeBaseUrl + bridgeAuthToken do BridgePublisher (sem deps externas).
// ═══════════════════════════════════════════════════════════════════════════

@MainActor
final class ObdAutomationsStore: ObservableObject {
    @Published var rules: [[String: Any]] = []
    @Published var places: [[String: Any]] = []
    @Published var loading = false

    let publisher: BridgePublisher
    init(publisher: BridgePublisher) { self.publisher = publisher }

    private func base() -> String {
        let u = publisher.bridgeBaseUrl
        return u.hasSuffix("/") ? String(u.dropLast()) : u
    }
    private func makeReq(_ path: String, _ method: String = "GET", body: Any? = nil) -> URLRequest? {
        guard let url = URL(string: base() + path) else { return nil }
        var r = URLRequest(url: url); r.httpMethod = method; r.timeoutInterval = 15
        if !publisher.bridgeAuthToken.isEmpty {
            r.addValue("Bearer " + publisher.bridgeAuthToken, forHTTPHeaderField: "Authorization")
        }
        if let b = body {
            r.addValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: b)
        }
        return r
    }

    func load() async {
        loading = true; defer { loading = false }
        if let r = makeReq("/api/rules"),
           let (d, _) = try? await URLSession.shared.data(for: r),
           let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] {
            rules = arr
        }
        if let r = makeReq("/api/known-places"),
           let (d, _) = try? await URLSession.shared.data(for: r),
           let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] {
            places = arr
        }
    }

    func save(_ rule: [String: Any]) async {
        guard let r = makeReq("/api/rules", "POST", body: rule) else { return }
        _ = try? await URLSession.shared.data(for: r)
        await load()
    }

    func delete(_ id: String) async {
        guard let r = makeReq("/api/rules/\(id)", "DELETE") else { return }
        _ = try? await URLSession.shared.data(for: r)
        await load()
    }
}

struct ObdAutomationsView: View {
    @ObservedObject var publisher: BridgePublisher
    @StateObject private var store: ObdAutomationsStore
    @State private var editing: [String: Any]? = nil
    @State private var showEditor = false
    @Environment(\.dismiss) private var dismiss

    init(publisher: BridgePublisher) {
        self.publisher = publisher
        _store = StateObject(wrappedValue: ObdAutomationsStore(publisher: publisher))
    }

    var body: some View {
        NavigationStack { content }
    }

    private var content: some View {
        List {
            Section {
                Button {
                    editing = nil; showEditor = true
                } label: { Label("Nova automação", systemImage: "plus.circle.fill") }
            }
            if store.rules.isEmpty && !store.loading {
                Text("Nenhuma automação. O carro executa sozinho, sem o iPad.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(store.rules.indices, id: \.self) { i in
                let r = store.rules[i]
                Button {
                    editing = r; showEditor = true
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text((r["name"] as? String) ?? "Automação").font(.body).foregroundStyle(.primary)
                        Text(summary(r)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    Button(role: .destructive) {
                        if let id = r["id"] as? String { Task { await store.delete(id) } }
                    } label: { Label("Excluir", systemImage: "trash") }
                }
            }
        }
        .navigationTitle("Automações")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Concluído") { dismiss() } } }
        .overlay { if store.loading && store.rules.isEmpty { ProgressView() } }
        .sheet(isPresented: $showEditor) {
            ObdRuleEditor(store: store, existing: editing)
        }
        .task { await store.load() }
    }

    private func summary(_ r: [String: Any]) -> String {
        let t = r["trigger"] as? [String: Any] ?? [:]
        let a = r["action"] as? [String: Any] ?? [:]
        let trig: String
        switch t["type"] as? String {
        case "geofence":
            trig = ((t["edge"] as? String) == "exit" ? "Ao sair" : "Ao chegar") + " (\(Int((t["radius_m"] as? Double) ?? 50))m)"
        case "time":
            let m = (t["hhmm"] as? Int) ?? 0
            trig = String(format: "Às %02d:%02d", m / 60, m % 60)
        default: trig = "Gatilho"
        }
        let act: String
        switch a["type"] as? String {
        case "window": act = ((a["status"] as? Int) == 2 ? "abrir vidro" : "fechar vidro")
        case "skylight": act = "fechar teto"
        case "shade": act = "cortina \((a["level"] as? Int) ?? 0)"
        case "request": act = "\(a["key"] as? String ?? "")=\(a["value"] as? String ?? "")"
        default: act = "ação"
        }
        let cond = (r["conditions"] as? [String: Any]) != nil ? " · c/ condição" : ""
        return "\(trig) → \(act)\(cond)"
    }
}

private struct PlaceOpt: Identifiable { let id: String; let name: String; let lat: Double; let lng: Double }

struct ObdCond: Identifiable {
    let id = UUID()
    var type = "compare"     // "compare" (estado do carro) | "visited" (passou por local)
    var field = "car.basic.vehicle_speed"
    var customKey = ""
    var cmp = ">="
    var value = ""
    var placeId = ""
    var withinMin = 5.0
}

struct ObdRuleEditor: View {
    @ObservedObject var store: ObdAutomationsStore
    let existing: [String: Any]?
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var trigKind = 0          // 0=chegar,1=sair,2=horário,3=velocidade
    @State private var placeId = ""
    @State private var radius = 30.0
    @State private var time = Date()
    @State private var speedKmh = 10.0       // gatilho por velocidade (>=)
    @State private var actKind = 0           // 0=vidro,1=teto,2=cortina,3=avançado
    @State private var winTarget = 0         // 0..3, 4=todas
    @State private var winOpen = false
    @State private var shadeLevel = 0.0
    @State private var advKey = ""
    @State private var advValue = ""
    @State private var debounce = 120.0
    @State private var condOp = "AND"
    @State private var conditions: [ObdCond] = []

    private let condFields: [(String, String)] = [
        ("Velocidade km/h", "car.basic.vehicle_speed"),
        ("SOC %", "car.ev_info.soc_of_battery"),
        ("Trava", "car.basic.door_lock_status"),
        ("Marcha", "car.basic.gear_status"),
        ("Carregando", "car.ev_info.charging_state"),
        ("Motor (rpm)", "car.basic.engine_speed"),
        ("Power mode", "car.basic.power_mode"),
        ("Outro (chave)", "__custom__"),
    ]

    private var places: [PlaceOpt] {
        store.places.map { p in
            PlaceOpt(id: "\(p["id"] ?? "")", name: (p["name"] as? String) ?? "?",
                     lat: (p["lat"] as? Double) ?? 0, lng: (p["lng"] as? Double) ?? 0)
        }
    }
    private let winTargets = ["Motorista", "Passageiro", "Tras. esq.", "Tras. dir.", "Todas"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Nome") { TextField("Ex: Cortina na portaria", text: $name) }

                Section("Quando") {
                    Picker("Gatilho", selection: $trigKind) {
                        Text("Chegar").tag(0); Text("Sair").tag(1); Text("Horário").tag(2); Text("Velocidade").tag(3)
                    }.pickerStyle(.segmented)
                    if trigKind <= 1 {
                        Picker("Local", selection: $placeId) {
                            Text("Selecione…").tag("")
                            ForEach(places) { Text($0.name).tag($0.id) }
                        }
                        HStack { Text("Raio"); Slider(value: $radius, in: 5...300, step: 5); Text("\(Int(radius)) m").foregroundStyle(.secondary) }
                    } else if trigKind == 3 {
                        HStack { Text("Ao atingir"); Slider(value: $speedKmh, in: 1...60, step: 1); Text("\(Int(speedKmh)) km/h").foregroundStyle(.secondary) }
                        Text("Dispara quando a velocidade sobe e cruza esse valor (ex: sair da catraca). Combine com 'passou por X antes' pra limitar ao contexto certo.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        DatePicker("Horário", selection: $time, displayedComponents: .hourAndMinute)
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
                                Text("Estado do carro").tag("compare")
                                Text("Passou por local").tag("visited")
                            }.pickerStyle(.segmented)
                            if c.type == "compare" {
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
                                    TextField("valor", text: $c.value).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                                }
                            } else {
                                Picker("Local", selection: $c.placeId) {
                                    Text("Selecione…").tag("")
                                    ForEach(places) { Text($0.name).tag($0.id) }
                                }
                                HStack { Text("Há no máximo"); Slider(value: $c.withinMin, in: 1...60, step: 1); Text("\(Int(c.withinMin)) min").foregroundStyle(.secondary) }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .onDelete { conditions.remove(atOffsets: $0) }
                    Button { conditions.append(ObdCond()) } label: { Label("Adicionar condição", systemImage: "plus") }
                } header: { Text("Condições (opcional)") }
                  footer: { Text("Tudo precisa ser verdadeiro no momento do gatilho (ou qualquer uma, se OU). Combine quantas quiser.") }

                Section("Fazer") {
                    Picker("Ação", selection: $actKind) {
                        Text("Vidro").tag(0); Text("Teto").tag(1); Text("Cortina").tag(2); Text("Avançado").tag(3)
                    }.pickerStyle(.segmented)
                    switch actKind {
                    case 0:
                        Picker("Janela", selection: $winTarget) { ForEach(0..<winTargets.count, id: \.self) { Text(winTargets[$0]).tag($0) } }
                        Toggle("Abrir (desligado = fechar)", isOn: $winOpen)
                    case 1:
                        Text("Fecha o teto solar.").font(.caption).foregroundStyle(.secondary)
                    case 2:
                        HStack { Text("Nível"); Slider(value: $shadeLevel, in: 0...100, step: 5)
                            Text(shadeLevel == 0 ? "fechada" : (shadeLevel == 100 ? "aberta" : "\(Int(shadeLevel))%")).foregroundStyle(.secondary) }
                    default:
                        TextField("Chave (car.xxx.yyy)", text: $advKey).autocorrectionDisabled().textInputAutocapitalization(.never)
                        TextField("Valor", text: $advValue).autocorrectionDisabled().textInputAutocapitalization(.never)
                    }
                }

                Section("Avançado") {
                    HStack { Text("Intervalo mínimo"); Slider(value: $debounce, in: 0...600, step: 30); Text("\(Int(debounce))s").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle(existing == nil ? "Nova automação" : "Editar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Salvar") { save() }.disabled(!isValid) }
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
        switch trigKind {
        case 0, 1:
            if let p = places.first(where: { $0.id == placeId }) {
                rule["trigger"] = ["type": "geofence", "lat": p.lat, "lng": p.lng,
                                   "radius_m": radius, "edge": trigKind == 1 ? "exit" : "enter"]
            }
        case 3:
            rule["trigger"] = ["type": "state", "field": "car.basic.vehicle_speed", "cmp": ">=", "value": "\(Int(speedKmh))"]
        default:
            let cal = Calendar.current
            rule["trigger"] = ["type": "time", "hhmm": cal.component(.hour, from: time) * 60 + cal.component(.minute, from: time), "days": [Int]()]
        }
        // Condições (lista flexível: estado do carro e/ou passagem por locais).
        let items: [[String: Any]] = conditions.compactMap { c in
            if c.type == "visited" {
                guard let p = places.first(where: { $0.id == c.placeId }) else { return nil }
                return ["type": "visited", "lat": p.lat, "lng": p.lng, "radius_m": 30, "within_s": Int(c.withinMin * 60)]
            } else {
                let key = c.field == "__custom__" ? c.customKey.trimmingCharacters(in: .whitespaces) : c.field
                guard !key.isEmpty, !c.value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                return ["field": key, "cmp": c.cmp, "value": c.value]
            }
        }
        if !items.isEmpty { rule["conditions"] = ["op": condOp, "items": items] }
        switch actKind {
        case 0:
            if winTarget == 4 { rule["action"] = ["type": "window", "all": true, "status": winOpen ? 2 : 1] }
            else { rule["action"] = ["type": "window", "window": winTarget, "status": winOpen ? 2 : 1] }
        case 1: rule["action"] = ["type": "skylight", "level": 0]
        case 2: rule["action"] = ["type": "shade", "level": Int(shadeLevel)]
        default: rule["action"] = ["type": "request", "key": advKey, "value": advValue]
        }
        Task { await store.save(rule) }
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
                radius = (t["radius_m"] as? Double) ?? 30
                if let lat = t["lat"] as? Double, let lng = t["lng"] as? Double,
                   let p = places.min(by: { abs($0.lat - lat) + abs($0.lng - lng) < abs($1.lat - lat) + abs($1.lng - lng) }) { placeId = p.id }
            case "time":
                trigKind = 2
                let m = (t["hhmm"] as? Int) ?? 0
                time = Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
            case "state":
                trigKind = 3
                speedKmh = Double((t["value"] as? String).flatMap { Int($0) } ?? 10)
            default: break
            }
        }
        if let cg = e["conditions"] as? [String: Any], let items = cg["items"] as? [[String: Any]] {
            condOp = (cg["op"] as? String) ?? "AND"
            conditions = items.map { it in
                var c = ObdCond()
                if (it["type"] as? String) == "visited" {
                    c.type = "visited"
                    c.withinMin = Double(((it["within_s"] as? Int) ?? 300) / 60)
                    if let lat = it["lat"] as? Double, let lng = it["lng"] as? Double,
                       let p = places.min(by: { abs($0.lat - lat) + abs($0.lng - lng) < abs($1.lat - lat) + abs($1.lng - lng) }) { c.placeId = p.id }
                } else {
                    c.type = "compare"
                    let key = (it["field"] as? String) ?? ""
                    if condFields.contains(where: { $0.1 == key }) { c.field = key }
                    else { c.field = "__custom__"; c.customKey = key }
                    c.cmp = (it["cmp"] as? String) ?? "=="
                    c.value = (it["value"] as? String) ?? ""
                }
                return c
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
    }
}
