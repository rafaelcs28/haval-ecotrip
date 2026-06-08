//
//  BydChargeWidget.swift
//  Widget de home screen do Grasi Recarga — status da recarga do BYD.
//  Fica fixo na tela (widget não some sozinho); mostra a recarga ao vivo quando
//  o BYD está carregando e um estado discreto quando não está. Busca /api/songpro/
//  status do bridge (URL/token via App Group). Atualiza por timeline (não segundo
//  a segundo — pra ao vivo de verdade use a Live Activity).
//
import WidgetKit
import SwiftUI

private let bydAccent = Color(red: 0.45, green: 0.75, blue: 1.0)
private let bydAppGroup = "group.br.com.consorciolimpagyn.songpro"

private func bydTripDur(_ min: Int) -> String {
    guard min > 0 else { return "—" }
    return min >= 60 ? "\(min/60)h\(String(format: "%02d", min%60))" : "\(min) min"
}

struct BydChargeEntry: TimelineEntry {
    let date: Date
    let charging: Bool
    let soc: Double
    let powerKw: Double
    let remainingMin: Int
    let configured: Bool
}

struct BydChargeProvider: TimelineProvider {
    func placeholder(in context: Context) -> BydChargeEntry {
        BydChargeEntry(date: Date(), charging: true, soc: 65, powerKw: 6.4, remainingMin: 48, configured: true)
    }
    func getSnapshot(in context: Context, completion: @escaping (BydChargeEntry) -> Void) {
        Task { completion(await fetch()) }
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<BydChargeEntry>) -> Void) {
        Task {
            let e = await fetch()
            // Carregando: atualiza a cada ~2 min; ocioso: a cada ~15 min.
            let next = Date().addingTimeInterval(e.charging ? 120 : 900)
            completion(Timeline(entries: [e], policy: .after(next)))
        }
    }
    private func fetch() async -> BydChargeEntry {
        let none = BydChargeEntry(date: Date(), charging: false, soc: 0, powerKw: 0, remainingMin: 0, configured: false)
        let g = UserDefaults(suiteName: bydAppGroup)
        guard let base = g?.string(forKey: "byd_bridge_url"), !base.isEmpty,
              let token = g?.string(forKey: "byd_bridge_token"), !token.isEmpty,
              let url = URL(string: (base.hasSuffix("/") ? String(base.dropLast()) : base) + "/api/songpro/status")
        else { return none }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.addValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        guard let (d, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        else { return BydChargeEntry(date: Date(), charging: false, soc: 0, powerKw: 0, remainingMin: 0, configured: true) }
        let num: (String) -> Double = { (o[$0] as? Double) ?? (o[$0] as? NSNumber)?.doubleValue ?? 0 }
        return BydChargeEntry(
            date: Date(),
            charging: (o["charging"] as? Bool) ?? false,
            soc: num("soc"), powerKw: num("powerKw"),
            remainingMin: Int(num("remainingMin")), configured: true
        )
    }
}

struct BydChargeWidgetView: View {
    var entry: BydChargeEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: entry.charging ? "bolt.car.fill" : "car.fill")
                    .foregroundStyle(entry.charging ? bydAccent : .secondary)
                Text(entry.charging ? "Carregando" : "BYD da Grasi")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(entry.charging ? bydAccent : .secondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
            if !entry.configured {
                Text("Abra o app pra configurar").font(.caption2).foregroundStyle(.secondary)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(Int(entry.soc))").font(.system(size: 38, weight: .bold, design: .rounded))
                        .foregroundStyle(entry.charging ? bydAccent : .primary).minimumScaleFactor(0.6).lineLimit(1)
                    Text("%").font(.title3).foregroundStyle(.secondary)
                }
                if entry.charging {
                    Text(String(format: "%.1f kW · %@", entry.powerKw, bydTripDur(entry.remainingMin)))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.6)
                } else {
                    Text("sem recarga").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct BydChargeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BydChargeWidget", provider: BydChargeProvider()) { entry in
            BydChargeWidgetView(entry: entry)
                .containerBackground(.black.gradient, for: .widget)
        }
        .configurationDisplayName("Recarga BYD")
        .description("Status da recarga do BYD da Grasi.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
