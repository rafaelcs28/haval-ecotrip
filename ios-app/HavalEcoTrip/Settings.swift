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
        // Migra URLs antigas (Tailscale ou IP direto HTTP) para HTTPS DuckDNS.
        let current = group.string(forKey: urlKey) ?? ""
        if current.contains("tailacc6e7.ts.net") || current.contains("mac-mini.tail")
            || current == "http://177.223.45.154:3000" {
            group.set("https://mqttrafael.duckdns.org:3443", forKey: urlKey)
        }
    }

    static var bridgeURL: String {
        get { defaults.string(forKey: urlKey) ?? "" }
        set { defaults.set(newValue, forKey: urlKey) }
    }

    /// bridgeURL sem barra final — concatenar `+ "/api/..."` direto gerava `//api`
    /// quando o usuário salvava a URL com barra no fim.
    static var apiBase: String {
        let u = bridgeURL
        return u.hasSuffix("/") ? String(u.dropLast()) : u
    }

    static var bridgeToken: String {
        get { defaults.string(forKey: tokenKey) ?? "" }
        set { defaults.set(newValue, forKey: tokenKey) }
    }

    static var isConfigured: Bool {
        !bridgeURL.isEmpty && !bridgeToken.isEmpty
    }

    private static let deviceIdKey  = "notif_device_id"

    /// device_id do device — usado pra filtrar /api/push/history por prefs, pra
    /// registrar push/pts token e pra reportar phone-location. O PWA escreve o seu
    /// id (setter). Em install nativo (sem PWA) o getter gera e persiste um UUID
    /// estável na 1ª leitura — sem isso o id fica vazio e vários POSTs são bloqueados.
    static var notifDeviceId: String {
        get {
            if let id = defaults.string(forKey: deviceIdKey), !id.isEmpty { return id }
            let id = "hav-" + UUID().uuidString.prefix(12).lowercased()
            defaults.set(id, forKey: deviceIdKey)
            return id
        }
        set { defaults.set(newValue, forKey: deviceIdKey) }
    }

    private static let nativeNotifsKey = "native_notifs_enabled"

    /// Notificações nativas via NotificationPoller (polling de /api/push/history
    /// + local notifications). Padrão OFF — o PWA standalone já notifica em tempo
    /// real via Web Push, e o poller nativo só re-dispararia o backlog ao abrir.
    static var nativeNotificationsEnabled: Bool {
        get { defaults.bool(forKey: nativeNotifsKey) }   // ausente = false = OFF
        set { defaults.set(newValue, forKey: nativeNotifsKey) }
    }
}
