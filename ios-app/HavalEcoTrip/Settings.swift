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

    private static let deviceIdKey  = "notif_device_id"
    private static let apnsKey      = "apns_push_enabled"

    /// device_id do PWA — usado para filtrar /api/push/history por prefs do device.
    static var notifDeviceId: String {
        get { defaults.string(forKey: deviceIdKey) ?? "" }
        set { defaults.set(newValue, forKey: deviceIdKey) }
    }

    /// Liga pushType: .token na Live Activity. Requer APNS_ENABLED=true no bridge.
    /// Padrão false para não quebrar quem não tem .p8 configurado.
    static var apnsEnabled: Bool {
        get { defaults.bool(forKey: apnsKey) }
        set { defaults.set(newValue, forKey: apnsKey) }
    }

    // ── Keep-alive em background ──────────────────────────────────────────────

    /// Comportamento do áudio silencioso que mantém o app vivo em background
    /// para atualizar a Live Activity em tempo real (~30s).
    enum KeepAliveMode: String, CaseIterable {
        case off           = "off"
        case whileCharging = "whileCharging"
        case always        = "always"

        var label: String {
            switch self {
            case .off:           return "Desativado"
            case .whileCharging: return "Enquanto carrega"
            case .always:        return "Sempre"
            }
        }
    }

    private static let keepAliveModeKey = "keep_alive_mode"

    /// Padrão: whileCharging — ativo apenas durante sessão de recarga.
    static var keepAliveMode: KeepAliveMode {
        get { KeepAliveMode(rawValue: defaults.string(forKey: keepAliveModeKey) ?? "") ?? .whileCharging }
        set { defaults.set(newValue.rawValue, forKey: keepAliveModeKey) }
    }
}
