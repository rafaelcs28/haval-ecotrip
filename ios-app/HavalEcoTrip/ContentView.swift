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
//  As Live Activities (recarga + pré-climatização) são dirigidas pelo BRIDGE via
//  APNs (push-to-start + updates) — ver LiveActivityPush. Não há mais keep-alive
//  de localização/áudio.
//
import SwiftUI

struct ContentView: View {
    @StateObject private var manager = ActivityManager()
    @StateObject private var shortcuts = ShortcutManager.shared
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
            // Registra os tokens APNs das Live Activities no bridge (push-to-start
            // + update). É o que permite o servidor criar/atualizar a LA com o app
            // fechado. Idempotente.
            LiveActivityPush.shared.start()
            // Notificações via APNs — pede permissão e registra no APNs (o token
            // chega no AppDelegate e vai pro bridge). O bridge manda os alertas.
            if Settings.nativeNotificationsEnabled {
                RemoteNotifications.enable()
            }
        }
        // URL scheme havalecotrip://open — disparado pelo SW do PWA standalone
        // quando user toca em notif Web Push.
        .onOpenURL { url in
            print("[app] aberto via URL:", url.absoluteString)
            Task { await manager.autoStartIfCharging() }
        }
        // Quick Actions (3D Touch no ícone) — postam em ShortcutManager.shared
        // via SceneDelegate. Aqui observamos e despachamos pra CarActions.
        .onReceive(shortcuts.$pendingAction.compactMap { $0 }) { action in
            shortcuts.pendingAction = nil
            Task { await CarActions.run(action) }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await manager.autoStartIfCharging() }
            } else if newPhase == .background {
                BackgroundRefresh.schedule()
            }
        }
    }
}

// ── Tela de Setup / Settings ─────────────────────────────────────────────────
struct SetupView: View {
    @ObservedObject var manager: ActivityManager
    @Binding var isPresented: Bool
    @State private var url:           String = Settings.bridgeURL
    @State private var token:         String = Settings.bridgeToken
    @State private var showTokenPlain = false
    @State private var nativeNotifs:  Bool = Settings.nativeNotificationsEnabled

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

                Section {
                    Toggle("Notificações", isOn: $nativeNotifs)
                        .onChange(of: nativeNotifs) { _, on in
                            Settings.nativeNotificationsEnabled = on
                            if on { RemoteNotifications.enable() }
                        }
                    Text("Recebe as notificações do carro direto neste app via APNs. Para desativar de vez, use Ajustes › Notificações › Haval EcoTrip.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: {
                    Text("Notificações")
                }

                Section {
                    Button {
                        LivePreview.charge()
                        isPresented = false
                    } label: {
                        Label("Pré-visualizar · Recarga", systemImage: "bolt.car.fill")
                    }
                    Button {
                        LivePreview.preclimat()
                        isPresented = false
                    } label: {
                        Label("Pré-visualizar · Pré-climatização", systemImage: "snowflake")
                    }
                    Text("Mostra a Live Activity localmente (sem push) pra validar o layout. Bloqueie a tela pra ver o card.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: {
                    Text("Pré-visualizar Live Activities")
                }

                Section("Como funciona") {
                    Text("Esse app é o PWA inteiro dentro de um wrapper nativo. Pra reabrir essas configurações: pressione e segure com 3 dedos por 1 segundo em qualquer parte da tela.\n\nAs Live Activities (recarga e pré-climatização) são iniciadas e atualizadas pelo servidor via push — aparecem mesmo com o app fechado.")
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
