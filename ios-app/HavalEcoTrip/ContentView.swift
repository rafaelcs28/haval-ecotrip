//
//  ContentView.swift
//  Modos:
//   - Sem URL configurada → mostra SetupView (form de URL + token)
//   - Com URL → carrega o PWA inteiro numa WKWebView fullscreen.
//
//  Pra reabrir o Setup (trocar URL/token): long-press com 3 dedos por 1 segundo
//  em qualquer lugar abre a sheet de Settings. Também pode ser disparado pelo
//  próprio PWA via window.HavalNative.openSettings().
//
import SwiftUI

struct ContentView: View {
    @StateObject private var manager = ActivityManager()
    @StateObject private var notifPoller = NotificationPoller()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSetup = false   // sheet por cima da WebView

    private var bridgeURL: URL? {
        URL(string: Settings.bridgeURL)
    }

    var body: some View {
        Group {
            if let url = bridgeURL, Settings.isConfigured {
                ZStack {
                    PwaWebView(url: url, manager: manager)
                        .ignoresSafeArea()
                    // Indicador discreto da Live Activity (não invasivo)
                    if manager.currentActivity != nil {
                        VStack {
                            HStack {
                                Spacer()
                                Image(systemName: "bolt.fill")
                                    .font(.caption)
                                    .padding(6)
                                    .background(Color.green.opacity(0.85))
                                    .foregroundStyle(.black)
                                    .clipShape(Circle())
                                    .padding(.top, 60)
                                    .padding(.trailing, 12)
                            }
                            Spacer()
                        }
                    }
                }
                // Long-press com 3 dedos por 1s abre Settings. Gesto invisível
                // pro user normal, fácil pra dev.
                .onLongPressGesture(minimumDuration: 1.0,
                                    maximumDistance: 30) {
                    showSetup = true
                }
                .onReceive(NotificationCenter.default.publisher(for: .openHavalSettings)) { _ in
                    showSetup = true
                }
                .sheet(isPresented: $showSetup) {
                    SetupView(manager: manager, isPresented: $showSetup)
                }
            } else {
                SetupView(manager: manager, isPresented: .constant(true))
            }
        }
        .task {
            await manager.autoStartIfCharging()
            await notifPoller.requestPermission()
            notifPoller.start()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await manager.autoStartIfCharging() }
                notifPoller.start()
            } else if newPhase == .background {
                notifPoller.stop()
            }
        }
    }
}

// ── Tela de Setup / Settings ─────────────────────────────────────────────────
struct SetupView: View {
    @ObservedObject var manager: ActivityManager
    @Binding var isPresented: Bool
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
                    Text("Mesmo bridge_token do PWA. Copia do localStorage do Safari/Chrome.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Como funciona") {
                    Text("Esse app é o PWA inteiro dentro de um wrapper nativo. Pra reabrir essas configurações: pressione e segure com 3 dedos por 1 segundo em qualquer parte da tela.\n\nA Live Activity é controlada direto pelo Dash → 'Recarga em andamento'. Auto-start quando o carro começa a carregar e o app está aberto.")
                        .font(.caption)
                    if manager.currentActivity != nil {
                        HStack {
                            Image(systemName: "bolt.fill").foregroundStyle(.green)
                            Text("Live Activity ativa")
                            Spacer()
                            Button("Parar") { Task { await manager.stop() } }
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .navigationTitle(Settings.isConfigured ? "Configurações" : "Configuração inicial")
            .toolbar {
                if Settings.isConfigured {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Concluído") { isPresented = false }
                    }
                }
            }
        }
    }
}
