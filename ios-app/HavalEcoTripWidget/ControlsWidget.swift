//  ControlsWidget.swift
//  Widget interativo (iOS 17): SOC + botões que disparam App Intents direto
//  (travar/destravar conforme o estado, e pré-clima) sem abrir o app.
//  Reusa BatteryProvider/BatteryEntry do BatteryWidget.

import WidgetKit
import SwiftUI
import AppIntents

@available(iOS 17.0, *)
struct ControlsWidget: Widget {
    let kind = "ControlsWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BatteryProvider()) { entry in
            ControlsWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color.black }
        }
        .configurationDisplayName("Controles do Haval")
        .description("SOC + botões: travar/destravar e pré-clima, direto do widget.")
        .supportedFamilies([.systemMedium])
    }
}

@available(iOS 17.0, *)
struct ControlsWidgetView: View {
    let entry: BatteryEntry
    private var locked: Bool { entry.lockState == "locked" }

    var body: some View {
        if !entry.isConfigured {
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.yellow)
                Text("Abra o app para configurar").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(Int(entry.soc.rounded()))")
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                        Text("%").font(.headline).foregroundStyle(.secondary)
                    }
                    .foregroundStyle(socColor(entry.soc))
                    Text("\(Int(entry.evKm.rounded())) km EV").font(.caption).foregroundStyle(.secondary)
                    if let l = entry.lockState {
                        Label(l == "locked" ? "Trancado" : "Destrancado",
                              systemImage: l == "locked" ? "lock.fill" : "lock.open.fill")
                            .font(.caption2).foregroundStyle(l == "locked" ? .green : .orange)
                    }
                }
                Spacer(minLength: 0)
                VStack(spacing: 8) {
                    if locked {
                        ctlButton(UnlockCarIntent(), "lock.open.fill", "Destravar", .orange)
                    } else {
                        ctlButton(LockCarIntent(), "lock.fill", "Travar", .green)
                    }
                    ctlButton(PreclimaIntent(), "fan.fill", "Pré-clima", .cyan)
                }
                .frame(width: 150)
            }
            .padding(6)
        }
    }

    private func ctlButton(_ intent: some AppIntent, _ icon: String, _ title: String, _ color: Color) -> some View {
        Button(intent: intent) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title).font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11).padding(.horizontal, 8)
            .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .foregroundStyle(color)
        }
        .buttonStyle(.plain)
    }

    private func socColor(_ s: Double) -> Color { s < 30 ? .orange : (s < 50 ? .yellow : .green) }
}
