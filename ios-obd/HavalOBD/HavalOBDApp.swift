import SwiftUI

@main
struct HavalOBDApp: App {
    @StateObject private var bt        = BluetoothManager()
    @StateObject private var elm       = ELM327(bt: BluetoothManager())
    @StateObject private var publisher = BridgePublisher()

    init() {
        // Mantém tela acesa enquanto o app está em foreground
        UIApplication.shared.isIdleTimerDisabled = true
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bt)
                .environmentObject(elm)
                .environmentObject(publisher)
                .preferredColorScheme(.dark)
                .onAppear {
                    publisher.bind(elm)
                }
        }
    }
}
