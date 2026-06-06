//  LockWidgets.swift
//  Widgets de tela de bloqueio (iOS 16+) e StandBy (iOS 17): SOC + autonomia do
//  Haval em formato accessory. Reusa BatteryProvider/BatteryEntry do BatteryWidget.

import WidgetKit
import SwiftUI

struct LockBatteryView: View {
    @Environment(\.widgetFamily) var family
    let entry: BatteryEntry

    private var remaining: String {
        let m = entry.remainingMin
        return m >= 60 ? "~\(m / 60)h\(String(format: "%02d", m % 60))" : "~\(m) min"
    }

    var body: some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: min(max(entry.soc / 100, 0), 1)) {
                Image(systemName: entry.charging ? "bolt.fill" : "bolt.car")
            } currentValueLabel: {
                Text("\(Int(entry.soc))")
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .containerBackground(.clear, for: .widget)

        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: entry.charging ? "bolt.fill" : "car.fill").font(.caption2)
                    Text("Haval \(Int(entry.soc))%").font(.headline).widgetAccentable()
                }
                if entry.charging && entry.remainingMin > 0 {
                    Text("Carregando · \(remaining)").font(.caption2)
                } else {
                    Text("⚡\(Int(entry.evKm)) km · ⛽\(Int(entry.iceKm)) km").font(.caption2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .containerBackground(.clear, for: .widget)

        case .accessoryInline:
            if entry.charging && entry.remainingMin > 0 {
                Label("\(Int(entry.soc))% · \(remaining)", systemImage: "bolt.fill")
            } else {
                Label("\(Int(entry.soc))% · \(Int(entry.evKm)) km", systemImage: "bolt.car")
            }

        default:
            Text("\(Int(entry.soc))%")
        }
    }
}

struct LockBatteryWidget: Widget {
    let kind = "LockBatteryWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BatteryProvider()) { entry in
            LockBatteryView(entry: entry)
        }
        .configurationDisplayName("Haval — bloqueio")
        .description("SOC e autonomia na tela de bloqueio e no StandBy.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
