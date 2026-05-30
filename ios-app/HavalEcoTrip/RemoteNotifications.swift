//
//  RemoteNotifications.swift
//  Notificações via APNs (conta paga): pede autorização, registra no APNs e
//  envia o device token ao bridge. O bridge então manda os alertas direto pro
//  app (substitui o antigo polling de /api/push/history).
//
import Foundation
import UIKit
import UserNotifications

enum RemoteNotifications {
    /// Pede permissão e registra no APNs. O token chega no AppDelegate
    /// (didRegisterForRemoteNotificationsWithDeviceToken) → sendToken.
    static func enable() {
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            guard granted else { return }
            Settings.nativeNotificationsEnabled = true   // sincroniza a flag nativa
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    /// Envia o device token (hex) ao bridge pra ele poder mandar APNs alert.
    static func sendToken(_ deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task {
            guard Settings.isConfigured,
                  let url = URL(string: Settings.bridgeURL + "/api/apns/register") else { return }
            var req = URLRequest(url: url, timeoutInterval: 8)
            req.httpMethod = "POST"
            req.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
            req.addValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "device_token": hex, "device_id": Settings.notifDeviceId,
            ])
            _ = try? await URLSession.shared.data(for: req)
        }
    }
}
