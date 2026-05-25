//
//  HavalEcoTripApp.swift
//  Entry point do app companion iOS. App em si é minimalíssimo — toda a UX
//  acontece na Live Activity (lock screen + Dynamic Island). O app só serve
//  pra registrar o pushToken da activity no bridge.
//
import SwiftUI
import UIKit

@main
struct HavalEcoTripApp: App {
    // AppDelegate adaptor pra capturar Quick Actions (3D/Haptic Touch no ícone).
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // Migra URL/token de versões antigas (UserDefaults.standard) pro
        // App Group novo — sem isso o widget aparece vazio e o user precisa
        // re-colar tudo. Idempotente.
        Settings.migrateFromStandardIfNeeded()
        // Registra handler de BG refresh ANTES de qualquer view aparecer.
        // Sem isso, iOS não acorda o app em background pra polling de notifs.
        BackgroundRefresh.register()
    }
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// Captura Quick Actions (Home Screen Shortcuts) e converte em URL scheme
/// havalecotrip://action/<name>. O ContentView.onOpenURL processa a URL,
/// chama o backend (/api/action/<name>) e dispara Local Notification com
/// o resultado.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        // Cold-launch via Quick Action: precisa processar aqui (performActionFor
        // não dispara nesse caso). Posta numa fila pra processar quando a view
        // estiver pronta.
        if let shortcut = launchOptions?[.shortcutItem] as? UIApplicationShortcutItem {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.handleShortcut(shortcut)
            }
        }
        return true
    }

    func application(_ application: UIApplication,
                     performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        handleShortcut(shortcutItem)
        completionHandler(true)
    }

    private func handleShortcut(_ shortcut: UIApplicationShortcutItem) {
        let action = (shortcut.userInfo?["action"] as? String) ?? ""
        guard !action.isEmpty else { return }
        if let url = URL(string: "havalecotrip://action/\(action)") {
            UIApplication.shared.open(url)
        }
    }
}
