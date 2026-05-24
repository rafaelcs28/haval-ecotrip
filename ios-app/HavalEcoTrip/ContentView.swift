//
//  ContentView.swift
//  Tela única do app companion. Mostra:
//   - Campo URL + Campo Token (salvos em UserDefaults)
//   - Botão "Iniciar Live Activity" (cria a activity + manda pushToken pro bridge)
//   - Botão "Parar"
//   - Status atual
//
//  O app NÃO precisa ficar aberto pra Live Activity funcionar — depois de
//  iniciada, o bridge atualiza via APNs Push direto.
//
import SwiftUI

struct ContentView: View {
    @StateObject private var manager = ActivityManager()
    @State private var url:   String = Settings.bridgeURL
    @State private var token: String = Settings.bridgeToken
    @State private var showTokenPlain = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Bridge") {
                    TextField("URL (https://…)", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: url) { _, new in Settings.bridgeURL = new }
                    HStack {
                        if showTokenPlain {
                            TextField("Bearer token", text: $token)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        } else {
                            SecureField("Bearer token", text: $token)
                        }
                        Button(action: { showTokenPlain.toggle() }) {
                            Image(systemName: showTokenPlain ? "eye.slash" : "eye")
                        }
                    }
                    .onChange(of: token) { _, new in Settings.bridgeToken = new }
                    Text("O token é o mesmo `bridge_token` do PWA — copie do localStorage do Safari/Chrome.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Live Activity") {
                    HStack {
                        Text("Status")
                        Spacer()
                        Text(manager.status).foregroundStyle(.secondary)
                    }
                    Button {
                        Task { await manager.start() }
                    } label: {
                        Label("Iniciar Live Activity", systemImage: "bolt.fill")
                    }
                    .disabled(!Settings.isConfigured || manager.currentActivity != nil)

                    Button(role: .destructive) {
                        Task { await manager.stop() }
                    } label: {
                        Label("Parar Live Activity", systemImage: "stop.fill")
                    }
                    .disabled(manager.currentActivity == nil)
                }

                Section("Como funciona") {
                    Text("1. Configure URL e token acima\n2. Toque em 'Iniciar Live Activity'\n3. A activity aparece no lock screen / Dynamic Island\n4. O bridge atualiza sozinho via APNs Push — não precisa manter o app aberto")
                        .font(.caption)
                }
            }
            .navigationTitle("Haval EcoTrip")
        }
    }
}

#Preview {
    ContentView()
}
