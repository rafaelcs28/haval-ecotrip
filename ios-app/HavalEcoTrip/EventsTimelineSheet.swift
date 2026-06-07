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
        let u = Settings.bridgeURL.isEmpty ? AuthConfig.bridgeURL : Settings.bridgeURL
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
        let byDay = Dictionary(grouping: store.events) { cal.startOfDay(for: $0.date) }
        return byDay.keys.sorted(by: >).map { (df.string(from: $0).capitalized, byDay[$0]!.sorted { $0.ts > $1.ts }) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.events.isEmpty {
                    if store.loading { ProgressView().tint(DS.green) }
                    else { Text("Sem eventos ainda.").font(.callout).foregroundStyle(DS.muted) }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(grouped, id: \.day) { g in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(g.day).font(.caption.weight(.semibold)).foregroundStyle(DS.muted)
                                    DSCard {
                                        VStack(spacing: 0) {
                                            ForEach(g.items) { e in row(e); if e.id != g.items.last?.id { Divider().background(DS.border) } }
                                        }
                                    }
                                }
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

    private func row(_ e: CarEvent) -> some View {
        let (ic, color) = icon(e.type)
        let tf = DateFormatter(); tf.locale = Locale(identifier: "pt_BR"); tf.dateFormat = "HH:mm"
        return HStack(spacing: 10) {
            Image(systemName: ic).font(.subheadline).foregroundStyle(color).frame(width: 24)
            Text(e.label).font(.subheadline).foregroundStyle(DS.text).frame(maxWidth: .infinity, alignment: .leading)
            Text(tf.string(from: e.date)).font(.caption2).foregroundStyle(DS.muted)
        }.padding(.vertical, 9)
    }
}
