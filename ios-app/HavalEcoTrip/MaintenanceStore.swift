//
//  MaintenanceStore.swift
//  GET /api/maintenance — próximas revisões, histórico, intervalos e totais.
//  POST /api/maintenance/history (registrar), DELETE /api/maintenance/history/:id.
//

import SwiftUI

struct MaintItem: Decodable, Identifiable {
    let itemId: String?
    let label: String?
    let category: String?
    let icon: String?
    let next_km: Double?
    let remaining_km: Double?
    let next_date_ms: Double?
    let remaining_days: Double?
    let status: String?   // ok | soon | overdue
    enum CodingKeys: String, CodingKey {
        case itemId = "id", label, category, icon, next_km, remaining_km, next_date_ms, remaining_days, status
    }
    var id: String { itemId ?? label ?? UUID().uuidString }
    var statusColor: Color {
        switch status { case "overdue": return DS.red; case "soon": return DS.yellow; default: return DS.green }
    }
}

struct MaintInterval: Decodable, Identifiable {
    let id: String
    let label: String?
    let icon: String?
}

struct MaintHistory: Decodable, Identifiable {
    let id: String
    let type_id: String?
    let label: String?
    let odometer_km: Double?
    let date_ms: Double?
    let notes: String?
    let cost: Double?
}

@MainActor
final class MaintenanceStore: ObservableObject {
    @Published var items: [MaintItem] = []        // next
    @Published var intervals: [MaintInterval] = []
    @Published var history: [MaintHistory] = []
    @Published var currentOdometer: Double = 0
    @Published var dailyKmAvg: Double = 0
    @Published var totalCost: Double = 0
    @Published var costPerKm: Double = 0

    private struct Resp: Decodable {
        let next: [MaintItem]?
        let intervals: [MaintInterval]?
        let history: [MaintHistory]?
        let current_odometer_km: Double?
        let daily_km_avg: Double?
        let total_cost: Double?
        let cost_per_km: Double?
    }

    private var base: String {
        let u = Settings.bridgeURL.isEmpty ? AuthConfig.bridgeURL : Settings.bridgeURL
        return u.hasSuffix("/") ? String(u.dropLast()) : u
    }
    private func authReq(_ path: String, _ method: String, _ body: [String: Any]? = nil) -> URLRequest? {
        guard let url = URL(string: "\(base)\(path)") else { return nil }
        var r = URLRequest(url: url); r.httpMethod = method; r.timeoutInterval = 12
        r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        if let body { r.addValue("application/json", forHTTPHeaderField: "Content-Type"); r.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        return r
    }

    func load() async {
        guard Settings.isConfigured, let r = authReq("/api/maintenance", "GET") else { return }
        guard let (data, resp) = try? await URLSession.shared.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let d = try? JSONDecoder().decode(Resp.self, from: data) else { return }
        items = (d.next ?? []).sorted { a, b in
            let rank: (String?) -> Int = { $0 == "overdue" ? 0 : ($0 == "soon" ? 1 : 2) }
            if rank(a.status) != rank(b.status) { return rank(a.status) < rank(b.status) }
            return (a.remaining_km ?? .greatestFiniteMagnitude) < (b.remaining_km ?? .greatestFiniteMagnitude)
        }
        intervals = d.intervals ?? []
        history = (d.history ?? []).sorted { ($0.date_ms ?? 0) > ($1.date_ms ?? 0) }
        currentOdometer = d.current_odometer_km ?? 0
        dailyKmAvg = d.daily_km_avg ?? 0
        totalCost = d.total_cost ?? 0
        costPerKm = d.cost_per_km ?? 0
    }

    func add(typeId: String, odometer: Double, dateMs: Double, cost: Double?, notes: String) async {
        var body: [String: Any] = ["type_id": typeId, "odometer_km": odometer, "date_ms": dateMs, "notes": notes]
        if let cost, cost > 0 { body["cost"] = cost }
        guard let r = authReq("/api/maintenance/history", "POST", body) else { return }
        _ = try? await URLSession.shared.data(for: r)
        await load()
    }

    func removeHistory(_ id: String) async {
        history.removeAll { $0.id == id }
        guard let r = authReq("/api/maintenance/history/\(id)", "DELETE") else { return }
        _ = try? await URLSession.shared.data(for: r)
        await load()
    }
}
