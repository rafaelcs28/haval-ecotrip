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
import AuthenticationServices

// Navegação programática entre tabs (ex: card "Última viagem" no Painel → Viagens;
// "Viagem em andamento" → Drive). Índices batem com a ordem da TabView abaixo.
final class TabRouter: ObservableObject {
    static let shared = TabRouter()
    enum Tab: Int { case painel = 0, drive = 1, recargas = 2, viagens = 3, config = 4 }
    @Published var selected = 0
    func go(_ t: Tab) { selected = t.rawValue }

    private init() {
        #if DEBUG
        // Tab inicial pra screenshots no sim: defaults write ... v2_tab -int N
        let t = UserDefaults.standard.integer(forKey: "v2_tab")
        if t > 0 { selected = t }
        #endif
    }
}

struct ContentView: View {
    @StateObject private var manager = ActivityManager()
    @ObservedObject private var router = TabRouter.shared
    @StateObject private var shortcuts = ShortcutManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSetup = false   // sheet por cima da WebView
    @State private var showCancelPreclima = false   // confirmação do botão da LA
    @State private var cancellingPreclima = false
    // Observa o token no App Group: ao logar (nativo ou manual), SwiftUI
    // re-renderiza e troca da tela de login pra WebView automaticamente.
    @AppStorage("bridge_token", store: UserDefaults(suiteName: Settings.appGroupId))
    private var storedToken: String = ""
    @AppStorage("ui_v2") private var uiV2: Bool = UIv2.defaultOn

    private var bridgeURL: URL? {
        URL(string: Settings.bridgeURL.isEmpty ? AuthConfig.bridgeURL : Settings.bridgeURL)
    }

    // Altura da barra de status (safe area top) — usada pra cobrir o topo e impedir
    // que o conteúdo rolável apareça por baixo do relógio/ícones do iPhone.
    private var topSafeInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .keyWindow?.safeAreaInsets.top
            ?? 47
    }

    var body: some View {
        Group {
            if bridgeURL != nil, !storedToken.isEmpty, !Settings.bridgeURL.isEmpty {
                TabView(selection: $router.selected) {
                  Group {
                      if uiV2 { DashV2View() } else { NativeDashView() }
                  }
                    .tabItem { Label("Painel", systemImage: "gauge.with.dots.needle.bottom.50percent") }.tag(0)
                  Group {
                      if uiV2 { DriveV2View() } else { NativeDriveView() }
                  }
                    .tabItem { Label("Drive", systemImage: "steeringwheel") }.tag(1)
                  Group {
                      if uiV2 { RecargasV2View() } else { NativeRecargasView() }
                  }
                    .tabItem { Label("Recargas", systemImage: "bolt.fill") }.tag(2)
                  Group {
                      if uiV2 { ViagensV2View() } else { NativeViagensView() }
                  }
                    .tabItem { Label("Viagens", systemImage: "map.fill") }.tag(3)
                  Group {
                      if uiV2 { ConfigV2View() } else { NativeConfigView() }
                  }
                    .tabItem { Label("Config", systemImage: "gearshape.fill") }.tag(4)
                }
                .tint(DS.green)
                .tabBarMinimizeOnScroll()
                // Cobre a área da status bar com o fundo do app: o conteúdo rolável
                // some atrás dela em vez de colidir com o relógio/ícones do iPhone.
                // No iOS 26+ o scroll-edge effect + toolbar glass cuidam disso — a
                // laje opaca mataria o efeito, então só aplica nos anteriores.
                .overlay(alignment: .top) {
                    if #unavailable(iOS 26) {
                        DS.bg
                            .frame(maxWidth: .infinity)
                            .frame(height: topSafeInset)
                            .ignoresSafeArea(edges: .top)
                            .allowsHitTesting(false)
                    }
                }
                .overlay { BiometricGate() }
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
            #if DEBUG
            // Preview de LA pra screenshots no sim:
            //   defaults write <bundle> la_preview -string charge|preclimat|trip|motor|security|stop
            switch UserDefaults.standard.string(forKey: "la_preview") {
            case "charge":    LivePreview.charge()
            case "preclimat": LivePreview.preclimat()
            case "trip":      LivePreview.trip()
            case "motor":     LivePreview.motor()
            case "security":  LivePreview.security()
            case "parking":   LivePreview.parking()
            case "stop":      LivePreview.stopAll()
            default: break
            }
            UserDefaults.standard.removeObject(forKey: "la_preview")
            #endif
            await manager.autoStartIfCharging()
            // Registra os tokens APNs das Live Activities no bridge (push-to-start
            // + update). É o que permite o servidor criar/atualizar a LA com o app
            // fechado. Idempotente.
            LiveActivityPush.shared.start()
            // Notificações via APNs — pede permissão e registra no APNs (o token
            // chega no AppDelegate e vai pro bridge). O bridge manda os alertas.
            // SEMPRE chama no boot: o iOS só mostra o prompt 1x (notDetermined);
            // depois é no-op. Não depende de Settings.nativeNotificationsEnabled,
            // que pode estar dessincronizada com a pref do PWA/bridge (device novo
            // restaurado de backup mostrava o toggle ON mas nunca pedia a permissão).
            RemoteNotifications.enable()
            // Reporta posição do celular em background (significant-change + geofence
            // no carro estacionado) pra LA "voltar ao carro" ter distância/rumo frescos.
            PhoneLocationReporter.shared.start()
        }
        // URL scheme havalecotrip://open — disparado pelo SW do PWA standalone
        // quando user toca em notif Web Push.
        .onOpenURL { url in
            print("[app] aberto via URL:", url.absoluteString)
            // Botão "Cancelar" da Live Activity de pré-clima → confirma antes de agir.
            if url.host == "preclimat-cancel" || url.path == "/preclimat-cancel" {
                showCancelPreclima = true
            }
            Task { await manager.autoStartIfCharging() }
        }
        .alert("Cancelar pré-climatização?", isPresented: $showCancelPreclima) {
            Button("Não", role: .cancel) {}
            Button("Cancelar pré-clima", role: .destructive) {
                cancellingPreclima = true
                Task {
                    await CarIntentAPI.cancelPreclimat()
                    cancellingPreclima = false
                }
            }
        } message: {
            Text("Restaura o ar-condicionado ao ajuste anterior e desliga o motor (se o carro estiver parado).")
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
                LiveActivityPush.shared.reregisterAll()   // garante pts-token no servidor
            } else if newPhase == .background {
                BackgroundRefresh.schedule()
            }
        }
        // Ao logar (token salvo), re-registra os push-to-start tokens (o iOS pode
        // tê-los emitido antes do login, quando o registro foi abortado).
        .onChange(of: storedToken) { _, newToken in
            if !newToken.isEmpty { LiveActivityPush.shared.reregisterAll() }
        }
    }
}

