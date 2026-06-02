//
//  ConfigStore.swift
//  Rede da tela de Configurações: la-prefs, push prefs, charge-limit,
//  pareamento, 2FA, senha, sobre (/api/config) e ações admin/backup.
//

import Foundation
import CryptoKit

@MainActor
final class ConfigStore: ObservableObject {
    @Published var laPrefs: [String: Bool] = [:]
    @Published var pushPrefs: [String: Bool] = [:]
    @Published var twofaEnabled = false
    // Sobre
    @Published var pwaVersion = "—"
    @Published var gitCommit = "—"
    @Published var bridgeUptime = "—"
    @Published var nodeVersion = "—"
    @Published var mqttHost = "—"
    @Published var pairCode: String?
    @Published var toast: String?

    private var base: String {
        let u = Settings.bridgeURL.isEmpty ? AuthConfig.bridgeURL : Settings.bridgeURL
        return u.hasSuffix("/") ? String(u.dropLast()) : u
    }
    private func req(_ path: String, _ method: String = "GET", _ body: [String: Any]? = nil) -> URLRequest? {
        guard let url = URL(string: "\(base)\(path)") else { return nil }
        var r = URLRequest(url: url); r.httpMethod = method; r.timeoutInterval = 15
        r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        if let body { r.addValue("application/json", forHTTPHeaderField: "Content-Type"); r.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        return r
    }
    @discardableResult private func send(_ path: String, _ method: String, _ body: [String: Any]? = nil) async -> (Int, Data)? {
        guard let r = req(path, method, body) else { return nil }
        guard let (d, resp) = try? await URLSession.shared.data(for: r) else { return nil }
        return ((resp as? HTTPURLResponse)?.statusCode ?? -1, d)
    }
    private func obj(_ data: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:] }

    // MARK: carga inicial
    func loadAll() async {
        if let (c, d) = await send("/api/la-prefs", "GET"), c == 200 {
            laPrefs = obj(d).compactMapValues { ($0 as? Bool) ?? (($0 as? Int).map { $0 != 0 }) }
        }
        if let (c, d) = await send("/api/push/prefs", "GET"), c == 200 {
            pushPrefs = obj(d).compactMapValues { ($0 as? Bool) ?? (($0 as? Int).map { $0 != 0 }) }
        }
        if let (c, d) = await send("/api/auth/2fa/status", "GET"), c == 200 {
            twofaEnabled = (obj(d)["enabled"] as? Bool) ?? false
        }
        if let (c, d) = await send("/api/config", "GET"), c == 200 {
            let o = obj(d)
            pwaVersion = (o["version"] as? String) ?? "—"
            gitCommit = (o["git_commit"] as? String).map { String($0.prefix(7)) } ?? "—"
            nodeVersion = (o["node_version"] as? String) ?? "—"
            mqttHost = (o["mqtt_host"] as? String) ?? "—"
            if let up = o["bridge_uptime_sec"] as? Double { bridgeUptime = "\(Int(up/3600))h \(Int(up.truncatingRemainder(dividingBy: 3600)/60))min" }
            else if let up = o["bridge_uptime_sec"] as? Int { bridgeUptime = "\(up/3600)h \((up%3600)/60)min" }
        }
    }

    func setLa(_ key: String, _ value: Bool) async { await send("/api/la-prefs", "POST", ["key": key, "value": value]); laPrefs[key] = value }
    func setPush(_ key: String, _ value: Bool) async { await send("/api/push/prefs", "POST", ["key": key, "value": value]); pushPrefs[key] = value }

    func setChargeLimit(_ pct: Int) async { await send("/api/charge-limit", "POST", ["pct": pct]) }

    func generatePair() async {
        if let (c, d) = await send("/api/pair/generate", "POST", [:]), c == 200 {
            pairCode = (obj(d)["code"] as? String) ?? (obj(d)["pairCode"] as? String)
        } else { toast = "Falha ao gerar código" }
    }

    // 2FA
    func twofaSetup() async -> (secret: String, qr: String)? {
        guard let (c, d) = await send("/api/auth/2fa/setup", "POST", [:]), c == 200 else { return nil }
        let o = obj(d); return ((o["secret"] as? String) ?? "", (o["qr"] as? String) ?? "")
    }
    func twofaActivate(_ code: String) async -> Bool {
        guard let (c, _) = await send("/api/auth/2fa/activate", "POST", ["code": code]) else { return false }
        if c == 200 { twofaEnabled = true; return true }; return false
    }
    func twofaDisable(_ code: String) async -> Bool {
        guard let (c, _) = await send("/api/auth/2fa/disable", "POST", ["code": code]) else { return false }
        if c == 200 { twofaEnabled = false; return true }; return false
    }

    func changePassword(_ plain: String) async -> Bool {
        let hash = SHA256.hash(data: Data(plain.utf8)).map { String(format: "%02x", $0) }.joined()
        guard let (c, _) = await send("/api/admin/change-password", "POST", ["newHash": hash]) else { return false }
        return c == 200
    }

    // Admin / dados
    @discardableResult func adminAction(_ path: String) async -> Bool {
        guard let (c, _) = await send(path, "POST", [:]) else { return false }
        return c == 200
    }

    // Backup: baixa o JSON e devolve a URL temporária pra compartilhar.
    func exportBackup() async -> URL? {
        guard let (c, d) = await send("/api/backup", "GET"), c == 200 else { toast = "Falha no backup"; return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ecotrip-backup-\(Int(Date().timeIntervalSince1970)).json")
        try? d.write(to: url); return url
    }
    func restoreBackup(_ data: Data) async -> Bool {
        guard let url = URL(string: "\(base)/api/restore") else { return false }
        var r = URLRequest(url: url); r.httpMethod = "POST"; r.timeoutInterval = 30
        r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        r.addValue("application/json", forHTTPHeaderField: "Content-Type"); r.httpBody = data
        guard let (_, resp) = try? await URLSession.shared.data(for: r) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }
}
