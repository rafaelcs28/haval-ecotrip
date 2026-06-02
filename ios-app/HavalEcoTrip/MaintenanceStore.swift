//
//  MaintenanceStore.swift
//  Carrega GET /api/maintenance pra mostrar os próximos itens no Painel.
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

@MainActor
final class MaintenanceStore: ObservableObject {
    @Published var items: [MaintItem] = []

    private var base: String {
        let u = Settings.bridgeURL.isEmpty ? AuthConfig.bridgeURL : Settings.bridgeURL
        return u.hasSuffix("/") ? String(u.dropLast()) : u
    }

    struct Wrapper: Decodable { let next: [MaintItem]? }

    func load() async {
        guard Settings.isConfigured, let url = URL(string: "\(base)/api/maintenance") else { return }
        var req = URLRequest(url: url); req.timeoutInterval = 12
        req.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
            let w = try JSONDecoder().decode(Wrapper.self, from: data)
            // Mais urgentes primeiro: overdue, soon, depois por km restante.
            items = (w.next ?? []).sorted { a, b in
                let rank: (String?) -> Int = { $0 == "overdue" ? 0 : ($0 == "soon" ? 1 : 2) }
                if rank(a.status) != rank(b.status) { return rank(a.status) < rank(b.status) }
                return (a.remaining_km ?? .greatestFiniteMagnitude) < (b.remaining_km ?? .greatestFiniteMagnitude)
            }
        } catch { /* silencioso */ }
    }
}
