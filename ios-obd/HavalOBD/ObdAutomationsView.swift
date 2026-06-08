import SwiftUI
import MapKit
import CoreLocation

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
        // Locais: SÓ os de automação (lista independente dos conhecidos de
        // recarga/trajeto). Gestão completa abaixo (add/update/delete).
        if let r = makeReq("/api/automation-places"),
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

    /// Cria um local de AUTOMAÇÃO (lista separada dos conhecidos) e recarrega.
    func addPlace(name: String, lat: Double, lng: Double, radius: Double) async -> String? {
        guard let r = makeReq("/api/automation-places", "POST",
                              body: ["name": name, "lat": lat, "lng": lng, "radius_m": radius]) else { return nil }
        guard let (d, _) = try? await URLSession.shared.data(for: r),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        await load()
        return "\(o["id"] ?? "")"
    }

    /// Catálogo de chaves do carro (referência pra montar condições/ações).
    func loadCarKeys() async -> [ObdCarKey] {
        guard let r = makeReq("/api/car-keys"),
              let (d, _) = try? await URLSession.shared.data(for: r),
              let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return [] }
        return arr.map { ObdCarKey(key: ($0["key"] as? String) ?? "", label: ($0["label"] as? String) ?? "", values: ($0["values"] as? String) ?? "") }
    }

    /// Edita um local de automação (nome/raio/posição) e recarrega.
    func updatePlace(_ id: String, name: String, lat: Double?, lng: Double?, radius: Double) async {
        var body: [String: Any] = ["name": name, "radius_m": radius]
        if let lat { body["lat"] = lat }
        if let lng { body["lng"] = lng }
        guard let r = makeReq("/api/automation-places/\(id)", "PUT", body: body) else { return }
        _ = try? await URLSession.shared.data(for: r)
        await load()
    }
    func deletePlace(_ id: String) async {
        guard let r = makeReq("/api/automation-places/\(id)", "DELETE") else { return }
        _ = try? await URLSession.shared.data(for: r)
        await load()
    }

    /// Posição atual do carro (state.gps_lat/lng) pra centralizar o mapa.
    func carLocation() async -> CLLocationCoordinate2D? {
        guard let r = makeReq("/api/state") else { return nil }
        guard let (d, _) = try? await URLSession.shared.data(for: r),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let la = o["gps_lat"] as? Double, let ln = o["gps_lng"] as? Double, la != 0, ln != 0 else { return nil }
        return CLLocationCoordinate2D(latitude: la, longitude: ln)
    }
}

