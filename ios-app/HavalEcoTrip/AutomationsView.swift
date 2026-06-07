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
        case "automation": t = "Após outra automação"
        case "state": t = "Quando estado muda"
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
                RuleEditorSheet(cfg: cfg, existing: editing, allRules: loader.rules) { rule in
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
            Button { duplicate(r) } label: { Label("Duplicar", systemImage: "doc.on.doc") }
            Button(role: .destructive) { Task { await loader.delete(r.id) } } label: {
                Label("Excluir", systemImage: "trash")
            }
        }
    }

    // Abre o editor preenchido com uma CÓPIA da regra (sem id → salva como nova).
    // Útil pra criar uma automação complexa e variar só o local/uma condição.
    private func duplicate(_ r: AutoRule) {
        var copy = r.raw
        copy.removeValue(forKey: "id")
        copy.removeValue(forKey: "_updated_ms")
        copy["name"] = r.name + " (cópia)"
        copy["enabled"] = true
        editing = copy; showEditor = true
    }
}

// MARK: - Editor

struct RuleEditorSheet: View {
    @ObservedObject var cfg: ConfigStore
    let existing: [String: Any]?
    var allRules: [AutoRule] = []            // p/ o gatilho "Após automação"
    let onSave: ([String: Any]) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var trigKind = 0          // 0=chegar, 1=sair, 2=horário, 3=estado, 4=após automação
    @State private var afterRuleId = ""      // gatilho "automation"
    @State private var onlyIfSuccess = true
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
    @State private var delaySec = 0.0    // espera antes de executar a ação (s)
    @State private var stableSec = 0.0   // condição estável por X s antes de disparar
    @State private var repeatSec = 0.0   // repetir a ação a cada X s enquanto a condição durar
    @State private var conditions: [Cond] = []
    @State private var showPlacePicker = false
    @State private var pickerAutoSelectTrigger = false
    @State private var showPlacesManager = false
    @State private var showKeysRef = false
    @State private var carKeys: [CarKey] = []   // catálogo p/ autocomplete da chave custom

    struct Cond: Identifiable {
        let id = UUID()
        var type = "compare"     // "compare" | "recent" | "visited" | "time"
        var field = "car.basic.vehicle_speed"; var customKey = ""; var cmp = "=="; var value = ""
        var placeIds: [String] = []; var withinMin = 5.0   // "visited": 1+ locais (OU)
        var withinSec = 60.0; var negate = false   // "recent"
        var fromMin = 0; var toMin = 1439; var condDays: Set<Int> = []   // "time": faixa (min do dia) + dias
    }

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
    private let winTargets = ["Motorista", "Passageiro", "Tras. esq.", "Tras. dir.", "Todas"]
    private let weekdays = ["D", "S", "T", "Q", "Q", "S", "S"]

