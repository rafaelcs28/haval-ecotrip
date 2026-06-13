//
//  PreclimatSheet.swift
//  Pré-climatização — agendamentos (igual ao PWA). GET /api/preclimat,
//  POST /api/preclimat/schedule (cria sem id / atualiza com id), DELETE.
//

import SwiftUI

struct PreclimatSched: Identifiable {
    let id: String
    var enabled: Bool
    var time: String        // "HH:MM"
    var recurrence: String  // once | daily | weekdays | weekends
    var temp: Double        // 16–32
    var fan: Int            // 1–7
    var duration: Int       // 0–180 min

    init(_ r: [String: Any]) {
        id = (r["id"] as? String) ?? UUID().uuidString
        enabled = (r["enabled"] as? Bool) ?? true
        time = (r["time"] as? String) ?? "07:30"
        recurrence = (r["recurrence"] as? String) ?? "daily"
        temp = anyD(r["temp"]) == 0 ? 22 : anyD(r["temp"])
        fan = Int(anyD(r["fan"])); if fan < 1 { fan = 3 }
        duration = Int(anyD(r["duration"])); if duration == 0 { duration = 20 }
    }
}
private func anyD(_ v: Any?) -> Double {
    switch v { case let d as Double: return d; case let i as Int: return Double(i)
    case let n as NSNumber: return n.doubleValue; case let s as String: return Double(s) ?? 0; default: return 0 }
}

@MainActor
final class PreclimatStore: ObservableObject {
    @Published var scheds: [PreclimatSched] = []
    @Published var loading = false

    private var base: String {
        let u = Settings.bridgeURL.isEmpty ? AuthConfig.bridgeURL : Settings.bridgeURL
        return u.hasSuffix("/") ? String(u.dropLast()) : u
    }
    private func req(_ path: String, _ method: String, _ body: [String: Any]? = nil) -> URLRequest? {
        guard let url = URL(string: "\(base)\(path)") else { return nil }
        var r = URLRequest(url: url); r.httpMethod = method; r.timeoutInterval = 12
        r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        if let body { r.addValue("application/json", forHTTPHeaderField: "Content-Type"); r.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        return r
    }

    func load() async {
        guard Settings.isConfigured, let r = req("/api/preclimat", "GET") else { return }
        loading = true
        defer { loading = false }
        guard let (data, resp) = try? await URLSession.shared.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["schedules"] as? [[String: Any]] else { return }
        scheds = arr.map(PreclimatSched.init)
    }

    func add() async {
        guard let r = req("/api/preclimat/schedule", "POST", ["device_id": ""]) else { return }
        guard let (data, _) = try? await URLSession.shared.data(for: r),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        scheds.append(PreclimatSched(obj))
    }

    // Cria um agendamento já com horário e temperatura (sugestão inteligente).
    func addAt(time: String, temp: Double) async {
        guard let r = req("/api/preclimat/schedule", "POST",
                          ["device_id": "", "time": time, "temp": temp, "enabled": true]) else { return }
        _ = try? await URLSession.shared.data(for: r)
        await load()
    }

    func update(_ id: String, _ field: String, _ value: Any) async {
        guard let r = req("/api/preclimat/schedule", "POST", ["id": id, field: value, "device_id": ""]) else { return }
        _ = try? await URLSession.shared.data(for: r)
    }

    func remove(_ id: String) async {
        scheds.removeAll { $0.id == id }
        guard let r = req("/api/preclimat/schedule/\(id)", "DELETE") else { return }
        _ = try? await URLSession.shared.data(for: r)
    }
}

struct PreclimatSheet: View {
    @StateObject private var store = PreclimatStore()
    @ObservedObject private var trips = TripsLoader.shared
    @ObservedObject private var car = CarStore.shared
    @Environment(\.dismiss) private var dismiss

    // Horário típico de saída (mediana das viagens de manhã em dias úteis), em minutos.
    private var typicalDeparture: Int? {
        let cal = Calendar.current
        let mins = trips.trips.compactMap { t -> Int? in
            let wd = cal.component(.weekday, from: t.date)
            guard (2...6).contains(wd) else { return nil }   // seg–sex
            let h = cal.component(.hour, from: t.date), m = cal.component(.minute, from: t.date)
            guard h >= 4 && h <= 12 else { return nil }       // manhã
            return h * 60 + m
        }
        guard mins.count >= 4 else { return nil }
        let s = mins.sorted(); return s[s.count / 2]
    }

