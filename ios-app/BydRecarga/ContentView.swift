//
//  ContentView.swift
//  Tela única do app BYD Recarga: setup (URL + token) → status + toggle da LA.
//
import SwiftUI

struct ContentView: View {
    @State private var configured = BydSettings.isConfigured
    @State private var urlField = BydSettings.bridgeURL
    @State private var tokenField = BydSettings.bridgeToken
    @State private var laOn = false
    @State private var statusMsg = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                if !configured {
                    setupSection
                } else {
                    statusSection
                    laSection
                    Section {
                        Button("Reconfigurar", role: .destructive) {
                            configured = false
                            statusMsg = ""
                        }
                    }
                }
                if !statusMsg.isEmpty {
                    Section { Text(statusMsg).font(.callout).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("BYD Recarga")
        }
        .task {
            if configured {
                BydRemoteNotifications.enable()
                BydLiveActivityPush.shared.start()
                await fetchPref()
            }
        }
    }

    // ── Setup inicial ─────────────────────────────────────────────────────
    private var setupSection: some View {
        Section("Configuração") {
            TextField("URL do bridge (https://…)", text: $urlField)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                .keyboardType(.URL)
            SecureField("Token / senha do bridge", text: $tokenField)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
            Button("Salvar e ativar") {
                BydSettings.bridgeURL = urlField
                BydSettings.bridgeToken = tokenField
                guard BydSettings.isConfigured else {
                    statusMsg = "Preencha URL e token."
                    return
                }
                configured = true
                statusMsg = "✓ Configurado. Ativando notificações…"
                BydRemoteNotifications.enable()
                BydLiveActivityPush.shared.start()
                Task { await setPref(true) }
            }
            .disabled(urlField.isEmpty || tokenField.isEmpty)
            Text("Use a mesma URL e token do app principal do Haval. O device é registrado só pra Live Activity da recarga do BYD.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // ── Status ────────────────────────────────────────────────────────────
    private var statusSection: some View {
        Section("Status") {
            LabeledContent("Bridge") {
                Text(BydSettings.bridgeURL).font(.caption.monospaced())
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            LabeledContent("Device") {
                Text(BydSettings.deviceId.suffix(12)).font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var laSection: some View {
        Section("Live Activity da recarga") {
            Toggle("Mostrar recarga do BYD", isOn: Binding(
                get: { laOn },
                set: { v in laOn = v; Task { await setPref(v) } }
            )).disabled(busy)
            Text("Quando o BYD Song Pro começar a carregar, aparece a Live Activity azul na tela de bloqueio e Dynamic Island com SOC, potência e tempo restante.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // ── Bridge: preferência la_songpro ─────────────────────────────────────
    private func fetchPref() async {
        guard let url = URL(string: BydSettings.baseURL + "/api/notif/prefs/" + BydSettings.deviceId) else { return }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.addValue("Bearer " + BydSettings.bridgeToken, forHTTPHeaderField: "Authorization")
        if let (data, resp) = try? await URLSession.shared.data(for: req),
           (resp as? HTTPURLResponse)?.statusCode == 200,
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let prefs = obj["prefs"] as? [String: Any] {
            await MainActor.run { laOn = (prefs["la_songpro"] as? Bool) ?? false }
        }
    }

    private func setPref(_ on: Bool) async {
        await MainActor.run { busy = true }
        defer { Task { @MainActor in busy = false } }
        guard let url = URL(string: BydSettings.baseURL + "/api/notif/prefs/" + BydSettings.deviceId) else { return }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = "POST"
        req.addValue("Bearer " + BydSettings.bridgeToken, forHTTPHeaderField: "Authorization")
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["key": "la_songpro", "value": on])
        if let (_, resp) = try? await URLSession.shared.data(for: req),
           (resp as? HTTPURLResponse)?.statusCode == 200 {
            await MainActor.run { statusMsg = on ? "✓ Live Activity ativada" : "Live Activity desativada" }
        } else {
            await MainActor.run { statusMsg = "⚠ Falha ao falar com o bridge. Confira URL/token." }
        }
    }
}
