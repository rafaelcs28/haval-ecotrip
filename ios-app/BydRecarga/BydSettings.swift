//
//  BydSettings.swift
//  Config mínima do app BYD Recarga: URL do bridge, token e device_id próprio.
//  Sem App Group — a Live Activity é 100% push-driven (o widget só renderiza o
//  ContentState que chega no push APNs), então não precisa compartilhar dados.
//
import Foundation

enum BydSettings {
    static let appGroup = "group.br.com.consorciolimpagyn.songpro"
    private static let d = UserDefaults.standard
    // Suite compartilhada com o widget de home screen (lê URL/token pra buscar status).
    private static let shared = UserDefaults(suiteName: appGroup)

    static var bridgeURL: String {
        get { shared?.string(forKey: "byd_bridge_url") ?? d.string(forKey: "byd_bridge_url") ?? "" }
        set {
            let v = newValue.trimmingCharacters(in: .whitespaces)
            d.set(v, forKey: "byd_bridge_url"); shared?.set(v, forKey: "byd_bridge_url")
        }
    }

    static var bridgeToken: String {
        get { shared?.string(forKey: "byd_bridge_token") ?? d.string(forKey: "byd_bridge_token") ?? "" }
        set {
            let v = newValue.trimmingCharacters(in: .whitespaces)
            d.set(v, forKey: "byd_bridge_token"); shared?.set(v, forKey: "byd_bridge_token")
        }
    }

    /// device_id próprio deste iPhone — gerado uma vez e persistido.
    static var deviceId: String {
        if let id = d.string(forKey: "byd_device_id"), !id.isEmpty { return id }
        let id = "byd-" + UUID().uuidString.lowercased()
        d.set(id, forKey: "byd_device_id")
        return id
    }

    static var isConfigured: Bool {
        !bridgeURL.isEmpty && !bridgeToken.isEmpty
    }

    /// Normaliza a base URL (sem barra final).
    static var baseURL: String {
        let u = bridgeURL
        return u.hasSuffix("/") ? String(u.dropLast()) : u
    }
}
