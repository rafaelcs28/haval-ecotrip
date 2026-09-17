import SwiftUI

@main
struct HavalOBDApp: App {
    @StateObject private var bt:        BluetoothManager
    @StateObject private var elm:       ELM327
    @StateObject private var publisher = BridgePublisher()
    @StateObject private var channel   = OBDBridgeChannel()
    @StateObject private var discovery = OBDDiscovery()
    @StateObject private var location  = LocationManager()
    @StateObject private var lanDisc   = LocalDiscovery()

    init() {
        let bluetooth = BluetoothManager()
        _bt  = StateObject(wrappedValue: bluetooth)
        _elm = StateObject(wrappedValue: ELM327(bt: bluetooth))
        UIApplication.shared.isIdleTimerDisabled = true
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(bt)
                .environmentObject(elm)
                .environmentObject(publisher)
                .environmentObject(channel)
                .environmentObject(discovery)
                .environmentObject(location)
                .environmentObject(lanDisc)
                .preferredColorScheme(.dark)
                .ignoresSafeArea()
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
                .onAppear {
                    publisher.bind(elm)
                    publisher.autoConnectIfConfigured()
                    discovery.bind(elm: elm)
                    channel.bind(location: location)
                    location.start()
                    // Injeta state recebido (MQTT ou HTTP) no cluster.html
                    publisher.onClusterExtra = { [channel] dict in
                        channel.injectExtra(dict)
                    }
                    // Bridge HTTP — fonte PRINCIPAL agora (igual PWA).
                    // Faz GET /api/state com Bearer token a cada 1s.
                    publisher.restartHttpPoll()
                    // ── LAN direta carro↔iPad (descoberta mDNS) ───────────
                    // Quando achar APK na LAN, BridgePublisher conecta WS
                    // local pra telemetria fast (~5ms) e usa POST direto pros
                    // comandos. Fallback automático pra Tailscale.
                    lanDisc.setEnabled(publisher.useLanWhenAvailable)
                    // Repassa o URL descoberto pro publisher
                    Task { @MainActor in
                        for await url in lanDisc.$localUrl.values {
                            publisher.updateLanUrl(url)
                        }
                    }
                }
        }
    }
}

/// Abas do Cockpit. Deslizar com dois dedos anda entre elas; o conteúdo ocupa a
/// tela inteira do iPad, sem ficar dentro de cartão nenhum.
enum AbaCockpit: Int, CaseIterable {
    case painel, carro3d
    var titulo: String { self == .painel ? "Painel" : "Carro em 3D" }
}

/// Aba pedida de fora do RootView (botão dos ajustes). Gesto é rápido mas
/// invisível: sem um caminho visível, quem não souber do gesto não acha o 3D.
final class AbaPedida: ObservableObject {
    static let shared = AbaPedida()
    @Published var aba: AbaCockpit? = nil
    private init() {}
}

/// Root — cluster fullscreen + 3 maneiras de abrir settings:
///   1. Botão flutuante visível (engrenagem) no canto superior direito
///   2. Hotspot ampliado 120×120 nesse mesmo canto (toque longo 0.6s)
///   3. Triplo tap em qualquer lugar da tela
struct RootView: View {
    @EnvironmentObject var channel:   OBDBridgeChannel
    @EnvironmentObject var bt:        BluetoothManager
    @EnvironmentObject var elm:       ELM327
    @StateObject  private var nav     = NavigationService()
    @State private var showSettings   = false
    @State private var showNav        = false
    @State private var aba: AbaCockpit = .painel
    @ObservedObject private var pedida = AbaPedida.shared
    /// O visualizador 3D baixa ~92 MB na primeira abertura. Monta na primeira vez
    /// que a aba é pedida e NUNCA desmonta — trocar de aba não pode recarregar
    /// aquilo. Por isso as duas ficam vivas e quem alterna é a opacidade.
    @State private var montou3D      = false
    @State private var avisoAba: String? = nil
    @State private var splashHidden   = false
    @State private var initInFlight   = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Fundo preto sólido (mapa removido — app é cluster puro)
            Color.black.ignoresSafeArea()

            ClusterWebView()
                .ignoresSafeArea()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onTapGesture(count: 3) { showSettings = true }
                .opacity(aba == .painel ? 1 : 0)
                .allowsHitTesting(aba == .painel)

            if montou3D {
                Carro3DView()
                    .ignoresSafeArea()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(aba == .carro3d ? 1 : 0)
                    .allowsHitTesting(aba == .carro3d)
            }

