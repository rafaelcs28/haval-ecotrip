//
//  Settings.swift
//  Persistência via UserDefaults SHARED entre app principal e Widget Extension
//  (App Group). Isso permite que o widget de home screen faça fetch direto do
//  bridge usando o mesmo token que o user configurou no app.
//
import Foundation

enum Settings {
    static let appGroupId = "group.br.com.consorciolimpagyn.havalecotrip"

    private static let urlKey   = "bridge_url"
    private static let tokenKey = "bridge_token"

    // Defaults compartilhados via App Group. Cai pra .standard se o group
    // não estiver disponível (ex: dev local sem entitlement) pra não quebrar.
    private static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupId) ?? .standard
    }

    /// Migra URL+token do UserDefaults.standard pro App Group, uma vez só.
    /// Chamado no init do app — sem isso, ao trocar pra app group em release
    /// nova o user perderia config e veria widget vazio + tela de Setup.
    static func migrateFromStandardIfNeeded() {
        let group = defaults
        let std = UserDefaults.standard
        if let oldUrl = std.string(forKey: urlKey),
           !oldUrl.isEmpty,
           (group.string(forKey: urlKey) ?? "").isEmpty {
            group.set(oldUrl, forKey: urlKey)
        }
        if let oldTok = std.string(forKey: tokenKey),
           !oldTok.isEmpty,
           (group.string(forKey: tokenKey) ?? "").isEmpty {
            group.set(oldTok, forKey: tokenKey)
        }
    }

    static var bridgeURL: String {
        get { defaults.string(forKey: urlKey) ?? "" }
        set { defaults.set(newValue, forKey: urlKey) }
    }

    static var bridgeToken: String {
        get { defaults.string(forKey: tokenKey) ?? "" }
        set { defaults.set(newValue, forKey: tokenKey) }
    }

    static var isConfigured: Bool {
        !bridgeURL.isEmpty && !bridgeToken.isEmpty
    }

    private static let deviceIdKey = "notif_device_id"

    /// device_id do PWA — usado para filtrar /api/push/history por prefs do device.
    static var notifDeviceId: String {
        get { defaults.string(forKey: deviceIdKey) ?? "" }
        set { defaults.set(newValue, forKey: deviceIdKey) }
    }
}
