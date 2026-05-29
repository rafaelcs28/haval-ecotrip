import SwiftUI

@main
struct HavalOBDApp: App {
    @StateObject private var bt:        BluetoothManager
    @StateObject private var elm:       ELM327
    @StateObject private var publisher = BridgePublisher()
    @StateObject private var channel   = OBDBridgeChannel()
    @StateObject private var discovery = OBDDiscovery()

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
                .preferredColorScheme(.dark)
                .ignoresSafeArea()
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
                .onAppear {
                    publisher.bind(elm)
                    publisher.autoConnectIfConfigured()
                    discovery.bind(elm: elm)
                }
        }
    }
}

/// Root — cluster fullscreen + 3 maneiras de abrir settings:
///   1. Botão flutuante visível (engrenagem) no canto superior direito
///   2. Hotspot ampliado 120×120 nesse mesmo canto (toque longo 0.6s)
///   3. Triplo tap em qualquer lugar da tela
struct RootView: View {
    @EnvironmentObject var channel: OBDBridgeChannel
    @State private var showSettings = false
    @State private var splashHidden = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ClusterWebView()
                .ignoresSafeArea()
                .onTapGesture(count: 3) { showSettings = true }

            // Splash com logo enquanto o cluster.html carrega.
            // Some quando channel.webViewReady vira true (cluster terminou
            // de carregar e _nativeBridge foi injetado).
            if !splashHidden {
                SplashView()
                    .ignoresSafeArea()
                    .transition(.opacity)
            }

            // Hotspot 120×120 + long-press 0.6s
            Color.clear
                .frame(width: 120, height: 120)
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0.6) {
                    showSettings = true
                }

            // Botão visível
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 1))
                    .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 2)
            }
            .padding(.top, 12)
            .padding(.trailing, 12)
            .opacity(splashHidden ? 1 : 0)
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .onChange(of: channel.webViewReady) { _, ready in
            if ready {
                // Fade out suave do splash 200ms depois do cluster estar pronto
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    withAnimation(.easeOut(duration: 0.4)) { splashHidden = true }
                }
            }
        }
        // Fallback: se webViewReady demorar muito (>5s), some o splash assim mesmo
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                if !splashHidden { withAnimation(.easeOut(duration: 0.4)) { splashHidden = true } }
            }
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