    // Modelos prontos (só ao criar). Tocar preenche o formulário; o usuário revisa e salva.
    struct RuleTemplate: Identifiable { let id: Int; let group: String; let icon: String; let title: String; let desc: String }
    static let templateGroups = ["Conforto", "Chuva", "Energia / EV", "Recarga", "Segurança"]
    private let templates: [RuleTemplate] = [
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
            conditions = [Cond(type: "compare", field: "car.basic.vehicle_speed", cmp: "==", value: "0")]
            actKind = 3; advKey = "car.hvac.ac_enable"; advValue = "0"; debounce = 900
        case 2:
            name = "Fechar vidros ao sair"
            trigKind = 1; radius = 50
            actKind = 0; winTarget = 4; winOpen = false
        case 3:
            name = "Fechar teto andando"
            trigKind = 3; trigField = "car.basic.vehicle_speed"; trigCmp = ">="; trigValue = "10"
            conditions = [Cond(type: "compare", field: "__custom__", customKey: "car.basic.sunroof_status", cmp: ">", value: "0")]
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
            conditions = [Cond(type: "compare", field: "__custom__", customKey: "car.basic.outside_temp", cmp: "<", value: "10")]
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
            conditions = [Cond(type: "compare", field: "__custom__", customKey: "car.basic.outside_temp", cmp: "<", value: "5")]
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
            conditions = [Cond(type: "compare", field: "__custom__", customKey: "car.basic.sunroof_status", cmp: ">", value: "0")]
            actKind = 1
        case 14:
            name = "Limpador → fechar teto"
            trigKind = 3; trigField = "car.basic.front_wipwer_status"; trigCmp = ">"; trigValue = "0"
            conditions = [Cond(type: "compare", field: "__custom__", customKey: "car.basic.sunroof_status", cmp: ">", value: "0")]
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
            conditions = [Cond(type: "compare", field: "car.basic.vehicle_speed", cmp: ">", value: "0")]
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
            conditions = [Cond(type: "compare", field: "__custom__", customKey: "car.hvac.ac_enable", cmp: "==", value: "1")]
            actKind = 3; advKey = "car.comfort_setting.passenger_seat_ventilation_level"; advValue = "3"
        case 23:
            name = "Desligar vent. passageiro"
            trigKind = 3; trigField = "car.basic.seated_state[1]"; trigCmp = "=="; trigValue = "0"
            actKind = 3; advKey = "car.comfort_setting.passenger_seat_ventilation_level"; advValue = "0"
        default: break
        }
    }
    // Automação usa SÓ a lista de locais de automação — independente dos conhecidos
    // (recarga/trajeto), que ficam em Config › Locais conhecidos.
    private var allPlaces: [KnownPlace] { cfg.automationPlaces }

    var body: some View {
        NavigationStack {
            Form {
                if existing == nil {
                    ForEach(Self.templateGroups, id: \.self) { g in
                        Section(g == Self.templateGroups.first ? "Modelos · \(g)" : g) {
                            ForEach(templates.filter { $0.group == g }) { t in
                                Button { applyTemplate(t.id) } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: t.icon).frame(width: 26).foregroundStyle(DS.green)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(t.title).foregroundStyle(DS.text)
                                            Text(t.desc).font(.caption).foregroundStyle(DS.muted)
                                        }
                                        Spacer()
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                Section("Nome") {
                    TextField("Ex: Cortina na portaria", text: $name)
                }

                quandoSection
                fazerSection
                condicoesSection
                locaisSection
                avancadoSection
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
            .task { if carKeys.isEmpty { carKeys = await cfg.loadCarKeys() } }
            .sheet(isPresented: $showPlacePicker) {
                PlaceMapPicker(cfg: cfg) { newId in
                    if pickerAutoSelectTrigger { placeId = newId }
                }
            }
            .sheet(isPresented: $showPlacesManager) {
                AutomationPlacesManager(cfg: cfg)
            }
            .sheet(isPresented: $showKeysRef) { CarKeysReference(cfg: cfg) }
        }
    }

    @ViewBuilder private var quandoSection: some View {
                Section("Quando") {
                    Picker("Gatilho", selection: $trigKind) {
                        Text("Chegar").tag(0); Text("Sair").tag(1); Text("Horário").tag(2)
                        Text("Estado").tag(3); Text("Após").tag(4)
                    }.pickerStyle(.menu)

                    if trigKind == 4 {
                        if allRules.isEmpty {
                            Text("Crie outra automação primeiro pra poder encadear.")
                                .font(.caption).foregroundStyle(.orange)
                        } else {
                            Picker("Após executar", selection: $afterRuleId) {
                                Text("Selecione…").tag("")
                                ForEach(allRules.filter { $0.id != (existing?["id"] as? String) }) { r in
                                    Text(r.name).tag(r.id)
                                }
                            }
                            Toggle("Só se executou com sucesso", isOn: $onlyIfSuccess)
                            Text("Dispara depois que a automação escolhida executar. Use o Atraso (Avançado) pra esperar antes, e Condições pra exigir algo (ex: velocidade ≥ 10).")
                                .font(.caption).foregroundStyle(DS.muted)
                        }
                    } else if trigKind <= 1 {
                        if allPlaces.isEmpty {
                            Text("Cadastre um local de automação primeiro (botão \"Novo local pelo mapa\" abaixo).")
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
                            // Autocomplete: filtra o catálogo de chaves conforme digita.
                            let tq = trigCustomKey.lowercased()
                            if !tq.isEmpty, !carKeys.contains(where: { $0.key == trigCustomKey }) {
                                ForEach(Array(carKeys.filter { $0.key.lowercased().contains(tq) || $0.label.lowercased().contains(tq) }.prefix(6))) { k in
                                    Button { trigCustomKey = k.key } label: {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(k.label).font(.caption).foregroundStyle(DS.text)
                                            Text(k.key).font(.system(size: 11, design: .monospaced)).foregroundStyle(DS.green)
                                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                }
                            }
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
    }

    @ViewBuilder private var fazerSection: some View {
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
                                                    Text(k.label).font(.caption).foregroundStyle(DS.text)
                                                    Text(k.key).font(.system(size: 11, design: .monospaced)).foregroundStyle(DS.green)
                                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                            }.buttonStyle(.plain)
                                        }
                                    }
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
                                            Text(weekdays[d]).font(.system(size: 13, weight: .bold)).frame(maxWidth: .infinity).frame(height: 32)
                                                .foregroundStyle(on ? .black : DS.text).background(on ? DS.green : DS.panel2).clipShape(RoundedRectangle(cornerRadius: 7))
                                        }.buttonStyle(.borderless)
                                    }
                                }
                                Text("Vazio = todo dia. Passa se o horário atual estiver na faixa (e no dia, se marcado).")
                                    .font(.caption2).foregroundStyle(DS.muted)
                            } else {
                                Text("Passou por QUALQUER um (selecione 1+):").font(.caption).foregroundStyle(DS.muted)
                                ForEach(allPlaces) { p in
                                    // Mutação por assignment explícito + .plain: mutar
                                    // $c.placeIds.wrappedValue.append num ForEach($binding)
                                    // aninhado crashava o app ao tocar no local.
                                    Button {
                                        var ids = c.placeIds
                                        if let i = ids.firstIndex(of: p.id) { ids.remove(at: i) }
                                        else { ids.append(p.id) }
                                        $c.placeIds.wrappedValue = ids
                                    } label: {
                                        HStack {
                                            Image(systemName: c.placeIds.contains(p.id) ? "checkmark.circle.fill" : "circle")
                                                .foregroundStyle(c.placeIds.contains(p.id) ? DS.green : DS.muted)
                                            Text(p.name).foregroundStyle(DS.text)
                                            Spacer()
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                                HStack { Text("Há no máximo"); Slider(value: $c.withinMin, in: 1...60, step: 1); Text("\(Int(c.withinMin)) min").foregroundStyle(DS.muted) }
                            }
                            // Remover por id (não por offset): swipe-to-delete com
                            // ForEach($binding) + conteúdo complexo crashava o app.
                            // .borderless: sem isso, num Form os vários botões da row
                            // compartilham a área de toque (clicar em "Remover" acionava
                            // o picker de chave). Cada botão vira alvo independente.
                            Button(role: .destructive) {
                                let cid = c.id
                                conditions.removeAll { $0.id == cid }
                            } label: { Label("Remover condição", systemImage: "trash").font(.caption) }
                            .buttonStyle(.borderless)
                        }
                    }
                    Button { conditions.append(Cond()) } label: { Label("Adicionar condição", systemImage: "plus") }
                        .buttonStyle(.borderless)
                    Button { pickerAutoSelectTrigger = false; showPlacePicker = true } label: {
                        Label("Novo local pelo mapa", systemImage: "mappin.and.ellipse")
                    }.buttonStyle(.borderless)
                } header: { Text("Condições (opcional)") }
                  footer: { Text("Tudo precisa ser verdadeiro no gatilho (ou qualquer um, se OU).") }

    }

    @ViewBuilder private var locaisSection: some View {
                Section {
                    Button { showPlacesManager = true } label: {
                        Label("Gerenciar locais de automação", systemImage: "mappin.and.ellipse")
                    }
                    Button { showKeysRef = true } label: {
                        Label("Chaves do carro (referência)", systemImage: "list.bullet.rectangle")
                    }
                } footer: {
                    Text("Renomeie, ajuste o raio/posição ou remova os locais (lista independente da de recarga/trajeto). \"Chaves do carro\" lista os campos disponíveis pra usar nas condições/ações — toque pra copiar.")
                }
    }

    @ViewBuilder private var avancadoSection: some View {
                Section {
                    HStack { Text("Esperar antes de executar"); Slider(value: $delaySec, in: 0...300, step: 5); Text("\(Int(delaySec))s").foregroundStyle(DS.muted) }
                    HStack { Text("Condição estável por"); Slider(value: $stableSec, in: 0...120, step: 5); Text("\(Int(stableSec))s").foregroundStyle(DS.muted) }
                    HStack { Text("Repetir enquanto valer"); Slider(value: $repeatSec, in: 0...600, step: 10); Text(repeatSec > 0 ? "\(Int(repeatSec))s" : "não").foregroundStyle(DS.muted) }
                    HStack { Text("Intervalo mínimo"); Slider(value: $debounce, in: 0...600, step: 30); Text("\(Int(debounce))s").foregroundStyle(DS.muted) }
                } header: { Text("Avançado") }
                  footer: { Text("Esperar: aguarda após o gatilho e revalida a condição antes de executar. Estável por: a condição (gatilho de estado) precisa durar esse tempo antes de disparar. Repetir: reexecuta a ação nesse intervalo enquanto a condição continuar verdadeira. Intervalo mínimo: tempo entre disparos.") }
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
        case 4:
            rule["trigger"] = ["type": "automation", "after_rule_id": afterRuleId, "only_if_success": onlyIfSuccess]
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

        onSave(rule)
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
            case "automation":
                trigKind = 4
                afterRuleId = (t["after_rule_id"] as? String) ?? ""
                onlyIfSuccess = (t["only_if_success"] as? Bool) ?? true
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
                } else if t == "time" {
                    c.type = "time"
                    c.fromMin = (it["from_hhmm"] as? Int) ?? 0
                    c.toMin = (it["to_hhmm"] as? Int) ?? 1439
                    c.condDays = Set((it["days"] as? [Int]) ?? [])
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
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 36)).foregroundStyle(.red).shadow(radius: 3).offset(y: -18)
                    .allowsHitTesting(false)
            }
            .safeAreaInset(edge: .top) {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Buscar endereço", text: $query)
                            .autocorrectionDisabled().submitLabel(.search)
                            .onSubmit { Task { await search() } }
                        Button { centerOnCar() } label: { Image(systemName: "car.fill") }
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

// MARK: - Gestão de locais de AUTOMAÇÃO (lista independente da de recarga/trajeto)
struct AutomationPlacesManager: View {
    @ObservedObject var cfg: ConfigStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing: KnownPlace?

    var body: some View {
        NavigationStack {
            List {
                if cfg.automationPlaces.isEmpty {
                    Text("Nenhum local de automação. Crie pelo botão \"Novo local pelo mapa\" na automação.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(cfg.automationPlaces) { p in
                    Button { editing = p } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).foregroundStyle(.primary)
                                Text("raio \(Int(p.radiusM)) m").font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
                .onDelete { idx in
                    let ids = idx.map { cfg.automationPlaces[$0].id }
                    Task { for id in ids { await cfg.deleteAutomationPlace(id) } }
                }
            }
            .navigationTitle("Locais de automação").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Concluído") { dismiss() } }
            }
            .sheet(item: $editing) { p in AutomationPlaceEditor(cfg: cfg, place: p) }
            .task { await cfg.loadAutomationPlaces() }
        }
    }
}

struct AutomationPlaceEditor: View {
    @ObservedObject var cfg: ConfigStore
    let place: KnownPlace
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

    init(cfg: ConfigStore, place: KnownPlace) {
        self.cfg = cfg; self.place = place
        _name = State(initialValue: place.name)
        _radius = State(initialValue: place.radiusM)
        let c = CLLocationCoordinate2D(latitude: place.lat, longitude: place.lng)
        _center = State(initialValue: c)
        _camera = State(initialValue: .region(MKCoordinateRegion(center: c, span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))))
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
                            await cfg.updateAutomationPlace(place.id, name: name.trimmingCharacters(in: .whitespaces),
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

// MARK: - Referência de chaves do carro (consulta + copiar pra montar automações)
struct CarKeysReference: View {
    @ObservedObject var cfg: ConfigStore
    @Environment(\.dismiss) private var dismiss
    @State private var keys: [CarKey] = []
    @State private var query = ""
    @State private var copied: String?

    private var filtered: [CarKey] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return keys }
        return keys.filter { $0.key.lowercased().contains(q) || $0.label.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                if keys.isEmpty {
                    Text("Carregando chaves…").foregroundStyle(.secondary)
                }
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
            .listStyle(.plain)
            .searchable(text: $query, prompt: "Buscar chave ou descrição")
            .navigationTitle("Chaves do carro").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Concluído") { dismiss() } } }
            .overlay(alignment: .bottom) {
                if copied != nil {
                    Text("Chave copiada").font(.caption.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.regularMaterial).clipShape(Capsule()).padding(.bottom, 12)
                        .task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = nil }
                }
            }
            .task { if keys.isEmpty { keys = await cfg.loadCarKeys() } }
        }
    }
}
