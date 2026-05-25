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
        .task { await manager.autoStartIfCharging() }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await manager.autoStartIfCharging() }
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

                Section("Live Activity") {
                    HStack {
                        Text("Status").foregroundStyle(.secondary)
                        Spacer()
                        Text(manager.status).font(.callout)
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
                    Text("Esse app é o PWA inteiro dentro de um wrapper nativo. Pra reabrir essas configurações: pressione e segure com 3 dedos por 1 segundo em qualquer parte da tela.")
                        .font(.caption)
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