    // Sugestão: só quando não há agendamento, há rotina e a temperatura justifica.
    private var suggestion: (time: String, temp: Double, why: String)? {
        guard store.scheds.isEmpty, let dep = typicalDeparture else { return nil }
        let t = car.outsideTemp
        let pick: (Double, String)?
        if t >= 27        { pick = (22, "Faz \(Int(t))°C lá fora — pré-climatizar pra esfriar a cabine") }
        else if t > 0 && t <= 15 { pick = (23, "Faz \(Int(t))°C lá fora — pré-climatizar pra aquecer a cabine") }
        else { pick = nil }
        guard let (target, why) = pick else { return nil }
        let pre = max(0, dep - 12)
        return (String(format: "%02d:%02d", pre / 60, pre % 60), target, why)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if let sug = suggestion { suggestionCard(sug) }
                    if store.scheds.isEmpty && !store.loading {
                        Text("Nenhum agendamento. Adicione um para o carro pré-climatizar antes de você sair.")
                            .font(.subheadline).foregroundStyle(DS.muted).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 16)
                    }
                    ForEach(store.scheds) { s in SchedCard(sched: s, store: store) }
                    Button { Task { await store.add() } } label: {
                        Label("Adicionar agendamento", systemImage: "plus.circle.fill")
                            .font(.system(size: 15, weight: .bold)).frame(maxWidth: .infinity).frame(height: 50)
                            .foregroundStyle(.black).background(DS.green).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
                .padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Pré-climatização").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Concluído") { dismiss() } } }
        }
        .task { await store.load(); await trips.load() }
    }

    @ViewBuilder private func suggestionCard(_ s: (time: String, temp: Double, why: String)) -> some View {
        DSCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(DS.teal)
                    Text("Sugestão inteligente").font(.caption.weight(.semibold)).foregroundStyle(DS.teal)
                }
                Text("\(s.why). Você costuma sair de manhã nos dias úteis — deixar pronto às \(s.time), a \(Int(s.temp))°.")
                    .font(.subheadline).foregroundStyle(DS.text)
                Button { Task { await store.addAt(time: s.time, temp: s.temp) } } label: {
                    Label("Agendar \(s.time) · \(Int(s.temp))°", systemImage: "plus.circle.fill")
                        .font(.system(size: 14, weight: .bold)).frame(maxWidth: .infinity).frame(height: 44)
                        .foregroundStyle(.black).background(DS.teal).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
    }
}

private struct SchedCard: View {
    let sched: PreclimatSched
    let store: PreclimatStore

    // Estado local (não fica preso ao array do store → deletar não invalida binding).
    @State private var enabled: Bool
    @State private var time: String
    @State private var recurrence: String
    @State private var temp: Double
    @State private var fan: Double
    @State private var duration: Double

    init(sched: PreclimatSched, store: PreclimatStore) {
        self.sched = sched; self.store = store
        _enabled = State(initialValue: sched.enabled)
        _time = State(initialValue: sched.time)
        _recurrence = State(initialValue: sched.recurrence)
        _temp = State(initialValue: sched.temp)
        _fan = State(initialValue: Double(sched.fan))
        _duration = State(initialValue: Double(sched.duration))
    }

    private static let recOpts: [(String, String)] = [("once", "Uma vez"), ("daily", "Diário"), ("weekdays", "Dias úteis"), ("weekends", "Fim de semana")]
    private func f1(_ v: Double) -> String { String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",") }

    private var timeBinding: Binding<Date> {
        Binding(get: {
            let p = time.split(separator: ":"); var c = DateComponents()
            c.hour = Int(p.first ?? "7") ?? 7; c.minute = Int(p.last ?? "30") ?? 30
            return Calendar.current.date(from: c) ?? Date()
        }, set: { d in
            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
            time = String(format: "%02d:%02d", c.hour ?? 7, c.minute ?? 30)
            Task { await store.update(sched.id, "time", time) }
        })
    }

    var body: some View {
        DSCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    DatePicker("", selection: timeBinding, displayedComponents: .hourAndMinute).labelsHidden()
                    Spacer()
                    Toggle("", isOn: Binding(get: { enabled }, set: { v in enabled = v; Task { await store.update(sched.id, "enabled", v) } })).labelsHidden().tint(DS.green)
                    Button { Task { await store.remove(sched.id) } } label: {
                        Image(systemName: "trash").foregroundStyle(DS.red)
                    }.buttonStyle(.plain)
                }
                DSChoiceRow(options: Self.recOpts, selected: recurrence, color: DS.teal) { v in
                    recurrence = v; Task { await store.update(sched.id, "recurrence", v) }
                }
                sliderRow("Temperatura", "\(f1(temp))°", v: $temp, range: 16...32, step: 0.5) { Task { await store.update(sched.id, "temp", temp) } }
                sliderRow("Ventilador", "\(Int(fan))/7", v: $fan, range: 1...7, step: 1) { Task { await store.update(sched.id, "fan", Int(fan)) } }
                sliderRow("Duração", "\(Int(duration)) min", v: $duration, range: 5...60, step: 5) { Task { await store.update(sched.id, "duration", Int(duration)) } }
            }
        }
    }

    private func sliderRow(_ label: String, _ value: String, v: Binding<Double>, range: ClosedRange<Double>, step: Double, onCommit: @escaping () -> Void) -> some View {
        VStack(spacing: 4) {
            HStack { Text(label).font(.system(size: 14, weight: .medium)).foregroundStyle(DS.text); Spacer(); Text(value).font(.system(size: 14, weight: .bold)).foregroundStyle(DS.teal) }
            Slider(value: v, in: range, step: step) { editing in if !editing { onCommit() } }.tint(DS.teal)
        }
    }
}
