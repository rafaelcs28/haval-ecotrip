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
}
