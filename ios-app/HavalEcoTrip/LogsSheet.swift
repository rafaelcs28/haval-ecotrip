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
    // Eventos offline-first: carrega do disco e sincroniza só o novo (?since=).
    @StateObject private var events = SyncedList(name: "events", path: "/api/events", idKeys: ["id", "ts"], incremental: true)
    @State private var loading = true
    @State private var cat = "Tudo"
    @State private var period = 0   // 0=Tudo,1=Hoje,2=7d,3=30d
    @State private var search = ""

    private var all: [LogEvent] { events.items.map(LogEvent.init).sorted { $0.id > $1.id } }
    private let cats = ["Tudo", "Motor", "Viagens", "Recarga", "Trava", "Portas", "Vidros", "AC", "Manut."]
    private static let df: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR"); f.dateFormat = "d MMM HH:mm"; return f }()
    // Terminal: só HH:mm:ss no começo de cada linha.
    private static let tf: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR"); f.dateFormat = "HH:mm:ss"; return f }()
    // Fundo mais escuro que DS.bg pro visual de terminal (#060607).
    private static let terminalBg = Color(red: 0.024, green: 0.024, blue: 0.027)

    // Estimativa de retenção: janela dos eventos carregados + tamanho bruto.
    private var retentionLine: String {
        guard let oldest = all.last?.ts, let newest = all.first?.ts else { return "sem eventos" }
        let days = max(1, Int(newest.timeIntervalSince(oldest) / 86400) + 1)
        let bytes = all.reduce(0) { $0 + $1.label.utf8.count + $1.type.utf8.count + 40 }
        let mb = Double(bytes) / 1_048_576
        let size = mb >= 0.1 ? "\(Fmt.dec1(mb)) MB" : "\(bytes / 1024) KB"
        return "\(days) \(days == 1 ? "dia" : "dias") · \(all.count) eventos · \(size)"
    }

    // Texto exportável (timestamp topic payload por linha).
    private func exportText() -> URL? {
        let body = filtered.reversed().map { e in
            "\(Self.tf.string(from: e.ts)) \(e.type) \(e.label)"
        }.joined(separator: "\n")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("haval-logs.txt")
        try? body.data(using: .utf8)?.write(to: url)
        return url
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

                terminal

                HStack(spacing: 8) {
                    Text(retentionLine).font(.system(size: 10.5)).foregroundStyle(DS.muted)
                    Spacer()
                    ShareLink(item: exportText() ?? FileManager.default.temporaryDirectory) {
                        Label("Exportar .txt", systemImage: "square.and.arrow.up")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.teal)
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 4)
            }
            .searchable(text: $search, prompt: "Buscar")
            .background(DS.bg.ignoresSafeArea())
            .overlay { if loading { ProgressView().tint(DS.green) } }
            .navigationTitle("Logs de eventos").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Concluído") { dismiss() } } }
        }
        .presentationDetents([.large])
        .task { loading = events.items.isEmpty; await events.sync(); loading = false }
    }

    // Console mono: "timestamp topic payload", topic tingido por semântica.
    private var terminal: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 3) {
                if filtered.isEmpty && !loading {
                    Text("nenhum evento").font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(DS.muted).padding(.top, 30)
                }
                ForEach(filtered) { e in
                    HStack(alignment: .top, spacing: 8) {
                        Text(Self.tf.string(from: e.ts))
                            .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(DS.muted)
                        Text(e.type.isEmpty ? e.category.lowercased() : e.type)
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(e.color).lineLimit(1)
                        Text(e.label).font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(DS.text2)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Self.terminalBg)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(DS.border, lineWidth: 1))
        .padding(.horizontal, 16)
    }
}