struct ObdAutomationsView: View {
    @ObservedObject var publisher: BridgePublisher
    @StateObject private var store: ObdAutomationsStore
    @State private var editing: [String: Any]? = nil
    @State private var showEditor = false
    @State private var showPlacesManager = false
    @State private var showKeysRef = false
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
                Button {
                    showPlacesManager = true
                } label: { Label("Gerenciar locais de automação", systemImage: "mappin.and.ellipse") }
                Button {
                    showKeysRef = true
                } label: { Label("Chaves do carro (referência)", systemImage: "list.bullet.rectangle") }
            } footer: {
                Text("Locais de automação são independentes dos de recarga/trajeto. \"Chaves do carro\" lista os campos disponíveis pra usar nas condições/ações — toque pra copiar.")
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
                    Button {
                        var copy = r
                        copy.removeValue(forKey: "id")
                        copy.removeValue(forKey: "_updated_ms")
                        copy["name"] = ((r["name"] as? String) ?? "Automação") + " (cópia)"
                        copy["enabled"] = true
                        editing = copy; showEditor = true
                    } label: { Label("Duplicar", systemImage: "doc.on.doc") }.tint(.blue)
                }
            }
        }
        .navigationTitle("Automações")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Concluído") { dismiss() } } }
        .overlay { if store.loading && store.rules.isEmpty { ProgressView() } }
        .sheet(isPresented: $showEditor) {
            ObdRuleEditor(store: store, existing: editing)
        }
        .sheet(isPresented: $showPlacesManager) {
            ObdPlacesManager(store: store)
        }
        .sheet(isPresented: $showKeysRef) {
            ObdCarKeysReference(store: store)
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
    var type = "compare"     // "compare" (estado agora) | "recent" (nos últimos N s) | "visited" (passou por local)
    var field = "car.basic.vehicle_speed"
    var customKey = ""
    var cmp = ">="
    var value = ""
    var placeIds: [String] = []   // "visited": um ou mais locais (passou por QUALQUER um = OU)
    var withinMin = 5.0
    var withinSec = 60.0     // janela do "recent"
    var negate = false       // "recent": true = NÃO ocorreu na janela
    var fromMin = 0; var toMin = 1439; var condDays: Set<Int> = []   // "time": faixa (min do dia) + dias
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
    // Gatilho por estado (genérico): qualquer chave + comparador + valor (borda).
    @State private var trigField = "car.basic.vehicle_speed"
    @State private var trigCustomKey = ""
    @State private var trigCmp = ">="
    @State private var trigValue = "10"
    @State private var actKind = 0           // 0=vidro,1=teto,2=cortina,3=avançado
    @State private var winTarget = 0         // 0..3, 4=todas
    @State private var winOpen = false
    @State private var shadeLevel = 0.0
    @State private var advKey = ""
    @State private var advValue = ""
    @State private var debounce = 120.0
    @State private var delaySec = 0.0    // espera antes de executar a ação (s)
    @State private var stableSec = 0.0   // condição estável por X s antes de disparar
    @State private var repeatSec = 0.0   // repetir a ação a cada X s enquanto a condição durar
    @State private var condOp = "AND"
    @State private var conditions: [ObdCond] = []
    @State private var showPlacePicker = false
    @State private var pickerAutoSelectTrigger = false
    @State private var carKeys: [ObdCarKey] = []   // catálogo p/ autocomplete da chave custom

    // Conversão minuto-do-dia ↔ Date pros DatePickers da condição "time".
    static func dateFromMin(_ m: Int) -> Date { Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date() }
    static func minFromDate(_ d: Date) -> Int { let c = Calendar.current.dateComponents([.hour, .minute], from: d); return (c.hour ?? 0) * 60 + (c.minute ?? 0) }

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
        ("Aviso de cinto", "car.basic.seat_belt_warning"),
        ("Passageiro sentado", "car.basic.seated_state[1]"),
        ("Outro (chave)", "__custom__"),
    ]

    private var places: [PlaceOpt] {
        store.places.map { p in
            PlaceOpt(id: "\(p["id"] ?? "")", name: (p["name"] as? String) ?? "?",
                     lat: (p["lat"] as? Double) ?? 0, lng: (p["lng"] as? Double) ?? 0)
        }
    }
    private let winTargets = ["Motorista", "Passageiro", "Tras. esq.", "Tras. dir.", "Todas"]

    // Modelos prontos (só ao criar). Tocar preenche o formulário; o usuário revisa e salva.
    struct ObdRuleTemplate: Identifiable { let id: Int; let group: String; let icon: String; let title: String; let desc: String }
    static let templateGroups = ["Conforto", "Chuva", "Energia / EV", "Recarga", "Segurança"]
    private let templates: [ObdRuleTemplate] = [
        // Conforto
        .init(id: 1,  group: "Conforto", icon: "snowflake",             title: "Desligar AC esquecido",   desc: "AC ligado + carro parado → desliga o AC"),
        .init(id: 4,  group: "Conforto", icon: "aqi.medium",            title: "Ar poluído → recircular", desc: "PM2.5 alto → recirculação interna do ar"),
        .init(id: 5,  group: "Conforto", icon: "house",                 title: "Abrir cortina ao chegar", desc: "Ao chegar no local → abre a cortina"),
        .init(id: 6,  group: "Conforto", icon: "thermometer.snowflake", title: "Desembaçar manhã fria",   desc: "Horário + temp. externa < 10° → desembaçador"),
        .init(id: 7,  group: "Conforto", icon: "snowflake",             title: "Ar gelado no calor",      desc: "Temp. interna > 38° → AC máximo"),
        .init(id: 8,  group: "Conforto", icon: "fanblades",             title: "Ventilar bancos no calor",desc: "Temp. interna > 35° → ventilação do banco"),
        .init(id: 9,  group: "Conforto", icon: "flame",                 title: "Aquecimento manhã fria",  desc: "Horário + temp. externa < 5° → aquecimento"),
        .init(id: 10, group: "Conforto", icon: "sparkles",              title: "Ionizador ao ligar",      desc: "Carro pronto → liga o ionizador"),
        .init(id: 11, group: "Conforto", icon: "wind",                  title: "Qualidade do ar ao ligar",desc: "Carro pronto → liga a recirculação automática (AQS)"),
        .init(id: 22, group: "Conforto", icon: "person.fill",           title: "Ventilar passageiro ao sentar",desc: "AC ligado + passageiro sentado → ventilação do banco nível 3"),
        .init(id: 23, group: "Conforto", icon: "person.slash",          title: "Desligar vent. passageiro",desc: "Ninguém no passageiro → desliga a ventilação do banco"),
        // Chuva
        .init(id: 12, group: "Chuva",    icon: "cloud.rain",            title: "Choveu → fechar vidros",  desc: "Chuva detectada → fecha todos os vidros"),
        .init(id: 13, group: "Chuva",    icon: "cloud.heavyrain",       title: "Choveu → fechar teto",    desc: "Chuva + teto aberto → fecha o teto"),
        .init(id: 14, group: "Chuva",    icon: "drop",                  title: "Limpador → fechar teto",  desc: "Limpador ligado + teto aberto → fecha o teto"),
        // Energia / EV
        .init(id: 15, group: "Energia / EV", icon: "bolt.fill",                  title: "Cidade → EV puro",        desc: "Ao chegar no local → modo EV puro"),
        .init(id: 16, group: "Energia / EV", icon: "arrow.triangle.2.circlepath",title: "Cidade → regeneração alta",desc: "Ao chegar no local → regeneração alta"),
        .init(id: 17, group: "Energia / EV", icon: "1.circle",                   title: "Cidade → um pedal",       desc: "Ao chegar no local → condução de um pedal"),
        .init(id: 18, group: "Energia / EV", icon: "fuelpump.fill",              title: "Viagem → HEV (bateria baixa)",desc: "SOC ≤ 20% em movimento → modo HEV"),
        .init(id: 19, group: "Energia / EV", icon: "leaf.fill",                  title: "Reserva inteligente",     desc: "SOC ≤ 30% → reserva de energia inteligente"),
        // Recarga
        .init(id: 20, group: "Recarga",  icon: "battery.100.bolt",      title: "Limite 100% ao recarregar",desc: "Começou a carregar → limite de carga em 100%"),
        // Segurança
        .init(id: 2,  group: "Segurança", icon: "arrow.up.right.square", title: "Fechar vidros ao sair",   desc: "Ao sair do local → fecha todos os vidros"),
        .init(id: 3,  group: "Segurança", icon: "speedometer",           title: "Fechar teto andando",     desc: "Velocidade ≥ 10 + teto aberto → fecha o teto"),
        .init(id: 21, group: "Segurança", icon: "parkingsign",           title: "Estacionou → fechar vidros",desc: "Marcha em P → fecha todos os vidros"),
    ]

    private func applyTemplate(_ id: Int) {
        conditions = []
        switch id {
        case 1:
            name = "Desligar AC esquecido"
            trigKind = 3; trigField = "__custom__"; trigCustomKey = "car.hvac.fan_speed"; trigCmp = ">="; trigValue = "1"
            conditions = [ObdCond(type: "compare", field: "car.basic.vehicle_speed", cmp: "==", value: "0")]
            actKind = 3; advKey = "car.hvac.ac_enable"; advValue = "0"; debounce = 900
        case 2:
            name = "Fechar vidros ao sair"
            trigKind = 1; radius = 50
            actKind = 0; winTarget = 4; winOpen = false
        case 3:
            name = "Fechar teto andando"
            trigKind = 3; trigField = "car.basic.vehicle_speed"; trigCmp = ">="; trigValue = "10"
            conditions = [ObdCond(type: "compare", field: "__custom__", customKey: "car.basic.sunroof_status", cmp: ">", value: "0")]
            actKind = 1
        case 4:
            name = "Ar poluído → recircular"
            trigKind = 3; trigField = "__custom__"; trigCustomKey = "car.hvac.pm2.5_value"; trigCmp = ">="; trigValue = "80"
            actKind = 3; advKey = "car.hvac.cycle_mode"; advValue = "0"
        case 5:
            name = "Abrir cortina ao chegar"
            trigKind = 0; radius = 50
            actKind = 2; shadeLevel = 100
        case 6:
            name = "Desembaçar manhã fria"
            trigKind = 2
            conditions = [ObdCond(type: "compare", field: "__custom__", customKey: "car.basic.outside_temp", cmp: "<", value: "10")]
            actKind = 3; advKey = "car.hvac.front_defrost_enable"; advValue = "1"
        case 7:
            name = "Ar gelado no calor"
            trigKind = 3; trigField = "__custom__"; trigCustomKey = "car.basic.inside_temp"; trigCmp = ">"; trigValue = "38"
            actKind = 3; advKey = "car.hvac.acmax_enable"; advValue = "1"
        case 8:
            name = "Ventilar bancos no calor"
            trigKind = 3; trigField = "__custom__"; trigCustomKey = "car.basic.inside_temp"; trigCmp = ">"; trigValue = "35"
            actKind = 3; advKey = "car.comfort_setting.driver_seat_ventilation_level"; advValue = "3"
        case 9:
            name = "Aquecimento manhã fria"
            trigKind = 2
            conditions = [ObdCond(type: "compare", field: "__custom__", customKey: "car.basic.outside_temp", cmp: "<", value: "5")]
            actKind = 3; advKey = "car.hvac.heating_enable"; advValue = "1"
        case 10:
            name = "Ionizador ao ligar"
            trigKind = 3; trigField = "__custom__"; trigCustomKey = "car.basic.driving_ready_state"; trigCmp = "=="; trigValue = "1"
            actKind = 3; advKey = "car.hvac.anion_enable"; advValue = "1"
        case 11:
            name = "Qualidade do ar (AQS) ao ligar"
            trigKind = 3; trigField = "__custom__"; trigCustomKey = "car.basic.driving_ready_state"; trigCmp = "=="; trigValue = "1"
            actKind = 3; advKey = "car.hvac.aqs_enable"; advValue = "1"
        case 12:
            name = "Choveu → fechar vidros"
            trigKind = 3; trigField = "rain_intensity"; trigCmp = ">"; trigValue = "0"
            actKind = 0; winTarget = 4; winOpen = false
        case 13:
            name = "Choveu → fechar teto"
            trigKind = 3; trigField = "rain_intensity"; trigCmp = ">"; trigValue = "0"
            conditions = [ObdCond(type: "compare", field: "__custom__", customKey: "car.basic.sunroof_status", cmp: ">", value: "0")]
            actKind = 1
        case 14:
            name = "Limpador → fechar teto"
            trigKind = 3; trigField = "car.basic.front_wipwer_status"; trigCmp = ">"; trigValue = "0"
            conditions = [ObdCond(type: "compare", field: "__custom__", customKey: "car.basic.sunroof_status", cmp: ">", value: "0")]
            actKind = 1
        case 15:
            name = "Cidade → EV puro"
            trigKind = 0; radius = 50
            actKind = 3; advKey = "car.ev_setting.power_model_config"; advValue = "3"
        case 16:
            name = "Cidade → regeneração alta"
            trigKind = 0; radius = 50
            actKind = 3; advKey = "car.ev_setting.energy_recovery_level"; advValue = "1"
        case 17:
            name = "Cidade → um pedal"
            trigKind = 0; radius = 50
            actKind = 3; advKey = "car.ev.setting.pedal_control_enable"; advValue = "1"
        case 18:
            name = "Viagem → HEV (bateria baixa)"
            trigKind = 3; trigField = "car.ev_info.soc_of_battery"; trigCmp = "<="; trigValue = "20"
            conditions = [ObdCond(type: "compare", field: "car.basic.vehicle_speed", cmp: ">", value: "0")]
            actKind = 3; advKey = "car.ev_setting.power_model_config"; advValue = "0"
        case 19:
            name = "Reserva inteligente"
            trigKind = 3; trigField = "car.ev_info.soc_of_battery"; trigCmp = "<="; trigValue = "30"
            actKind = 3; advKey = "car.ev_setting.power_reserve_config"; advValue = "1"
        case 20:
            name = "Limite 100% ao recarregar"
            trigKind = 3; trigField = "car.ev_info.charging_state"; trigCmp = "=="; trigValue = "1"
            actKind = 3; advKey = "car.ev_setting.charge_soc_limit_config"; advValue = "0"
        case 21:
            name = "Estacionou → fechar vidros"
            trigKind = 3; trigField = "car.basic.gear_status"; trigCmp = "=="; trigValue = "3"
            actKind = 0; winTarget = 4; winOpen = false
        case 22:
            name = "Ventilar passageiro ao sentar"
            trigKind = 3; trigField = "car.basic.seated_state[1]"; trigCmp = "=="; trigValue = "1"
            conditions = [ObdCond(type: "compare", field: "__custom__", customKey: "car.hvac.ac_enable", cmp: "==", value: "1")]
            actKind = 3; advKey = "car.comfort_setting.passenger_seat_ventilation_level"; advValue = "3"
        case 23:
            name = "Desligar vent. passageiro"
            trigKind = 3; trigField = "car.basic.seated_state[1]"; trigCmp = "=="; trigValue = "0"
            actKind = 3; advKey = "car.comfort_setting.passenger_seat_ventilation_level"; advValue = "0"
        default: break
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if existing == nil {
                    ForEach(Self.templateGroups, id: \.self) { g in
                        Section(g == Self.templateGroups.first ? "Modelos · \(g)" : g) {
                            ForEach(templates.filter { $0.group == g }) { t in
                                Button { applyTemplate(t.id) } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: t.icon).frame(width: 26).foregroundStyle(.green)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(t.title).foregroundStyle(.primary)
                                            Text(t.desc).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                Section("Nome") { TextField("Ex: Cortina na portaria", text: $name) }

                quandoSection
                condicoesSection
                fazerSection
                avancadoSection
            }
            .navigationTitle(existing == nil ? "Nova automação" : "Editar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Salvar") { save() }.disabled(!isValid) }
            }
            .onAppear { loadExisting() }
            .task { if carKeys.isEmpty { carKeys = await store.loadCarKeys() } }
            .sheet(isPresented: $showPlacePicker) {
                ObdPlacePickerView(store: store) { newId in
                    if pickerAutoSelectTrigger { placeId = newId }
                }
            }
        }
    }

    @ViewBuilder private var quandoSection: some View {
                Section("Quando") {
                    Picker("Gatilho", selection: $trigKind) {
                        Text("Chegar").tag(0); Text("Sair").tag(1); Text("Horário").tag(2); Text("Estado").tag(3)
                    }.pickerStyle(.segmented)
                    if trigKind <= 1 {
                        Picker("Local", selection: $placeId) {
                            Text("Selecione…").tag("")
                            ForEach(places) { Text($0.name).tag($0.id) }
                        }
                        Button { pickerAutoSelectTrigger = true; showPlacePicker = true } label: {
                            Label("Novo local pelo mapa", systemImage: "mappin.and.ellipse")
                        }
                        HStack { Text("Raio"); Slider(value: $radius, in: 5...300, step: 5); Text("\(Int(radius)) m").foregroundStyle(.secondary) }
                    } else if trigKind == 3 {
                        Picker("Campo", selection: $trigField) {
                            ForEach(condFields, id: \.1) { Text($0.0).tag($0.1) }
                        }
                        if trigField == "__custom__" {
                            TextField("chave (car.xxx.yyy)", text: $trigCustomKey)
                                .autocorrectionDisabled().textInputAutocapitalization(.never)
                            let q = trigCustomKey.lowercased()
                            if !q.isEmpty, !carKeys.contains(where: { $0.key == trigCustomKey }) {
                                ForEach(Array(carKeys.filter { $0.key.lowercased().contains(q) || $0.label.lowercased().contains(q) }.prefix(6))) { k in
                                    Button { trigCustomKey = k.key } label: {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(k.label).font(.caption).foregroundStyle(.primary)
                                            Text(k.key).font(.system(size: 11, design: .monospaced)).foregroundStyle(.blue)
                                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                        HStack {
                            Picker("", selection: $trigCmp) {
                                ForEach(["==", "!=", ">", "<", ">=", "<="], id: \.self) { Text($0).tag($0) }
                            }.pickerStyle(.menu)
                            TextField("valor", text: $trigValue).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                        }
                        Text("Dispara na borda: quando o estado passa a satisfazer (ex: velocidade ≥ 10, carregando = 1, trava = 0).")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        DatePicker("Horário", selection: $time, displayedComponents: .hourAndMinute)
                    }
                }

    }

    @ViewBuilder private var condicoesSection: some View {
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
                                Text("Horário").tag("time")
                            }.pickerStyle(.segmented)
                            if c.type == "compare" || c.type == "recent" {
                                Picker("Campo", selection: $c.field) {
                                    ForEach(condFields, id: \.1) { Text($0.0).tag($0.1) }
                                }
                                if c.field == "__custom__" {
                                    TextField("chave (car.xxx.yyy)", text: $c.customKey)
                                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                                    // Autocomplete: filtra o catálogo de chaves conforme digita.
                                    let q = c.customKey.lowercased()
                                    if !q.isEmpty, !carKeys.contains(where: { $0.key == c.customKey }) {
                                        ForEach(Array(carKeys.filter { $0.key.lowercased().contains(q) || $0.label.lowercased().contains(q) }.prefix(6))) { k in
                                            Button { $c.customKey.wrappedValue = k.key } label: {
                                                VStack(alignment: .leading, spacing: 1) {
                                                    Text(k.label).font(.caption).foregroundStyle(.primary)
                                                    Text(k.key).font(.system(size: 11, design: .monospaced)).foregroundStyle(.blue)
                                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                            }.buttonStyle(.plain)
                                        }
                                    }
                                }
                                HStack {
                                    Picker("", selection: $c.cmp) {
                                        ForEach(["==", "!=", ">", "<", ">=", "<="], id: \.self) { Text($0).tag($0) }
                                    }.pickerStyle(.menu)
                                    TextField("valor", text: $c.value).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                                }
                                if c.type == "recent" {
                                    Toggle("NÃO ocorreu na janela", isOn: $c.negate)
                                    HStack { Text("Janela"); Slider(value: $c.withinSec, in: 5...600, step: 5); Text("\(Int(c.withinSec))s").foregroundStyle(.secondary) }
                                    Text(c.negate ? "Passa se o campo NÃO satisfez nos últimos segundos (ex: limpador != 0 → não acionou)."
                                                  : "Passa se o campo satisfez em algum momento nos últimos segundos.")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            } else if c.type == "time" {
                                DatePicker("De", selection: Binding(
                                    get: { Self.dateFromMin(c.fromMin) },
                                    set: { $c.fromMin.wrappedValue = Self.minFromDate($0) }), displayedComponents: .hourAndMinute)
                                DatePicker("Até", selection: Binding(
                                    get: { Self.dateFromMin(c.toMin) },
                                    set: { $c.toMin.wrappedValue = Self.minFromDate($0) }), displayedComponents: .hourAndMinute)
                                HStack(spacing: 4) {
                                    ForEach(0..<7, id: \.self) { d in
                                        let on = c.condDays.contains(d)
                                        Button {
                                            var s = c.condDays
                                            if s.contains(d) { s.remove(d) } else { s.insert(d) }
                                            $c.condDays.wrappedValue = s
                                        } label: {
                                            Text(["D","S","T","Q","Q","S","S"][d]).font(.system(size: 13, weight: .bold)).frame(maxWidth: .infinity).frame(height: 32)
                                                .foregroundStyle(on ? .black : .primary).background(on ? Color.green : Color(.systemGray5)).clipShape(RoundedRectangle(cornerRadius: 7))
                                        }.buttonStyle(.borderless)
                                    }
                                }
                                Text("Vazio = todo dia. Passa se o horário atual estiver na faixa (e no dia, se marcado).")
                                    .font(.caption2).foregroundStyle(.secondary)
                            } else {
                                Text("Passou por QUALQUER um (selecione 1+):").font(.caption).foregroundStyle(.secondary)
                                ForEach(places) { p in
                                    // .buttonStyle(.plain) impede o Form de tratar o tap como
                                    // "row tap" (marcava todos os botões da Section). Mutação
                                    // por assignment explícito ao binding é mais robusta que
                                    // `wrappedValue.append`.
                                    Button {
                                        var ids = c.placeIds
                                        if let i = ids.firstIndex(of: p.id) { ids.remove(at: i) }
                                        else { ids.append(p.id) }
                                        $c.placeIds.wrappedValue = ids
                                    } label: {
                                        HStack {
                                            Image(systemName: c.placeIds.contains(p.id) ? "checkmark.circle.fill" : "circle")
                                                .foregroundStyle(c.placeIds.contains(p.id) ? .green : .secondary)
                                            Text(p.name).foregroundStyle(.primary)
                                            Spacer()
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                                HStack { Text("Há no máximo"); Slider(value: $c.withinMin, in: 1...60, step: 1); Text("\(Int(c.withinMin)) min").foregroundStyle(.secondary) }
                            }
                            // Remover por id (não por offset): swipe-to-delete com
                            // ForEach($binding) + conteúdo complexo crashava o app.
                            // .borderless: cada botão vira alvo de toque independente no
                            // Form (sem isso, "Remover" acionava o picker de chave).
                            Button(role: .destructive) {
                                let cid = c.id
                                conditions.removeAll { $0.id == cid }
                            } label: { Label("Remover condição", systemImage: "trash").font(.caption) }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 2)
                    }
                    Button { conditions.append(ObdCond()) } label: { Label("Adicionar condição", systemImage: "plus") }
                        .buttonStyle(.borderless)
                    Button { pickerAutoSelectTrigger = false; showPlacePicker = true } label: {
                        Label("Novo local pelo mapa", systemImage: "mappin.and.ellipse")
                    }.buttonStyle(.borderless)
                } header: { Text("Condições (opcional)") }
                  footer: { Text("Tudo precisa ser verdadeiro no momento do gatilho (ou qualquer uma, se OU). Combine quantas quiser.") }
    }

    @ViewBuilder private var fazerSection: some View {
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

    }

    @ViewBuilder private var avancadoSection: some View {
                Section {
                    HStack { Text("Esperar antes de executar"); Slider(value: $delaySec, in: 0...300, step: 5); Text("\(Int(delaySec))s").foregroundStyle(.secondary) }
                    HStack { Text("Condição estável por"); Slider(value: $stableSec, in: 0...120, step: 5); Text("\(Int(stableSec))s").foregroundStyle(.secondary) }
                    HStack { Text("Repetir enquanto valer"); Slider(value: $repeatSec, in: 0...600, step: 10); Text(repeatSec > 0 ? "\(Int(repeatSec))s" : "não").foregroundStyle(.secondary) }
                    HStack { Text("Intervalo mínimo"); Slider(value: $debounce, in: 0...600, step: 30); Text("\(Int(debounce))s").foregroundStyle(.secondary) }
                } header: { Text("Avançado") }
                  footer: { Text("Esperar: aguarda após o gatilho e revalida a condição. Estável por: a condição (gatilho de estado) precisa durar esse tempo. Repetir: reexecuta a ação nesse intervalo enquanto a condição valer. Intervalo mínimo: tempo entre disparos.") }
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
        var rule: [String: Any] = ["name": name, "enabled": true, "debounce_s": Int(debounce), "delay_s": Int(delaySec), "stable_s": Int(stableSec), "repeat_s": Int(repeatSec)]
        if let e = existing, let id = e["id"] as? String { rule["id"] = id }
        switch trigKind {
        case 0, 1:
            if let p = places.first(where: { $0.id == placeId }) {
                rule["trigger"] = ["type": "geofence", "lat": p.lat, "lng": p.lng,
                                   "radius_m": radius, "edge": trigKind == 1 ? "exit" : "enter"]
            }
        case 3:
            let key = trigField == "__custom__" ? trigCustomKey.trimmingCharacters(in: .whitespaces) : trigField
            rule["trigger"] = ["type": "state", "field": key, "cmp": trigCmp, "value": trigValue]
        default:
            let cal = Calendar.current
            rule["trigger"] = ["type": "time", "hhmm": cal.component(.hour, from: time) * 60 + cal.component(.minute, from: time), "days": [Int]()]
        }
        // Condições (lista flexível: estado do carro e/ou passagem por locais).
        let items: [[String: Any]] = conditions.compactMap { c in
            if c.type == "visited" {
                let pts = c.placeIds.compactMap { id in places.first(where: { $0.id == id }) }
                    .map { ["lat": $0.lat, "lng": $0.lng, "radius_m": 30] as [String: Any] }
                guard !pts.isEmpty else { return nil }
                return ["type": "visited", "points": pts, "within_s": Int(c.withinMin * 60)]
            }
            if c.type == "time" {
                var d: [String: Any] = ["type": "time", "from_hhmm": c.fromMin, "to_hhmm": c.toMin]
                if !c.condDays.isEmpty { d["days"] = c.condDays.sorted() }
                return d
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
        delaySec = Double((e["delay_s"] as? Int) ?? 0)
        stableSec = Double((e["stable_s"] as? Int) ?? 0)
        repeatSec = Double((e["repeat_s"] as? Int) ?? 0)
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
                let key = (t["field"] as? String) ?? "car.basic.vehicle_speed"
                if condFields.contains(where: { $0.1 == key }) { trigField = key }
                else { trigField = "__custom__"; trigCustomKey = key }
                trigCmp = (t["cmp"] as? String) ?? ">="
                trigValue = (t["value"] as? String) ?? ""
            default: break
            }
        }
        if let cg = e["conditions"] as? [String: Any], let items = cg["items"] as? [[String: Any]] {
            condOp = (cg["op"] as? String) ?? "AND"
            conditions = items.map { it in
                var c = ObdCond()
                let t = (it["type"] as? String) ?? "compare"
                if t == "visited" {
                    c.type = "visited"
                    c.withinMin = Double(((it["within_s"] as? Int) ?? 300) / 60)
                    // Coords podem vir em points[] (multi) ou lat/lng (legado single).
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
                        places.min(by: { abs($0.lat - la) + abs($0.lng - ln) < abs($1.lat - la) + abs($1.lng - ln) })?.id
                    }
                } else if t == "time" {
                    c.type = "time"
                    c.fromMin = (it["from_hhmm"] as? Int) ?? 0
                    c.toMin = (it["to_hhmm"] as? Int) ?? 1439
                    c.condDays = Set((it["days"] as? [Int]) ?? [])
                } else {
                    c.type = (t == "recent") ? "recent" : "compare"
                    let key = (it["field"] as? String) ?? ""
                    if condFields.contains(where: { $0.1 == key }) { c.field = key }
                    else { c.field = "__custom__"; c.customKey = key }
                    c.cmp = (it["cmp"] as? String) ?? "=="
                    c.value = (it["value"] as? String) ?? ""
                    c.withinSec = Double((it["within_s"] as? Int) ?? 60)
                    c.negate = (it["negate"] as? Bool) ?? false
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

// ═══════════════════════════════════════════════════════════════════════════
//  Seletor de local pelo mapa — busca endereço, arrasta o mapa (pino central
//  fixo) ou centraliza no carro. Salva como Local Conhecido (/api/known-places).
// ═══════════════════════════════════════════════════════════════════════════
struct ObdPlacePickerView: View {
    @ObservedObject var store: ObdAutomationsStore
    let onSaved: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private static let fallback = CLLocationCoordinate2D(latitude: -16.6869, longitude: -49.2648) // Goiânia
    @State private var camera: MapCameraPosition = .region(MKCoordinateRegion(
        center: ObdPlacePickerView.fallback,
        span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)))
    @State private var center = ObdPlacePickerView.fallback
    @State private var query = ""
    @State private var name = ""
    @State private var radius = 30.0
    @State private var saving = false
    @State private var mapMode: MapMode = .map

    private enum MapMode: String, CaseIterable, Identifiable {
        case map = "Mapa", satellite = "Satélite"
        var id: String { rawValue }
        var style: MapStyle { self == .satellite ? .hybrid : .standard }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Map(position: $camera) {
                    // Desenha a área de cobertura do raio escolhido (atualiza ao vivo).
                    MapCircle(center: center, radius: radius)
                        .foregroundStyle(.blue.opacity(0.18))
                        .stroke(.blue.opacity(0.85), lineWidth: 2)
                }
                    .mapStyle(mapMode.style)
                    .onMapCameraChange(frequency: .continuous) { ctx in center = ctx.region.center }
                    .ignoresSafeArea(edges: .bottom)
                // Pino fixo no centro — arrastar o mapa move o ponto.
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 36)).foregroundStyle(.red)
                    .shadow(radius: 3).offset(y: -18).allowsHitTesting(false)
            }
            .safeAreaInset(edge: .top) {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Buscar endereço", text: $query)
                            .autocorrectionDisabled().submitLabel(.search)
                            .onSubmit { Task { await searchAddress() } }
                        Button { Task { await centerOnCar() } } label: {
                            Image(systemName: "car.fill")
                        }
                    }
                    .padding(10).background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    Picker("Estilo do mapa", selection: $mapMode) {
                        ForEach(MapMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                .padding()
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    TextField("Nome do local (ex: Portaria)", text: $name)
                        .textFieldStyle(.roundedBorder)
                    HStack { Text("Raio"); Slider(value: $radius, in: 5...300, step: 5); Text("\(Int(radius)) m").foregroundStyle(.secondary) }
                    Button {
                        Task {
                            saving = true
                            if let id = await store.addPlace(
                                name: name.trimmingCharacters(in: .whitespaces),
                                lat: center.latitude, lng: center.longitude, radius: radius), !id.isEmpty {
                                onSaved(id); dismiss()
                            }
                            saving = false
                        }
                    } label: {
                        Text(saving ? "Salvando…" : "Salvar local").bold().frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                }
                .padding().background(.regularMaterial)
            }
            .navigationTitle("Novo local").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } } }
            .task {
                if let c = await store.carLocation() { recenter(c, span: 0.01) }
            }
        }
    }

    private func recenter(_ c: CLLocationCoordinate2D, span: Double) {
        center = c
        camera = .region(MKCoordinateRegion(center: c, span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)))
    }
    private func searchAddress() async {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = query
        if let resp = try? await MKLocalSearch(request: req).start(), let item = resp.mapItems.first {
            recenter(item.placemark.coordinate, span: 0.005)
            if name.isEmpty { name = item.name ?? "" }
        }
    }
    private func centerOnCar() async {
        if let c = await store.carLocation() { recenter(c, span: 0.005) }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Gestão de locais de AUTOMAÇÃO (iPad) — lista independente da de recarga/trajeto.
// ═══════════════════════════════════════════════════════════════════════════
struct ObdPlacesManager: View {
    @ObservedObject var store: ObdAutomationsStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing: [String: Any]?

    var body: some View {
        NavigationStack {
            List {
                if store.places.isEmpty {
                    Text("Nenhum local de automação. Crie pelo botão \"Novo local pelo mapa\" na automação.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(store.places.indices, id: \.self) { i in
                    let p = store.places[i]
                    Button { editing = p } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text((p["name"] as? String) ?? "?").foregroundStyle(.primary)
                                Text("raio \(Int((p["radius_m"] as? Double) ?? 30)) m").font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            if let id = p["id"] as? String { Task { await store.deletePlace(id) } }
                        } label: { Label("Excluir", systemImage: "trash") }
                    }
                }
            }
            .navigationTitle("Locais de automação").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Concluído") { dismiss() } } }
            .sheet(item: ObdPlaceBox.binding($editing)) { box in ObdPlaceEditor(store: store, place: box.dict) }
            .task { await store.load() }
        }
    }
}

// Wrapper Identifiable pra usar [String:Any] em .sheet(item:).
private struct ObdPlaceBox: Identifiable {
    let id: String
    let dict: [String: Any]
    static func binding(_ b: Binding<[String: Any]?>) -> Binding<ObdPlaceBox?> {
        Binding(
            get: { b.wrappedValue.flatMap { d in (d["id"] as? String).map { ObdPlaceBox(id: $0, dict: d) } } },
            set: { if $0 == nil { b.wrappedValue = nil } }
        )
    }
}

struct ObdPlaceEditor: View {
    @ObservedObject var store: ObdAutomationsStore
    let place: [String: Any]
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var radius: Double
    @State private var camera: MapCameraPosition
    @State private var center: CLLocationCoordinate2D
    @State private var saving = false
    @State private var mapMode: MapMode = .map

    private enum MapMode: String, CaseIterable, Identifiable {
        case map = "Mapa", satellite = "Satélite"
        var id: String { rawValue }
        var style: MapStyle { self == .satellite ? .hybrid : .standard }
    }

    init(store: ObdAutomationsStore, place: [String: Any]) {
        self.store = store; self.place = place
        _name = State(initialValue: (place["name"] as? String) ?? "")
        _radius = State(initialValue: (place["radius_m"] as? Double) ?? 30)
        let c = CLLocationCoordinate2D(latitude: (place["lat"] as? Double) ?? -16.6869,
                                       longitude: (place["lng"] as? Double) ?? -49.2648)
        _center = State(initialValue: c)
        _camera = State(initialValue: .region(MKCoordinateRegion(center: c, span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))))
    }

    private var placeId: String { (place["id"] as? String) ?? "" }

    var body: some View {
        NavigationStack {
            ZStack {
                Map(position: $camera) {
                    // Desenha a área de cobertura do raio escolhido (atualiza ao vivo).
                    MapCircle(center: center, radius: radius)
                        .foregroundStyle(.blue.opacity(0.18))
                        .stroke(.blue.opacity(0.85), lineWidth: 2)
                }
                    .mapStyle(mapMode.style)
                    .onMapCameraChange(frequency: .continuous) { ctx in center = ctx.region.center }
                    .ignoresSafeArea(edges: .bottom)
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 36)).foregroundStyle(.red).shadow(radius: 3).offset(y: -18)
                    .allowsHitTesting(false)
            }
            .safeAreaInset(edge: .top) {
                Picker("Estilo do mapa", selection: $mapMode) {
                    ForEach(MapMode.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).padding()
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    TextField("Nome do local", text: $name).textFieldStyle(.roundedBorder)
                    HStack { Text("Raio"); Slider(value: $radius, in: 5...300, step: 5); Text("\(Int(radius)) m").foregroundStyle(.secondary) }
                    Button {
                        Task {
                            saving = true
                            await store.updatePlace(placeId, name: name.trimmingCharacters(in: .whitespaces),
                                lat: center.latitude, lng: center.longitude, radius: radius)
                            saving = false; dismiss()
                        }
                    } label: { Text(saving ? "Salvando…" : "Salvar alterações").bold().frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                }
                .padding().background(.regularMaterial)
            }
            .navigationTitle("Editar local").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } } }
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Referência de chaves do carro (iPad) — consulta + copiar pra montar automações.
// ═══════════════════════════════════════════════════════════════════════════
struct ObdCarKey: Identifiable {
    let key: String, label: String, values: String
    var id: String { key }
}

