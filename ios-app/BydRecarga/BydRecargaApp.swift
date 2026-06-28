//
//  BydRecargaApp.swift
//  App minimal dedicado à Live Activity da recarga do BYD Song Pro.
//  Função única: registrar tokens APNs no bridge e exibir status da recarga.
//
import SwiftUI
import UserNotifications

@main
struct BydRecargaApp: App {
    @UIApplicationDelegateAdaptor(BydAppDelegate.self) var appDelegate
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}

final class BydAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        BydSettings.migrateURLIfNeeded()
        return true
    }

    /// Device token APNs (push normal) — registrado no bridge pra notificações.
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await BydRemoteNotifications.sendToken(hex) }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("[byd] APNs registration falhou: \(error.localizedDescription)")
    }

    // Mostra notificações com app em foreground.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .sound, .badge] }
}

enum BydRemoteNotifications {
    static func enable() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    static func sendToken(_ hexToken: String) async {
        guard BydSettings.isConfigured,
              let url = URL(string: BydSettings.baseURL + "/api/apns/register") else { return }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = "POST"
        req.addValue("Bearer " + BydSettings.bridgeToken, forHTTPHeaderField: "Authorization")
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "device_token": hexToken,
            "device_id": BydSettings.deviceId,
        ])
        _ = try? await URLSession.shared.data(for: req)
    }
}
