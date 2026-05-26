//
//  HavalEcoTripApp.swift
//  Entry point do app companion iOS. App em si é minimalíssimo — toda a UX
//  acontece na Live Activity (lock screen + Dynamic Island). O app só serve
//  pra registrar o pushToken da activity no bridge.
//
import SwiftUI
import UIKit
import UserNotifications

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
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        // Registra como delegate de notificações para controlar apresentação
        // em foreground (evitar banner para updates silenciosos de carga).
        UNUserNotificationCenter.current().delegate = self

        if let shortcut = launchOptions?[.shortcutItem] as? UIApplicationShortcutItem {
            DispatchQueue.main.async {
                ShortcutManager.shared.receive(shortcut)
            }
        }
        return true
    }

    // Controla como notificações são exibidas quando o app está em foreground.
    // Para charge_live (updates ao vivo de carga), suprime o banner — a notif
    // vai só para a central, sem interromper o user. O background já é tratado
    // pelo apns-interruption-level: passive enviado pelo servidor.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                 willPresent notification: UNNotification,
                                 withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let info = notification.request.content.userInfo
        // O SW passa data: { type, soc, pwr, rem, kwh } → iOS armazena em userInfo
        let data = (info["data"] as? [String: Any]) ?? [:]
        let type = (info["type"] as? String) ?? (data["type"] as? String)

        if type == "charge_live" {
            // Atualiza a Live Activity diretamente do payload — sem fetch.
            // Cobre o caso em que o app está aberto mas o pushType:nil não tem
            // canal de push pro servidor atualizar em background.
            let soc = (data["soc"] as? Double) ?? 0
            let pwr = (data["pwr"] as? Double) ?? 0
            let rem = (data["rem"] as? Double) ?? 0
            let kwh = (data["kwh"] as? Double) ?? 0
            if soc > 0 || pwr > 0 {
                Task { await ActivityManager.updateFromPayload(soc: soc, pwr: pwr, rem: rem, kwh: kwh) }
            }
            completionHandler([.list])   // silencioso, sem banner, só central
        } else {
            completionHandler([.banner, .sound, .list, .badge])
        }
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}
