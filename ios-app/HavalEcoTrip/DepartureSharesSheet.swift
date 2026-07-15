//
//  DepartureSharesSheet.swift
//  Config de "Saídas monitoradas": cada entrada é um par (Origem, Destino, Dias,
//  Janela) que gera 2 automation_rules no bridge com o mesmo `_group` marker:
//    • Ao sair da origem → notify template=traffic_delay (LA da Grasi ganha
//      delayMin no cs). NÃO cria share sozinho — só se o Rafael compartilhar
//      manualmente antes.
//    • Ao chegar no destino → notify template=arrived_home (encerra a LA
//      da Grasi se ela estiver ativa).
//
//  Reaproveita RulesLoader/SyncedList do AutomationsView. Multi-config sem
//  mexer em código (adiciona quantos pares quiser via wizard).
//

import SwiftUI

// MARK: - Modelo agrupado (2 rules com mesmo _group)

struct DepartureConfig: Identifiable {
    var groupId: String                  // uuid extraído de _group="departure_share:<uuid>"
    var sourceName: String; var sourceLat: Double; var sourceLng: Double; var sourceRadius: Double
    var destName: String;   var destLat: Double;   var destLng: Double;   var destRadius: Double
    var days: Set<Int>                   // 0=Dom..6=Sáb
    var fromHhmm: Int                    // início da janela (min do dia)
    var untilHhmm: Int                   // fim da janela
    var exitRuleId: String?              // ids das rules geradas (pra edit/delete)
    var enterRuleId: String?
    var enabled: Bool
    var id: String { groupId }
}

// MARK: - Sheet principal (lista + botão nova)

struct DepartureSharesSheet: View {
    @ObservedObject var cfg: ConfigStore
    @StateObject private var loader = RulesLoader()
    @Environment(\.dismiss) private var dismiss

    @State private var editing: DepartureConfig? = nil
    @State private var baselineEnabled = true
    @State private var baselineEntries = 0
    @State private var baselinePairs = 0
    @State private var baselineCostUsd = 0.0

    // Merge automation_places + known_places pra o dropdown (Casa mora em
    // known_places; Limpa Gyn em automation_places). Dedup por lat/lng arredondado.
    private var allPlaces: [KnownPlace] {
        var seen = Set<String>(); var out: [KnownPlace] = []
        for p in cfg.places + cfg.automationPlaces {
            let k = String(format: "%.4f,%.4f", p.lat, p.lng)
            if !seen.contains(k) { seen.insert(k); out.append(p) }
        }
        return out.sorted { $0.name < $1.name }
    }

    private var configs: [DepartureConfig] {
        let byGroup = Dictionary(grouping: loader.rules) { r -> String in
            (r.raw["_group"] as? String) ?? ""
        }
        return byGroup.compactMap { gid, rules -> DepartureConfig? in
            guard gid.hasPrefix("departure_share:") else { return nil }
            let exit = rules.first { ($0.raw["trigger"] as? [String:Any])?["edge"] as? String == "exit" }
            let enter = rules.first { ($0.raw["trigger"] as? [String:Any])?["edge"] as? String == "enter" }
            guard let e = exit else { return nil }
            let et = (e.raw["trigger"] as? [String:Any]) ?? [:]
            let ea = (e.raw["action"] as? [String:Any]) ?? [:]
            let to = (ea["to"] as? [String:Any]) ?? [:]
            let cond = ((e.raw["conditions"] as? [String:Any])?["items"] as? [[String:Any]])?
                .first { ($0["type"] as? String) == "time" } ?? [:]
            let uuid = String(gid.dropFirst("departure_share:".count))
            let nt = (enter?.raw["trigger"] as? [String:Any]) ?? [:]
            return DepartureConfig(
                groupId: uuid,
                sourceName: sourceNameFor(lat: et["lat"] as? Double ?? 0, lng: et["lng"] as? Double ?? 0, fallback: (et["name"] as? String) ?? "Origem"),
                sourceLat: (et["lat"] as? Double) ?? 0,
                sourceLng: (et["lng"] as? Double) ?? 0,
                sourceRadius: (et["radius_m"] as? Double) ?? 50,
                destName: sourceNameFor(lat: to["lat"] as? Double ?? nt["lat"] as? Double ?? 0,
                                        lng: to["lng"] as? Double ?? nt["lng"] as? Double ?? 0,
                                        fallback: "Destino"),
                destLat: (to["lat"] as? Double) ?? (nt["lat"] as? Double) ?? 0,
                destLng: (to["lng"] as? Double) ?? (nt["lng"] as? Double) ?? 0,
                destRadius: (nt["radius_m"] as? Double) ?? 50,
                days: Set((cond["days"] as? [Int]) ?? []),
                fromHhmm: (cond["from_hhmm"] as? Int) ?? 990,
                untilHhmm: (cond["to_hhmm"] as? Int) ?? 1200,
                exitRuleId: e.id, enterRuleId: enter?.id,
                enabled: e.enabled && (enter?.enabled ?? true)
            )
        }.sorted { $0.sourceName < $1.sourceName }
    }

