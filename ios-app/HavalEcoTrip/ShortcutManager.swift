//
//  ShortcutManager.swift
//  Centraliza Quick Actions (Home Screen Shortcuts) pra app SwiftUI. iOS 13+
//  com SwiftUI usa UIWindowSceneDelegate pra entregar shortcuts; o AppDelegate
//  sozinho não captura warm-launches. Padrão:
//    - SceneDelegate.windowScene(_:performActionFor:) posta no manager
//    - AppDelegate.didFinishLaunchingWithOptions[.shortcutItem] posta tb (cold)
//    - ContentView observa via @StateObject e despacha CarActions.run()
//
import Foundation
import UIKit

@MainActor
final class ShortcutManager: ObservableObject {
    static let shared = ShortcutManager()
    private init() {}

    /// Última ação solicitada via shortcut. ContentView limpa ao processar.
    @Published var pendingAction: String?

    func receive(_ item: UIApplicationShortcutItem) {
        let action = (item.userInfo?["action"] as? String) ?? ""
        guard !action.isEmpty else { return }
        pendingAction = action
    }
}

// ── SceneDelegate (warm-launch + foreground) ─────────────────────────────────
final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        // Cold-launch via shortcut também passa por aqui em iOS 13+
        if let item = connectionOptions.shortcutItem {
            DispatchQueue.main.async { ShortcutManager.shared.receive(item) }
        }
    }

    func windowScene(_ windowScene: UIWindowScene,
                     performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        ShortcutManager.shared.receive(shortcutItem)
        completionHandler(true)
    }
}
