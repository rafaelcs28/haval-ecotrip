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
    @StateObject private var shortcuts = ShortcutManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSetup = false   // sheet por cima da WebView
    @State private var preclimatTask: Task<Void, Never>? = nil

    // Loop de foreground que mantém a Live Activity da pré-climatização em dia.
    // (Em background quem cobre é o timer do ChargingKeepAlive, best-effort.)
    private func startPreclimatLoop() {
        preclimatTask?.cancel()
        preclimatTask = Task {
            while !Task.isCancelled {
                await PreClimatManager.shared.tick()
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            }
        }
    }

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
                    SetupView(manager: manager, notifPoller: notifPoller, isPresented: $showSetup)
                }
            } else {
                SetupView(manager: manager, notifPoller: notifPoller, isPresented: .constant(true))
            }
        }
        .task {
            await manager.autoStartIfCharging()
            // Notificações nativas são opt-in (padrão OFF) — o PWA standalone
            // já notifica em tempo real. Sem isso, o poller re-dispara o backlog.
            if Settings.nativeNotificationsEnabled {
                await notifPoller.requestPermission()
                notifPoller.start()
            }
            ChargingKeepAlive.shared.requestPermissionIfNeeded()
            startPreclimatLoop()
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
                if Settings.nativeNotificationsEnabled { notifPoller.start() }
                ChargingKeepAlive.shared.appDidForeground()
                ChargingKeepAlive.shared.requestPermissionIfNeeded()
                startPreclimatLoop()
            } else if newPhase == .background {
                notifPoller.stop()
                preclimatTask?.cancel()
                BackgroundRefresh.schedule()
                ChargingKeepAlive.shared.appDidBackground(
                    hasActiveCharging: manager.currentActivity != nil
                )
            }
        }
    }
}

// ── Tela de Setup / Settings ─────────────────────────────────────────────────
struct SetupView: View {
    @ObservedObject var manager: ActivityManager
    @ObservedObject var notifPoller: NotificationPoller
    @Binding var isPresented: Bool
    @State private var url:           String = Settings.bridgeURL
    @State private var token:         String = Settings.bridgeToken
    @State private var showTokenPlain = false
    @State private var keepAliveMode: Settings.KeepAliveMode = Settings.keepAliveMode
    @State private var nativeNotifs:  Bool = Settings.nativeNotificationsEnabled
    @ObservedObject private var keepAlive = ChargingKeepAlive.shared

    // Botão/indicador de permissão de localização. O texto e a ação mudam
    // conforme o status atual — refletindo a escalada em 2 passos do iOS.
    @ViewBuilder private var locationPermissionRow: some View {
        switch keepAlive.authStatus {
        case .authorizedAlways:
            Label("Localização: Sempre", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .authorizedWhenInUse:
            Button {
                keepAlive.requestAlwaysUpgrade()
            } label: {
                Label("Mudar para localização Sempre", systemImage: "location.fill")
            }
            Text("Hoje está em 'Ao Usar' — o app só segue ativo em background com 'Sempre'. Toque acima para liberar.")
                .font(.caption).foregroundStyle(.secondary)
        case .denied, .restricted:
            Button {
                keepAlive.requestAlwaysUpgrade()
            } label: {
                Label("Abrir Ajustes para permitir", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Text("Localização negada. Ative em Ajustes › Privacidade › Localização › Haval EcoTrip › Sempre.")
                .font(.caption).foregroundStyle(.secondary)
        default:   // .notDetermined
            Button {
                keepAlive.requestAlwaysUpgrade()
            } label: {
                Label("Permitir localização", systemImage: "location")
            }
            Text("O iOS pede 'Ao Usar' primeiro; depois aparece a opção 'Sempre'.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

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
                    Picker("Live Activity em background", selection: $keepAliveMode) {
                        ForEach(Settings.KeepAliveMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .onChange(of: keepAliveMode) { _, new in
                        Settings.keepAliveMode = new
                        if new != .off { keepAlive.requestPermissionIfNeeded() }
                    }
                    Text("Áudio silencioso mantém o app ativo e atualiza a Live Activity a cada 30s. Não interrompe música. 'Enquanto carrega' é o recomendado.")
                        .font(.caption).foregroundStyle(.secondary)

                    if keepAliveMode != .off {
                        locationPermissionRow
                    }
                } header: {
                    Text("Segundo plano")
                }

                Section {
                    Toggle("Notificações nativas", isOn: $nativeNotifs)
                        .onChange(of: nativeNotifs) { _, on in
                            Settings.nativeNotificationsEnabled = on
                            if on {
                                Task {
                                    await notifPoller.requestPermission()
                                    notifPoller.start()
                                }
                            } else {
                                notifPoller.stop()
                            }
                        }
                    Text("Desligado (recomendado): você recebe notificações em tempo real só pelo PWA. Ligado: o app nativo também busca o histórico e re-dispara como notificação local — útil só se você não usa o PWA na tela de início.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: {
                    Text("Notificações")
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