    private func sourceNameFor(lat: Double, lng: Double, fallback: String) -> String {
        allPlaces.first { abs($0.lat - lat) < 0.0005 && abs($0.lng - lng) < 0.0005 }?.name ?? fallback
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    Button {
                        editing = DepartureConfig(groupId: UUID().uuidString.lowercased(),
                                                  sourceName: "", sourceLat: 0, sourceLng: 0, sourceRadius: 50,
                                                  destName: "", destLat: 0, destLng: 0, destRadius: 50,
                                                  days: [1,2,3,4,5], fromHhmm: 990, untilHhmm: 1200,
                                                  exitRuleId: nil, enterRuleId: nil, enabled: true)
                    } label: {
                        Label("Nova saída monitorada", systemImage: "plus.circle.fill")
                            .font(.system(size: 15, weight: .bold)).foregroundStyle(.black)
                            .frame(maxWidth: .infinity).frame(height: 46)
                            .background(DS.green).clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    if configs.isEmpty && !loader.loading {
                        VStack(spacing: 6) {
                            Text("Nenhuma saída monitorada.")
                                .font(.subheadline).foregroundStyle(DS.muted)
                            Text("Cadastre um local de origem + destino. Quando você sair, o bridge calcula ETA vs histórico. Se você compartilhar o trajeto, a Grasi vê o atraso na LA do Grasi Recarga.")
                                .font(.caption).foregroundStyle(DS.muted).multilineTextAlignment(.center)
                        }.padding(.top, 30)
                    }
                    ForEach(configs) { c in card(c) }
                    baselineFooter
                }.padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .overlay { if loader.loading && configs.isEmpty { ProgressView().tint(DS.green) } }
            .navigationTitle("Saídas monitoradas").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Concluído") { dismiss() } } }
            .sheet(item: $editing) { c in
                DepartureEditorSheet(cfg: cfg, initial: c, allPlaces: allPlaces) { saved in
                    Task { await save(saved) }
                }
            }
            .task { await cfg.loadPlaces(); await cfg.loadAutomationPlaces(); await loader.load(); await refreshBaselineStatus() }
        }
    }

    // Footer: status do scanner preditivo (baseline pré-calculado por hora) +
    // toggle pra ligar/desligar. Sem custo extra se você desliga.
    private var baselineFooter: some View {
        DSCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Baseline pré-calculado").font(.system(size: 14, weight: .semibold))
                        Text("Consulta Google Directions periódico p/ cada saída acima. Custo ~$0.01/chamada.").font(.caption).foregroundStyle(DS.muted)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { baselineEnabled }, set: { on in Task { await setBaseline(on) } })).labelsHidden().tint(DS.green)
                }
                if baselineEnabled {
                    HStack(spacing: 8) {
                        Label("\(baselineEntries) amostras", systemImage: "chart.bar.doc.horizontal").font(.caption)
                        Label("\(baselinePairs) pares", systemImage: "arrow.left.and.right").font(.caption)
                        Label(String(format: "$%.2f hoje", baselineCostUsd), systemImage: "dollarsign.circle").font(.caption)
                    }.foregroundStyle(DS.muted)
                }
            }
        }
    }

    private func refreshBaselineStatus() async {
        let base = BridgeRouter.shared.currentURL
        guard let u = URL(string: "\(base)/api/baseline-status") else { return }
        var r = URLRequest(url: u); r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization"); r.timeoutInterval = 6
        guard let (d, _) = try? await URLSession.shared.data(for: r) else { return }
        guard let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return }
        baselineEnabled = (j["enabled"] as? Bool) ?? true
        baselineEntries = (j["entries"] as? Int) ?? 0
        baselinePairs = (j["pairs"] as? Int) ?? 0
        let cost = (j["cost_today"] as? [String: Any])?["cost_usd"] as? Double ?? 0
        baselineCostUsd = cost
    }

    private func setBaseline(_ on: Bool) async {
        baselineEnabled = on  // otimista
        let base = BridgeRouter.shared.currentURL
        guard let u = URL(string: "\(base)/api/push/prefs") else { return }
        var r = URLRequest(url: u); r.httpMethod = "POST"
        r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        r.addValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["key": "baseline_predictive", "value": on])
        _ = try? await URLSession.shared.data(for: r)
        await refreshBaselineStatus()
    }

    private func card(_ c: DepartureConfig) -> some View {
        DSCard {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right.circle.fill").foregroundStyle(DS.blue)
                        Text(c.sourceName).font(.system(size: 15, weight: .semibold))
                        Text("→").foregroundStyle(DS.muted)
                        Image(systemName: "house.fill").foregroundStyle(DS.teal)
                        Text(c.destName).font(.system(size: 15, weight: .semibold))
                    }
                    Text(summary(c)).font(.caption).foregroundStyle(DS.muted).lineLimit(2)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { c.enabled }, set: { on in Task { await toggle(c, on: on) } }))
                    .labelsHidden().tint(DS.green)
            }
            .contentShape(Rectangle())
            .onTapGesture { editing = c }
        }
        .contextMenu {
            Button(role: .destructive) { Task { await delete(c) } } label: { Label("Excluir", systemImage: "trash") }
        }
    }

    private func summary(_ c: DepartureConfig) -> String {
        let dstr = daysAbbrev(c.days)
        return "\(dstr) · \(hhmmStr(c.fromHhmm))–\(hhmmStr(c.untilHhmm))"
    }
    private func hhmmStr(_ m: Int) -> String { String(format: "%02d:%02d", m/60, m%60) }
    private func daysAbbrev(_ s: Set<Int>) -> String {
        if s.isEmpty { return "Todos os dias" }
        if s == [1,2,3,4,5] { return "Seg–Sex" }
        if s == [0,1,2,3,4,5,6] { return "Todos os dias" }
        let names = ["Dom","Seg","Ter","Qua","Qui","Sex","Sáb"]
        return s.sorted().map { names[$0] }.joined(separator: ", ")
    }

    // MARK: - Persistência (gera 2 rules com _group marker)

    private func save(_ c: DepartureConfig) async {
        let group = "departure_share:\(c.groupId)"
        let exit: [String: Any] = [
            "id": c.exitRuleId ?? "rule_dep_\(c.groupId)_exit",
            "name": "Saindo — \(c.sourceName) → \(c.destName)",
            "enabled": c.enabled,
            "_group": group,
            "trigger": ["type": "geofence", "lat": c.sourceLat, "lng": c.sourceLng,
                        "radius_m": c.sourceRadius, "edge": "exit"],
            "conditions": ["op": "AND", "items": [
                ["type": "time", "from_hhmm": c.fromHhmm, "to_hhmm": c.untilHhmm,
                 "days": Array(c.days).sorted()]
            ]],
            "action": ["type": "notify", "template": "traffic_delay", "channel": "la",
                       "subject": "Rafael",
                       "from": ["lat": c.sourceLat, "lng": c.sourceLng, "name": c.sourceName],
                       "to": ["lat": c.destLat, "lng": c.destLng, "name": c.destName],
                       "baseline_min": 27, "threshold_min": 10],
            "debounce_s": 1800
        ]
        let enter: [String: Any] = [
            "id": c.enterRuleId ?? "rule_dep_\(c.groupId)_enter",
            "name": "Chegando — \(c.destName)",
            "enabled": c.enabled,
            "_group": group,
            "trigger": ["type": "geofence", "lat": c.destLat, "lng": c.destLng,
                        "radius_m": c.destRadius, "edge": "enter"],
            "conditions": ["op": "AND", "items": [
                ["type": "time", "from_hhmm": c.fromHhmm, "to_hhmm": 1439]
            ]],
            "action": ["type": "notify", "template": "arrived_home", "channel": "la",
                       "subject": "Rafael"],
            "debounce_s": 14400
        ]
        await loader.upsert(exit)
        await loader.upsert(enter)
    }

    private func toggle(_ c: DepartureConfig, on: Bool) async {
        var flipped = c; flipped.enabled = on; await save(flipped)
    }

    private func delete(_ c: DepartureConfig) async {
        if let id = c.exitRuleId { await loader.delete(id) }
        if let id = c.enterRuleId { await loader.delete(id) }
    }
}

