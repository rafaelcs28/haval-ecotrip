//
//  LogsSheet.swift
//  Popup de Logs de eventos. GET /api/events → {id, ts, type, label}.
//  Filtros: categoria (derivada do type), busca e período — como no PWA.
//

import SwiftUI

struct LogEvent: Identifiable {
    let id: Double
    let ts: Date
    let type: String
    let label: String
    init(_ r: [String: Any]) {
        let t = (r["ts"] as? Double) ?? (r["ts"] as? Int).map(Double.init) ?? 0
        id = (r["id"] as? Double) ?? (r["id"] as? Int).map(Double.init) ?? t
        ts = Date(timeIntervalSince1970: t / 1000)
        type = (r["type"] as? String) ?? ""
        label = (r["label"] as? String) ?? ""
    }
    var category: String {
        let t = type.lowercased()
        if t.contains("engine") || t.contains("motor") { return "Motor" }
        if t.contains("lock") || t.contains("trava") { return "Trava" }
        if t.contains("door") || t.contains("trunk") || t.contains("porta") { return "Portas" }
        if t.contains("window") || t.contains("sunroof") || t.contains("vidro") { return "Vidros" }
        if t.contains("ac") || t.contains("hvac") || t.contains("clim") { return "AC" }
        if t.contains("trip") || t.contains("geo") || t.contains("drive") { return "Viagens" }
        if t.contains("charge") || t.contains("fuel") || t.contains("refuel") || t.contains("recarg") { return "Recarga" }
        if t.contains("maint") || t.contains("alert") || t.contains("tyre") || t.contains("anomaly") { return "Manut." }
        return "Outros"
    }
    var color: Color {
        switch category {
        case "Motor": return DS.orange; case "Recarga": return DS.green; case "Viagens": return DS.teal
        case "Trava": return DS.blue; case "Manut.": return DS.yellow; default: return DS.muted
        }
    }
    var icon: String {
        switch category {
        case "Motor": return "power"; case "Recarga": return "bolt.fill"; case "Viagens": return "car.fill"
        case "Trava": return "lock.fill"; case "Portas": return "car.door.front.left.open"
        case "Vidros": return "macwindow"; case "AC": return "snowflake"; case "Manut.": return "wrench.and.screwdriver.fill"
        default: return "circle.fill"
        }
    }
}

struct LogsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var all: [LogEvent] = []
    @State private var loading = true
    @State private var cat = "Tudo"
    @State private var period = 0   // 0=Tudo,1=Hoje,2=7d,3=30d
    @State private var search = ""

    private let cats = ["Tudo", "Motor", "Viagens", "Recarga", "Trava", "Portas", "Vidros", "AC", "Manut."]
    private static let df: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR"); f.dateFormat = "d MMM HH:mm"; return f }()
    private var base: String {
        let u = Settings.bridgeURL.isEmpty ? AuthConfig.bridgeURL : Settings.bridgeURL
        return u.hasSuffix("/") ? String(u.dropLast()) : u
    }

    private var filtered: [LogEvent] {
        let now = Date(); let cal = Calendar.current
        return all.filter { e in
            if cat != "Tudo" && e.category != cat { return false }
            switch period {
            case 1: if !cal.isDateInToday(e.ts) { return false }
            case 2: if e.ts < now.addingTimeInterval(-7*86400) { return false }
            case 3: if e.ts < now.addingTimeInterval(-30*86400) { return false }
            default: break
            }
            if !search.isEmpty { return e.label.localizedCaseInsensitiveContains(search) || e.type.localizedCaseInsensitiveContains(search) }
            return true
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(cats, id: \.self) { c in
                            Button { cat = c } label: {
                                Text(c).font(.system(size: 12, weight: .bold))
                                    .padding(.horizontal, 12).frame(height: 32)
                                    .foregroundStyle(cat == c ? .black : DS.text).background(cat == c ? DS.green : DS.panel2).clipShape(Capsule())
                            }
                        }
                    }.padding(.horizontal, 16)
                }
                Picker("", selection: $period) { Text("Tudo").tag(0); Text("Hoje").tag(1); Text("7d").tag(2); Text("30d").tag(3) }
                    .pickerStyle(.segmented).padding(.horizontal, 16)

                ScrollView {
                    LazyVStack(spacing: 8) {
                        if filtered.isEmpty && !loading {
                            Text("Nenhum evento.").font(.subheadline).foregroundStyle(DS.muted).padding(.top, 30)
                        }
                        ForEach(filtered) { e in
                            HStack(spacing: 10) {
                                Image(systemName: e.icon).font(.caption).foregroundStyle(e.color).frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(e.label.isEmpty ? e.type : e.label).font(.system(size: 14)).foregroundStyle(DS.text)
                                    Text(Self.df.string(from: e.ts)).font(.caption2).foregroundStyle(DS.muted)
                                }
                                Spacer()
                            }
                            .padding(10).background(DS.panel).clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }.padding(.horizontal, 16)
                }
            }
            .searchable(text: $search, prompt: "Buscar")
            .background(DS.bg.ignoresSafeArea())
            .overlay { if loading { ProgressView().tint(DS.green) } }
            .navigationTitle("Logs de eventos").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Concluído") { dismiss() } } }
        }
        .task { await load() }
    }

    private func load() async {
        defer { loading = false }
        guard let url = URL(string: "\(base)/api/events") else { return }
        var req = URLRequest(url: url); req.timeoutInterval = 15
        req.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        all = arr.map(LogEvent.init).sorted { $0.id > $1.id }
    }
}
