import SwiftUI

@main
struct HavalOBDApp: App {
    @StateObject private var bt:        BluetoothManager
    @StateObject private var elm:       ELM327
    @StateObject private var publisher = BridgePublisher()
    @StateObject private var channel   = OBDBridgeChannel()

    init() {
        let bluetooth = BluetoothManager()
        _bt  = StateObject(wrappedValue: bluetooth)
        _elm = StateObject(wrappedValue: ELM327(bt: bluetooth))
        // Mantém tela acesa em foreground (cluster é always-on)
        UIApplication.shared.isIdleTimerDisabled = true
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(bt)
                .environmentObject(elm)
                .environmentObject(publisher)
                .environmentObject(channel)
                .preferredColorScheme(.dark)
                .ignoresSafeArea()
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
                .onAppear {
                    publisher.bind(elm)
                    publisher.autoConnectIfConfigured()
                }
        }
    }
}

/// Root — cluster fullscreen + 3 maneiras de abrir settings:
///   1. Botão flutuante visível (engrenagem) no canto superior direito
///   2. Hotspot ampliado 120×120 nesse mesmo canto (toque longo 0.6s)
///   3. Triplo tap em qualquer lugar da tela
struct RootView: View {
    @State private var showSettings = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ClusterWebView()
                .ignoresSafeArea()
                // Triplo tap em qualquer parte → abre settings (acesso alternativo)
                .onTapGesture(count: 3) { showSettings = true }

            // Hotspot 120×120 + long-press 0.6s (mais permissivo que antes)
            Color.clear
                .frame(width: 120, height: 120)
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0.6) {
                    showSettings = true
                }

            // Botão visível mas discreto — toque rápido abre settings
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
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }
}
