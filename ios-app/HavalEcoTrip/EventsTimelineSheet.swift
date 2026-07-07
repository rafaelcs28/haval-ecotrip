//  EventsTimelineSheet.swift
//  Timeline de eventos do carro (travar/destravar, porta-malas, viagens,
//  recargas, etc.) do /api/events do bridge.

import SwiftUI

struct CarEvent: Identifiable {
    let id: Double
    let ts: Double
    let type: String
    let label: String
    var date: Date { Date(timeIntervalSince1970: ts / 1000) }
}

@MainActor
final class EventsStore: ObservableObject {
    @Published var events: [CarEvent] = []
    @Published var loading = false

    private var base: String {
        let u = BridgeRouter.shared.currentURL
        return u.hasSuffix("/") ? String(u.dropLast()) : u
    }

    func load() async {
        guard !base.isEmpty, let url = URL(string: "\(base)/api/events") else { return }
        loading = true; defer { loading = false }
        var r = URLRequest(url: url); r.timeoutInterval = 12
        r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        guard let (d, resp) = try? await URLSession.shared.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return }
        events = arr.compactMap { e in
            guard let ts = (e["ts"] as? Double) ?? (e["ts"] as? Int).map(Double.init) else { return nil }
            return CarEvent(id: (e["id"] as? Double) ?? ts, ts: ts,
                            type: (e["type"] as? String) ?? "", label: (e["label"] as? String) ?? "")
        }
    }
}

struct EventsTimelineSheet: View {
    @StateObject private var store = EventsStore()
    @Environment(\.dismiss) private var dismiss
    @State private var filter: Filter = .all
    @State private var showAllDays = false

    enum Filter: String, CaseIterable, Identifiable {
        case all = "Tudo", commands = "Comandos", alerts = "Alertas"
        var id: String { rawValue }
    }

    /// Cor semântica do ponto: verde energia, teal viagem/clima, amarelo atenção, cinza comando.
    private func dotColor(_ t: String) -> Color {
        switch t {
        case let x where x.contains("charg") || x.contains("engine"): return DS.green
        case let x where x.contains("trip") || x.contains("window") || x.contains("vidro") || x.contains("climate") || x.contains("clima"): return DS.teal
        case let x where x.contains("theft") || x.contains("alert") || x.contains("low") || x.contains("warn"): return DS.yellow
        default: return DS.muted
        }
    }

    private func matches(_ e: CarEvent) -> Bool {
        switch filter {
        case .all: return true
        case .alerts:
            let t = e.type
            return t.contains("theft") || t.contains("alert") || t.contains("low") || t.contains("warn") || t.contains("geofence")
        case .commands:
            let t = e.type
            return t.contains("lock") || t.contains("window") || t.contains("vidro") || t.contains("trunk") || t.contains("engine")
        }
    }

    private func icon(_ t: String) -> (String, Color) {
        switch t {
        case let x where x.contains("lock_open"): return ("lock.open.fill", DS.orange)
        case let x where x.contains("lock"):       return ("lock.fill", DS.green)
        case let x where x.contains("trunk"):      return ("suitcase.fill", DS.muted)
        case let x where x.contains("trip_end"):   return ("flag.checkered", DS.teal)
        case let x where x.contains("trip"):       return ("car.fill", DS.teal)
        case let x where x.contains("charg"):      return ("bolt.fill", DS.green)
        case let x where x.contains("engine"):     return ("power", DS.blue)
        case let x where x.contains("theft"):      return ("exclamationmark.triangle.fill", DS.red)
        case let x where x.contains("geofence"):   return ("mappin.circle.fill", DS.blue)
        case let x where x.contains("window") || x.contains("vidro"): return ("macwindow", DS.teal)
        default: return ("circle.fill", DS.muted)
        }
    }

    private var grouped: [(day: String, items: [CarEvent])] {
        let df = DateFormatter(); df.locale = Locale(identifier: "pt_BR"); df.dateFormat = "EEEE, d 'de' MMM"
        let cal = Calendar.current
        let filtered = store.events.filter(matches)
        let byDay = Dictionary(grouping: filtered) { cal.startOfDay(for: $0.date) }
        let all = byDay.keys.sorted(by: >).map { (df.string(from: $0).capitalized, byDay[$0]!.sorted { $0.ts > $1.ts }) }
        // Por padrão só o dia mais recente; "ver dias anteriores" revela o resto.
        return showAllDays ? all : Array(all.prefix(1))
    }

    private var extraDays: Int { max(0, Set(store.events.filter(matches).map { Calendar.current.startOfDay(for: $0.date) }).count - 1) }

    var body: some View {
        NavigationStack {
            Group {
                if store.events.isEmpty {
                    if store.loading { ProgressView().tint(DS.green) }
                    else { Text("Sem eventos ainda.").font(.callout).foregroundStyle(DS.muted) }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            // Filtros: Tudo / Comandos / Alertas.
                            HStack(spacing: 8) {
                                ForEach(Filter.allCases) { f in
                                    let on = filter == f
                                    Button { filter = f } label: {
                                        Text(f.rawValue).font(.system(size: 13, weight: .semibold))
                                            .padding(.horizontal, 14).padding(.vertical, 7)
                                            .foregroundStyle(on ? Color.black : DS.text2)
                                            .background(on ? DS.teal : DS.panel2)
                                            .clipShape(Capsule())
                                    }.buttonStyle(.plain)
                                }
                                Spacer()
                            }

                            ForEach(grouped, id: \.day) { g in
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(g.day).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.text2)
                                    VStack(alignment: .leading, spacing: 0) {
                                        ForEach(g.items) { e in row(e, last: e.id == g.items.last?.id) }
                                    }
                                }
                            }

                            if !showAllDays && extraDays > 0 {
                                Button { showAllDays = true } label: {
                                    HStack(spacing: 4) {
                                        Text("Ver dias anteriores").font(.system(size: 13, weight: .semibold))
                                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                                    }.foregroundStyle(DS.teal)
                                }.buttonStyle(.plain).padding(.top, 2)
                            }
                        }.padding(16)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Eventos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fechar") { dismiss() } } }
            .task { await store.load() }
            .refreshable { await store.load() }
        }
    }

    private func row(_ e: CarEvent, last: Bool) -> some View {
        let color = dotColor(e.type)
        let tf = DateFormatter(); tf.locale = Locale(identifier: "pt_BR"); tf.dateFormat = "HH:mm"
        return HStack(alignment: .top, spacing: 12) {
            // Coluna do timeline: ponto colorido (9px) + linha contínua.
            VStack(spacing: 0) {
                Circle().fill(color).frame(width: 9, height: 9)
                    .overlay(Circle().stroke(DS.bg, lineWidth: 2).scaleEffect(1.6))
                    .padding(.top, 4)
                if !last {
                    Rectangle().fill(DS.divider).frame(width: 2).frame(maxHeight: .infinity)
                }
            }.frame(width: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.label).font(.system(size: 12)).foregroundStyle(DS.text)
                Text(tf.string(from: e.date)).font(.system(size: 10, design: .monospaced)).foregroundStyle(DS.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, last ? 0 : 14)
        }
    }
}
