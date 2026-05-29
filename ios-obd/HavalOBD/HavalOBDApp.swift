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
                .onAppear { publisher.bind(elm) }
        }
    }
}

/// Root — cluster fullscreen + hotspot invisível pra abrir settings.
struct RootView: View {
    @State private var showSettings = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ClusterWebView()
                .ignoresSafeArea()
            // Hotspot transparente 60×60 no canto superior direito.
            // Toque longo de 1s abre as settings — protege contra abertura
            // acidental enquanto dirigindo.
            Color.clear
                .frame(width: 60, height: 60)
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 1.0) {
                    showSettings = true
                }
                .padding(.top, 8)
                .padding(.trailing, 8)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }
}