// MARK: - Editor

struct DepartureEditorSheet: View {
    @ObservedObject var cfg: ConfigStore
    let allPlaces: [KnownPlace]
    let onSave: (DepartureConfig) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var conf: DepartureConfig
    @State private var fromTime: Date
    @State private var untilTime: Date
    private let weekdays = ["D", "S", "T", "Q", "Q", "S", "S"]

    init(cfg: ConfigStore, initial: DepartureConfig, allPlaces: [KnownPlace], onSave: @escaping (DepartureConfig) -> Void) {
        self.cfg = cfg; self.allPlaces = allPlaces; self.onSave = onSave
        _conf = State(initialValue: initial)
        let cal = Calendar.current
        _fromTime = State(initialValue: cal.date(bySettingHour: initial.fromHhmm/60, minute: initial.fromHhmm%60, second: 0, of: Date()) ?? Date())
        _untilTime = State(initialValue: cal.date(bySettingHour: initial.untilHhmm/60, minute: initial.untilHhmm%60, second: 0, of: Date()) ?? Date())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Origem") {
                    Picker("Local de saída", selection: Binding(get: { placeKey(conf.sourceLat, conf.sourceLng) }, set: setSource)) {
                        Text("Escolha…").tag("")
                        ForEach(allPlaces) { p in Text(p.name).tag(placeKey(p.lat, p.lng)) }
                    }
                }
                Section("Destino") {
                    Picker("Local de chegada", selection: Binding(get: { placeKey(conf.destLat, conf.destLng) }, set: setDest)) {
                        Text("Escolha…").tag("")
                        ForEach(allPlaces) { p in Text(p.name).tag(placeKey(p.lat, p.lng)) }
                    }
                }
                Section("Janela") {
                    DatePicker("De", selection: $fromTime, displayedComponents: .hourAndMinute)
                        .onChange(of: fromTime) { syncHhmm() }
                    DatePicker("Até", selection: $untilTime, displayedComponents: .hourAndMinute)
                        .onChange(of: untilTime) { syncHhmm() }
                    HStack(spacing: 6) {
                        ForEach(0..<7, id: \.self) { d in
                            let on = conf.days.contains(d)
                            Text(weekdays[d]).font(.system(size: 13, weight: .bold))
                                .frame(width: 32, height: 32)
                                .background(on ? DS.green : DS.panel2).foregroundStyle(on ? .black : DS.text)
                                .clipShape(Circle())
                                .onTapGesture { if on { conf.days.remove(d) } else { conf.days.insert(d) } }
                        }
                    }
                    Text(conf.days.isEmpty ? "Escolha ao menos um dia" : "").font(.caption).foregroundStyle(DS.muted)
                }
                Section {
                    Text("Quando você sair da origem nessa janela, o bridge calcula seu ETA histórico do mesmo dia da semana. Se você compartilhar o trajeto com a Grasi (manual), a LA dela mostra o atraso em tempo real.")
                        .font(.caption).foregroundStyle(DS.muted)
                }
            }
            .navigationTitle(conf.exitRuleId == nil ? "Nova saída" : "Editar saída")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar") { onSave(conf); dismiss() }
                        .disabled(conf.sourceLat == 0 || conf.destLat == 0 || conf.days.isEmpty)
                }
            }
        }
    }

    private func placeKey(_ lat: Double, _ lng: Double) -> String { String(format: "%.4f,%.4f", lat, lng) }
    private func setSource(_ k: String) {
        guard let p = allPlaces.first(where: { placeKey($0.lat, $0.lng) == k }) else { return }
        conf.sourceName = p.name; conf.sourceLat = p.lat; conf.sourceLng = p.lng; conf.sourceRadius = p.radiusM
    }
    private func setDest(_ k: String) {
        guard let p = allPlaces.first(where: { placeKey($0.lat, $0.lng) == k }) else { return }
        conf.destName = p.name; conf.destLat = p.lat; conf.destLng = p.lng; conf.destRadius = p.radiusM
    }
    private func syncHhmm() {
        let cal = Calendar.current
        conf.fromHhmm = cal.component(.hour, from: fromTime)*60 + cal.component(.minute, from: fromTime)
        conf.untilHhmm = cal.component(.hour, from: untilTime)*60 + cal.component(.minute, from: untilTime)
    }
}
