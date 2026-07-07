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
    /// Cor por severidade inferida do tipo (alerta/segurança = vermelho/laranja).
    var tint: Color {
        let t = type.lowercased()
        if t.contains("maint") || t.contains("alert") || t.contains("anomaly") || t.contains("security") || t.contains("seguran") { return DS.red }
        if t.contains("lock") || t.contains("trava") || t.contains("engine") || t.contains("motor") { return DS.orange }
        if t.contains("charge") || t.contains("recarg") { return DS.green }
        if t.contains("trip") || t.contains("viag") { return DS.blue }
        return DS.teal
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
    /// Marcador de leitura persistido: notificações com id (=ts ms) acima deste são não lidas.
    @AppStorage("notif_last_read_ts") private var lastReadTs: Double = 0

    private var items: [NotifItem] { hist.items.map(NotifItem.init).sorted { $0.id > $1.id } }
    private var unread: [NotifItem] { items.filter { $0.id > lastReadTs } }
    private var earlier: [NotifItem] { items.filter { $0.id <= lastReadTs } }
    private static let df: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR"); f.dateFormat = "d MMM · HH:mm"; return f
    }()

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if items.isEmpty && !loading {
                        Text("Nenhuma notificação.").font(.subheadline).foregroundStyle(DS.muted)
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    if !unread.isEmpty {
                        section("NÃO LIDAS") {
                            ForEach(unread) { n in row(n, unread: true) }
                        }
                    }
                    if !earlier.isEmpty {
                        section("ANTERIORES") {
                            ForEach(earlier) { n in row(n, unread: false) }
                        }
                    }
                    // Ação de rodapé: o que vira notificação
                    if !items.isEmpty {
                        Button { } label: {
                            HStack {
                                Text("O que vira notificação").font(.system(size: 13, weight: .medium)).foregroundStyle(DS.text)
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(DS.muted)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 13)
                            .background(DS.panel2).clipShape(RoundedRectangle(cornerRadius: 15))
                        }
                        .buttonStyle(.plain)
                    }
                }.padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .overlay { if loading && items.isEmpty { ProgressView().tint(DS.green) } }
            .navigationTitle("Notificações").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 7) {
                        Text("Notificações").font(.system(size: 16, weight: .bold)).foregroundStyle(DS.text)
                        if !unread.isEmpty {
                            Text("\(unread.count)")
                                .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(DS.red).clipShape(Capsule())
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Concluído") { dismiss() } }
                ToolbarItem(placement: .cancellationAction) {
                    if !unread.isEmpty {
                        Button("Marcar lidas") { markRead() }.foregroundStyle(DS.blue)
                    } else if !items.isEmpty {
                        Button("Limpar") { Task { await clear() } }.foregroundStyle(.red).disabled(clearing)
                    }
                }
            }
            .task { loading = hist.items.isEmpty; await hist.sync(); loading = false }
        }
    }

    @ViewBuilder
    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.muted).tracking(0.5)
                .padding(.leading, 4)
            VStack(spacing: 0) { content() }
                .background(DS.panel2).clipShape(RoundedRectangle(cornerRadius: 15))
        }
    }

    @ViewBuilder
    private func row(_ n: NotifItem, unread: Bool) -> some View {
        let accent = unread ? n.tint : DS.muted
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: n.icon).font(.system(size: 15)).foregroundStyle(accent).frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    if !n.title.isEmpty {
                        Text(n.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.text)
                    }
                    if !n.body.isEmpty {
                        Text(n.body).font(.system(size: 13)).foregroundStyle(unread ? DS.text.opacity(0.9) : DS.text2)
                    }
                    Text(Self.df.string(from: n.ts)).font(.system(size: 11)).foregroundStyle(DS.muted)
                }
                Spacer(minLength: 6)
                if unread { Circle().fill(n.tint).frame(width: 7, height: 7).padding(.top, 5) }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(unread ? n.tint.opacity(0.06) : Color.clear)
            if n.id != (unread ? self.unread.last?.id : self.earlier.last?.id) {
                Divider().overlay(DS.divider).padding(.leading, 47)
            }
        }
    }

    private func markRead() {
        if let top = items.first?.id { lastReadTs = top }
    }

    private func clear() async {
        clearing = true; defer { clearing = false }
        let base = BridgeRouter.shared.currentURL
        guard let url = URL(string: (base.hasSuffix("/") ? String(base.dropLast()) : base) + "/api/push/history/clear") else { return }
        var req = URLRequest(url: url); req.httpMethod = "POST"
        req.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: req)
        hist.clear()
        await hist.sync()
    }
}
