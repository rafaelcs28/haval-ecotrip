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

/// AppDelegate captura cold-launch via Quick Action + registra a SceneDelegate
/// pra entregar shortcuts em warm-launches. SwiftUI iOS 13+ usa scene lifecycle,
/// então performActionFor do AppDelegate NÃO é chamado em warm-launch — Apple
/// roteia tudo via UIWindowSceneDelegate.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        if let shortcut = launchOptions?[.shortcutItem] as? UIApplicationShortcutItem {
            DispatchQueue.main.async {
                ShortcutManager.shared.receive(shortcut)
            }
        }
        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}