// ── Tela de Setup / Settings ─────────────────────────────────────────────────
struct SetupView: View {
    @ObservedObject var manager: ActivityManager
    @Binding var isPresented: Bool
    @StateObject private var auth = AuthManager()
    @State private var url:           String = Settings.bridgeURL.isEmpty
        ? AuthConfig.bridgeURL : Settings.bridgeURL
    @State private var token:         String = Settings.bridgeToken
    @State private var totpCode       = ""
    @State private var showTokenPlain = false
    @State private var showAdvanced   = false
    @State private var nativeNotifs:  Bool = Settings.nativeNotificationsEnabled

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SignInWithAppleButton(.signIn) { request in
                        request.requestedScopes = [.email]
                    } onCompletion: { result in
                        auth.handleAppleResult(result, base: url)
                    }
                    .signInWithAppleButtonStyle(.white)
                    .frame(height: 46)
                    .cornerRadius(10)

                    if AuthConfig.googleEnabled {
                        Button { auth.startGoogle(base: url) } label: {
                            HStack {
                                Image(systemName: "globe")
                                Text("Entrar com Google").bold()
                            }
                            .frame(maxWidth: .infinity).frame(height: 46)
                        }
                        .buttonStyle(.bordered)
                    }

                    if auth.needsTotp {
                        TextField("Código 2FA (6 dígitos)", text: $totpCode)
                            .keyboardType(.numberPad)
                        Button("Confirmar código") { auth.submitTotp(totpCode) }
                    }
                    if auth.busy { ProgressView() }
                    if let e = auth.errorMessage {
                        Text(e).font(.caption).foregroundStyle(.red)
                    }
                } header: {
                    Text("Entrar")
                } footer: {
                    Text("Use sua conta autorizada. Sem senha — a autenticação é feita pela Apple ou Google.")
                }

                Section {
                    DisclosureGroup("Configuração manual (opcional · debug)", isExpanded: $showAdvanced) {
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
                    Button {
                        LivePreview.trip()
                        isPresented = false
                    } label: {
                        Label("Pré-visualizar · Viagem ao vivo", systemImage: "car.fill")
                    }
                    Button {
                        LivePreview.motor()
                        isPresented = false
                    } label: {
                        Label("Pré-visualizar · Motor ligado", systemImage: "key.fill")
                    }
                    Button {
                        LivePreview.security()
                        isPresented = false
                    } label: {
                        Label("Pré-visualizar · Veículo desprotegido", systemImage: "lock.open.trianglebadge.exclamationmark.fill")
                    }
                    Button {
                        LivePreview.parking()
                        isPresented = false
                    } label: {
                        Label("Pré-visualizar · Voltar ao carro", systemImage: "parkingsign")
                    }
                    Button(role: .destructive) {
                        LivePreview.stopAll()
                    } label: {
                        Label("Parar Live Activity (teste)", systemImage: "stop.circle")
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
            .onAppear {
                // Ao logar (Apple/Google) o token é gravado e a tela some;
                // se estiver aberto como sheet (já configurado), fecha.
                auth.onSuccess = { isPresented = false }
            }
        }
    }
}