struct ObdCarKeysReference: View {
    @ObservedObject var store: ObdAutomationsStore
    @Environment(\.dismiss) private var dismiss
    @State private var keys: [ObdCarKey] = []
    @State private var query = ""
    @State private var copied: String?

    private var filtered: [ObdCarKey] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return keys }
        return keys.filter { $0.key.lowercased().contains(q) || $0.label.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                if keys.isEmpty { Text("Carregando chaves…").foregroundStyle(.secondary) }
                ForEach(filtered) { k in
                    Button {
                        UIPasteboard.general.string = k.key
                        copied = k.key
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(k.label).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: copied == k.key ? "checkmark.circle.fill" : "doc.on.doc")
                                    .font(.caption).foregroundStyle(copied == k.key ? .green : .secondary)
                            }
                            Text(k.key).font(.system(size: 12, design: .monospaced)).foregroundStyle(.blue)
                            Text(k.values).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Buscar chave ou descrição")
            .navigationTitle("Chaves do carro").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Concluído") { dismiss() } } }
            .overlay(alignment: .bottom) {
                if copied != nil {
                    Text("Chave copiada").font(.caption.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.regularMaterial).clipShape(Capsule()).padding(.bottom, 12)
                        .task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = nil }
                }
            }
            .task { if keys.isEmpty { keys = await store.loadCarKeys() } }
        }
    }
}
