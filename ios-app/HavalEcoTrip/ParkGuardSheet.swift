//  ParkGuardSheet.swift
//  Guarda-estacionamento (antifurto): o APK arma sozinho quando o carro desliga.
//  Aqui só liga/desliga o recurso e mostra o último alarme. Detecção real e
//  blindagem contra falso positivo ficam no carro (ParkGuard) + bridge (checkTheft).

import SwiftUI

struct ParkGuardSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var enabled = false
    @State private var lastAlarmMs: Double = 0
    @State private var loaded = false
    @State private var saving = false

    private var base: String {
        let u = BridgeRouter.shared.currentURL
        return u.hasSuffix("/") ? String(u.dropLast()) : u
    }

    @State private var breathe = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    hero
                    DSCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle(isOn: $enabled) {
                                Text("Vigiar quando desligado").font(.subheadline.weight(.semibold)).foregroundStyle(DS.text)
                            }.tint(DS.green)
                            Text("Ao desligar o carro, o app dele passa a vigiar. Se o veículo for movido ou rebocado (GPS sai do lugar, confirmado, ou sensor de movimento sustentado), você recebe um push com link ao vivo da localização.")
                                .font(.system(size: 11)).foregroundStyle(DS.muted)
                        }
                    }
                    if lastAlarmMs > 0 {
                        DSCard(title: "Último alarme", icon: "exclamationmark.triangle.fill") {
                            HStack {
                                Text(Date(timeIntervalSince1970: lastAlarmMs / 1000), style: .relative)
                                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.yellow).monospacedDigit()
                                Spacer()
                                Text(Date(timeIntervalSince1970: lastAlarmMs / 1000), format: .dateTime.day().month().hour().minute())
                                    .font(.system(size: 12)).foregroundStyle(DS.muted)
                            }
                        }
                    }
                    DSActionButton(icon: "checkmark.circle.fill", title: "Salvar", color: DS.green, busy: saving) { save() }
                    Text("Desarma sozinho quando seu iPhone se aproxima.")
                        .font(.system(size: 10.5)).foregroundStyle(DS.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }
            .background(DS.bg.ignoresSafeArea())
            .navigationTitle("Guarda-estacionamento")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fechar") { dismiss() } } }
            .task { await load() }
            .onAppear { breathe = true }
        }
        .presentationDetents([.medium, .large])
    }

    // Hero: chip "armado" pulsante + carro com glow.
    private var hero: some View {
        VStack(spacing: 14) {
            ZStack {
                if enabled {
                    Circle().fill(DS.green.opacity(0.18)).frame(width: 130, height: 130).blur(radius: 20)
                        .scaleEffect(breathe ? 1.08 : 0.92)
                        .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: breathe)
                }
                Image(systemName: "car.fill")
                    .font(.system(size: 52, weight: .regular))
                    .foregroundStyle(enabled ? DS.green : DS.muted)
            }
            .frame(height: 130)
            HStack(spacing: 7) {
                if enabled {
                    Circle().fill(DS.green).frame(width: 7, height: 7)
                        .opacity(breathe ? 1 : 0.35)
                        .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: breathe)
                    Text("armado").font(.system(size: 13, weight: .bold)).foregroundStyle(DS.green)
                } else {
                    Circle().fill(DS.muted).frame(width: 7, height: 7)
                    Text("desarmado").font(.system(size: 13, weight: .bold)).foregroundStyle(DS.muted)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background((enabled ? DS.green : DS.muted).opacity(0.15)).clipShape(Capsule())
        }
        .frame(maxWidth: .infinity).padding(.top, 4)
    }

    private func load() async {
        guard !loaded, !base.isEmpty, let url = URL(string: "\(base)/api/guard/state") else { return }
        var r = URLRequest(url: url); r.timeoutInterval = 10
        r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        if let (d, resp) = try? await URLSession.shared.data(for: r),
           (resp as? HTTPURLResponse)?.statusCode == 200,
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            enabled = (j["enabled"] as? Bool) ?? false
            lastAlarmMs = (j["lastAlarmMs"] as? Double) ?? Double((j["lastAlarmMs"] as? Int) ?? 0)
        }
        loaded = true
    }

    private func save() {
        guard !base.isEmpty else { return }
        let path = enabled ? "/api/guard/arm" : "/api/guard/disarm"
        guard let url = URL(string: "\(base)\(path)") else { return }
        saving = true
        Task {
            var r = URLRequest(url: url); r.httpMethod = "POST"; r.timeoutInterval = 10
            r.addValue("application/json", forHTTPHeaderField: "Content-Type")
            r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
            r.httpBody = try? JSONSerialization.data(withJSONObject: ["enabled": enabled])
            _ = try? await URLSession.shared.data(for: r)
            saving = false
            dismiss()
        }
    }
}
