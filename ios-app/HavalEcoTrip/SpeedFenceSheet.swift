//  SpeedFenceSheet.swift
//  Cerca de velocidade: define um limite; o bridge avisa por push quando o carro
//  passa dele (útil quando outra pessoa dirige). 0 = desligado.

import SwiftUI

struct SpeedFenceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var kmh: Double = 0
    @State private var loaded = false
    @State private var saving = false

    private var base: String {
        let u = BridgeRouter.shared.currentURL
        return u.hasSuffix("/") ? String(u.dropLast()) : u
    }

    private var on: Bool { kmh > 0 }

    private func bump(_ delta: Double) {
        let v = (kmh > 0 ? kmh : 100) + delta
        kmh = min(160, max(60, v))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    // Hero: limite em numeral fino com ± de 44px.
                    VStack(spacing: 14) {
                        if on {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("\(Int(kmh))").font(.system(size: 68, weight: .ultraLight, design: .rounded))
                                    .monospacedDigit().foregroundStyle(DS.teal)
                                Text("km/h").font(.system(size: 18, weight: .semibold)).foregroundStyle(DS.muted)
                            }
                            HStack(spacing: 16) {
                                stepButton("minus", DS.blue) { bump(-5) }
                                stepButton("plus", DS.orange) { bump(5) }
                            }
                        } else {
                            Text("Cerca desligada").font(.system(size: 20, weight: .light)).foregroundStyle(DS.muted)
                                .frame(height: 86)
                        }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 8)

                    // Regra explícita.
                    if on {
                        DSCard {
                            HStack(spacing: 10) {
                                Image(systemName: "gauge.with.dots.needle.67percent").foregroundStyle(DS.teal)
                                Text("Avisa se passar de \(Int(kmh)) km/h por 10 s")
                                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.text)
                                Spacer()
                            }
                        }
                    }

                    DSActionButton(icon: on ? "bell.fill" : "checkmark.circle.fill",
                                   title: "Salvar", color: DS.green, busy: saving) { save() }

                    Text("Quem dirige sabe da cerca · avisado no head-unit. Bom pra acompanhar quando outra pessoa dirige.")
                        .font(.system(size: 10.5)).foregroundStyle(DS.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Cerca de velocidade")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Toggle("", isOn: Binding(get: { on }, set: { kmh = $0 ? max(kmh, 100) : 0 }))
                        .labelsHidden().tint(DS.green)
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Fechar") { dismiss() } }
            }
            .task { await load() }
        }
        .presentationDetents([.medium, .large])
    }

    private func stepButton(_ icon: String, _ color: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 20, weight: .bold)).foregroundStyle(color)
                .frame(width: 44, height: 44)
                .background(DS.panel).clipShape(Circle())
                .overlay(Circle().stroke(DS.border, lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private func load() async {
        guard !loaded, !base.isEmpty, let url = URL(string: "\(base)/api/speed-fence") else { return }
        var r = URLRequest(url: url); r.timeoutInterval = 10
        r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        if let (d, resp) = try? await URLSession.shared.data(for: r),
           (resp as? HTTPURLResponse)?.statusCode == 200,
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            kmh = (j["kmh"] as? Double) ?? Double((j["kmh"] as? Int) ?? 0)
        }
        loaded = true
    }

    private func save() {
        guard !base.isEmpty, let url = URL(string: "\(base)/api/speed-fence") else { return }
        saving = true
        Task {
            var r = URLRequest(url: url); r.httpMethod = "POST"; r.timeoutInterval = 10
            r.addValue("application/json", forHTTPHeaderField: "Content-Type")
            r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
            r.httpBody = try? JSONSerialization.data(withJSONObject: ["kmh": Int(kmh)])
            _ = try? await URLSession.shared.data(for: r)
            saving = false
            dismiss()
        }
    }
}
