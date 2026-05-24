//
//  Settings.swift
//  Persistência simples via UserDefaults pros 2 valores que o app precisa:
//  URL do bridge (ex: "https://mac-mini.tailacc6e7.ts.net") e o bearer token
//  (mesmo hash de senha que o PWA usa, copiado de localStorage["bridge_token"]).
//
import Foundation

enum Settings {
    private static let urlKey   = "bridge_url"
    private static let tokenKey = "bridge_token"

    static var bridgeURL: String {
        get { UserDefaults.standard.string(forKey: urlKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: urlKey) }
    }

    static var bridgeToken: String {
        get { UserDefaults.standard.string(forKey: tokenKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: tokenKey) }
    }

    static var isConfigured: Bool {
        !bridgeURL.isEmpty && !bridgeToken.isEmpty
    }
}
