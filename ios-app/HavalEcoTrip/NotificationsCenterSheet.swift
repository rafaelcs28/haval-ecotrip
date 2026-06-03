//
//  NotificationsCenterSheet.swift
//  Central de notificações — histórico de alertas push recebidos.
//  GET /api/push/history?device_id= → [{ts, title, body, type}] (filtrado por device).
//  Offline-first: cacheia em disco (SyncedList) e mostra mesmo sem rede.
//

import SwiftUI

struct NotifItem: Identifiable {
    let id: Double
    let ts: Date
    let title: String
    let body: String
    let type: String
    init(_ r: [String: Any]) {
        let t = (r["ts"] as? Double) ?? (r["ts"] as? Int).map(Double.init) ?? 0
        id = t
        ts = Date(timeIntervalSince1970: t / 1000)
        title = (r["title"] as? String) ?? ""
        body = (r["body"] as? String) ?? ""
        type = (r["type"] as? String) ?? ""
    }
    var icon: String {
        let t = type.lowercased()
        if t.contains("charge") || t.contains("recarg") { return "bolt.fill" }
        if t.contains("lock") || t.contains("trava") { return "lock.fill" }
        if t.contains("engine") || t.contains("motor") { return "power" }
        if t.contains("trip") || t.contains("viag") { return "car.fill" }
        if t.contains("maint") || t.contains("alert") || t.contains("anomaly") { return "wrench.and.screwdriver.fill" }
        if t.contains("window") || t.contains("vidro") || t.contains("rule") || t.contains("automa") { return "wand.and.stars" }
        return "bell.fill"
    }
}

struct NotificationsCenterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var hist = SyncedList(
        name: "notif_history",
        path: "/api/push/history?device_id=\(Settings.notifDeviceId)",
        idKeys: ["ts"], incremental: false)
    @State private var loading = true
    @State private var clearing = false

    private var items: [NotifItem] { hist.items.map(NotifItem.init).sorted { $0.id > $1.id } }
    private static let df: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR"); f.dateFormat = "d MMM · HH:mm"; return f
    }()

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 8) {
                    if items.isEmpty && !loading {
                        Text("Nenhuma notificação.").font(.subheadline).foregroundStyle(DS.muted).padding(.top, 40)
                    }
                    ForEach(items) { n in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: n.icon).font(.system(size: 15)).foregroundStyle(DS.green).frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                if !n.title.isEmpty {
                                    Text(n.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.text)
                                }
                                if !n.body.isEmpty {
                                    Text(n.body).font(.system(size: 13)).foregroundStyle(DS.text.opacity(0.85))
                                }
                                Text(Self.df.string(from: n.ts)).font(.caption2).foregroundStyle(DS.muted)
                            }
                            Spacer()
                        }
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(DS.panel).clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }.padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .overlay { if loading && items.isEmpty { ProgressView().tint(DS.green) } }
            .navigationTitle("Notificações").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Concluído") { dismiss() } }
                ToolbarItem(placement: .cancellationAction) {
                    if !items.isEmpty {
                        Button("Limpar") { Task { await clear() } }.foregroundStyle(.red).disabled(clearing)
                    }
                }
            }
            .task { loading = hist.items.isEmpty; await hist.sync(); loading = false }
        }
    }

    private func clear() async {
        clearing = true; defer { clearing = false }
        let base = Settings.bridgeURL.isEmpty ? AuthConfig.bridgeURL : Settings.bridgeURL
        guard let url = URL(string: (base.hasSuffix("/") ? String(base.dropLast()) : base) + "/api/push/history/clear") else { return }
        var req = URLRequest(url: url); req.httpMethod = "POST"
        req.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: req)
        hist.clear()
        await hist.sync()
    }
}
