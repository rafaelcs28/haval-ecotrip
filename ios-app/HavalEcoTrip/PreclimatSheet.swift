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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if store.scheds.isEmpty && !store.loading {
                        Text("Nenhum agendamento. Adicione um para o carro pré-climatizar antes de você sair.")
                            .font(.subheadline).foregroundStyle(DS.muted).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 16)
                    }
                    ForEach($store.scheds) { $s in SchedCard(s: $s, store: store) }
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
        .task { await store.load() }
    }
}

private struct SchedCard: View {
    @Binding var s: PreclimatSched
    let store: PreclimatStore

    private static let recOpts: [(String, String)] = [("once", "Uma vez"), ("daily", "Diário"), ("weekdays", "Dias úteis"), ("weekends", "Fim de semana")]
    private func f1(_ v: Double) -> String { String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",") }

    private var timeBinding: Binding<Date> {
        Binding(get: {
            let p = s.time.split(separator: ":"); var c = DateComponents()
            c.hour = Int(p.first ?? "7") ?? 7; c.minute = Int(p.last ?? "30") ?? 30
            return Calendar.current.date(from: c) ?? Date()
        }, set: { d in
            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
            s.time = String(format: "%02d:%02d", c.hour ?? 7, c.minute ?? 30)
            Task { await store.update(s.id, "time", s.time) }
        })
    }

    var body: some View {
        DSCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    DatePicker("", selection: timeBinding, displayedComponents: .hourAndMinute).labelsHidden()
                    Spacer()
                    Toggle("", isOn: Binding(get: { s.enabled }, set: { v in s.enabled = v; Task { await store.update(s.id, "enabled", v) } })).labelsHidden().tint(DS.green)
                    Button { Task { await store.remove(s.id) } } label: {
                        Image(systemName: "trash").foregroundStyle(DS.red)
                    }
                }
                DSChoiceRow(options: Self.recOpts, selected: s.recurrence, color: DS.teal) { v in
                    s.recurrence = v; Task { await store.update(s.id, "recurrence", v) }
                }
                sliderRow("Temperatura", "\(f1(s.temp))°", value: s.temp, range: 16...32, step: 0.5) { v in
                    s.temp = v; Task { await store.update(s.id, "temp", v) }
                }
                sliderRow("Ventilador", "\(s.fan)/7", value: Double(s.fan), range: 1...7, step: 1) { v in
                    s.fan = Int(v); Task { await store.update(s.id, "fan", Int(v)) }
                }
                sliderRow("Duração", "\(s.duration) min", value: Double(s.duration), range: 5...60, step: 5) { v in
                    s.duration = Int(v); Task { await store.update(s.id, "duration", Int(v)) }
                }
            }
        }
    }

    @State private var editing = false
    private func sliderRow(_ label: String, _ value: String, value v: Double, range: ClosedRange<Double>, step: Double, onCommit: @escaping (Double) -> Void) -> some View {
        VStack(spacing: 4) {
            HStack { Text(label).font(.system(size: 14, weight: .medium)).foregroundStyle(DS.text); Spacer(); Text(value).font(.system(size: 14, weight: .bold)).foregroundStyle(DS.teal) }
            Slider(value: Binding(get: { v }, set: { nv in onCommit(nv) }), in: range, step: step).tint(DS.teal)
        }
    }
}
