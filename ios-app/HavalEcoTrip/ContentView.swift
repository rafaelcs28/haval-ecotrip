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
    @Environment(\.scenePhase) private var scenePhase
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
                    Text("1. Configure URL e token acima\n2. Toque em 'Iniciar Live Activity' (1ª vez)\n3. A activity aparece no lock screen / Dynamic Island\n4. App faz polling a cada 5s enquanto aberto\n\nDica: ao abrir o app, se o carro JÁ está carregando, a Activity dispara sozinha. Combine com um atalho de Automação ('Quando conectar ao WiFi de casa → Abrir Haval EcoTrip') pra ficar quase 100% automático.")
                        .font(.caption)
                }
            }
            .navigationTitle("Haval EcoTrip")
            // Auto-start ao abrir o app: se o carro está carregando, cria a
            // Activity sem precisar de toque. Funciona em combinação com
            // Atalhos Automation que abre o app no evento certo.
            .task { await manager.autoStartIfCharging() }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    Task { await manager.autoStartIfCharging() }
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