            // Splash com logo enquanto o cluster.html carrega.
            // Some quando channel.webViewReady vira true (cluster terminou
            // de carregar e _nativeBridge foi injetado).
            if !splashHidden {
                SplashView()
                    .ignoresSafeArea()
                    .transition(.opacity)
            }

            // Config: agora pelo botão ⚙ da topbar do cluster (action open_settings)
            // + triplo-toque na tela. O botão nativo grande foi removido (era duplicado).

            // Overlay de navegação sobre o cluster (não cobre tudo)
            if showNav {
                NavigationOverlay(nav: nav, isPresented: $showNav)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if let aviso = avisoAba {
                Text(aviso)
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 28)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .background(DoisDedosSwipe { passo in troca(passo) })
        // Tela cheia, não `.sheet`: no iPad o sheet vira cartão no meio da tela —
        // era o que deixava o carro em 3D espremido num quadrado.
        .fullScreenCover(isPresented: $showSettings) { SettingsView() }
        .onChange(of: pedida.aba) { _, nova in
            guard let nova, nova != aba else { return }
            if nova == .carro3d { montou3D = true }
            withAnimation(.easeOut(duration: 0.18)) { aba = nova }
            pedida.aba = nil
        }
        .onChange(of: channel.navRequestId) { old, new in
            if new > old { withAnimation(.spring(response: 0.3)) { showNav = true } }
        }
        .onChange(of: channel.settingsRequestId) { old, new in
            if new > old { showSettings = true }
        }
        .onChange(of: channel.webViewReady) { _, ready in
            if ready {
                // Fade out suave do splash 200ms depois do cluster estar pronto
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    withAnimation(.easeOut(duration: 0.4)) { splashHidden = true }
                }
            }
        }
        // App em modo SERVIDOR — toda telemetria vem via MQTT do bridge.
        // BLE/ELM desativados (podem ser reativados via Settings se quiser).
        .onAppear {
            // Gancho de teste: o simulador não injeta toque de dois dedos, então é
            // assim que a aba 3D é conferida sem device na mão.
            //   xcrun simctl launch <sim> <bundle> -aba carro3d
            if ProcessInfo.processInfo.arguments.contains("carro3d") {
                montou3D = true; aba = .carro3d
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                if !splashHidden { withAnimation(.easeOut(duration: 0.3)) { splashHidden = true } }
            }
        }
    }

    private func troca(_ passo: Int) {
        let todas = AbaCockpit.allCases
        let nova = todas[(aba.rawValue + passo + todas.count) % todas.count]
        guard nova != aba else { return }
        if nova == .carro3d { montou3D = true }
        withAnimation(.easeOut(duration: 0.18)) { aba = nova }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        // Aviso curto: sem ele, quem deslizou sem querer não entende o que mudou.
        withAnimation(.easeOut(duration: 0.15)) { avisoAba = nova.titulo }
        let titulo = nova.titulo
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if avisoAba == titulo { withAnimation(.easeIn(duration: 0.3)) { avisoAba = nil } }
        }
    }
}

/// Splash com a marca do app — fica visível enquanto o cluster.html carrega.
struct SplashView: View {
    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 18) {
                // Anel pulsante simulando o ícone
                ZStack {
                    Circle()
                        .stroke(Color(red: 0.13, green: 0.77, blue: 0.37), lineWidth: 4)
                        .frame(width: 110, height: 110)
                        .opacity(0.4)
                    Circle()
                        .trim(from: 0, to: 0.75)
                        .stroke(LinearGradient(
                            colors: [Color(red: 0.02, green: 0.71, blue: 0.83),
                                     Color(red: 0.13, green: 0.77, blue: 0.37)],
                            startPoint: .topLeading, endPoint: .bottomTrailing),
                            style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .frame(width: 110, height: 110)
                        .rotationEffect(.degrees(-90))
                        .shadow(color: Color(red: 0.13, green: 0.77, blue: 0.37).opacity(0.6), radius: 10)
                    VStack(spacing: 2) {
                        Text("GWM").font(.system(size: 28, weight: .black))
                            .foregroundStyle(.white)
                        Text("CLUSTER")
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(3)
                            .foregroundStyle(Color(red: 0.13, green: 0.77, blue: 0.37))
                    }
                }
                ProgressView()
                    .tint(.white.opacity(0.4))
                    .scaleEffect(0.8)
            }
        }
    }
}
