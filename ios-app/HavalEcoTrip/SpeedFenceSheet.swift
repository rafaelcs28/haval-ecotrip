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
        let u = Settings.bridgeURL.isEmpty ? AuthConfig.bridgeURL : Settings.bridgeURL
        return u.hasSuffix("/") ? String(u.dropLast()) : u
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    DSCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle(isOn: Binding(get: { kmh > 0 }, set: { kmh = $0 ? max(kmh, 100) : 0 })) {
                                Text("Alertar acima do limite").font(.subheadline.weight(.semibold)).foregroundStyle(DS.text)
                            }.tint(DS.green)
                            if kmh > 0 {
                                HStack {
                                    Text("Limite").font(.callout).foregroundStyle(DS.muted)
                                    Spacer()
                                    Text("\(Int(kmh)) km/h").font(.title3.weight(.bold)).foregroundStyle(DS.teal)
                                }
                                Slider(value: $kmh, in: 60...160, step: 5).tint(DS.teal)
                            }
                            Text("Quando o carro passar de \(kmh > 0 ? "\(Int(kmh)) km/h" : "—"), você recebe um push. Bom pra acompanhar quando um filho ou manobrista dirige.")
                                .font(.caption2).foregroundStyle(DS.muted)
                        }
                    }
                    DSActionButton(icon: "checkmark.circle.fill", title: "Salvar", color: DS.green, busy: saving) { save() }
                }
                .padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Cerca de velocidade")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fechar") { dismiss() } } }
            .task { await load() }
        }
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
