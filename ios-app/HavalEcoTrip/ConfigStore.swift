//
//  ConfigStore.swift
//  Rede da tela de Configurações: la-prefs, push prefs, charge-limit,
//  pareamento, 2FA, senha, sobre (/api/config) e ações admin/backup.
//

import Foundation
import CryptoKit

struct KnownPlace: Identifiable {
    let id: String
    var name: String
    var lat: Double
    var lng: Double
    var radiusM: Double
    init(_ r: [String: Any]) {
        if let i = r["id"] as? String { id = i } else if let n = r["id"] as? NSNumber { id = n.stringValue } else { id = UUID().uuidString }
        name = (r["name"] as? String) ?? "Local"
        lat = (r["lat"] as? Double) ?? (r["lat"] as? NSNumber)?.doubleValue ?? 0
        lng = (r["lng"] as? Double) ?? (r["lng"] as? NSNumber)?.doubleValue ?? 0
        radiusM = (r["radius_m"] as? Double) ?? (r["radius_m"] as? NSNumber)?.doubleValue ?? 200
    }
}

struct CarKey: Identifiable {
    let key: String, label: String, values: String
    var id: String { key }
}

@MainActor
final class ConfigStore: ObservableObject {
    @Published var laPrefs: [String: Bool] = [:]
    @Published var pushPrefs: [String: Bool] = [:]
    @Published var pushNums: [String: Int] = [:]
    @Published var pushStrs: [String: String] = [:]      // prefs string (security_from/to)
    @Published var securityDays: [Int] = []              // 0=dom..6=sáb (janela de segurança)
    @Published var twofaEnabled = false
    // Sobre
    @Published var pwaVersion = "—"
    @Published var gitCommit = "—"
    @Published var bridgeUptime = "—"
    @Published var nodeVersion = "—"
    @Published var mqttHost = "—"
    @Published var carVersion = "—"   // versão do APK rodando no carro (state.car_app_version)
    @Published var pairCode: String?
    @Published var toast: String?
    // Veículo
    @Published var modelName = ""
    @Published var chassi = ""
    // Locais conhecidos
    @Published var places: [KnownPlace] = []
    @Published var automationPlaces: [KnownPlace] = []   // locais só de automação (separados)
    // Listas de locais por notificação (geofence_*_places, soc_arrival_places)
    @Published var placeLists: [String: [String]] = [:]

    private var base: String { BridgeRouter.shared.currentURL }
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
            let o = obj(d)
            pushPrefs = o.compactMapValues { ($0 as? Bool) ?? (($0 as? Int).map { $0 != 0 }) }
            var lists: [String: [String]] = [:]
            for (k, v) in o where k.hasSuffix("_places") {
                if let arr = v as? [Any] { lists[k] = arr.map { "\($0)" } }
            }
            placeLists = lists
            // valores numéricos (min/pct/psi) ficam disponíveis em pushNums
            pushNums = o.compactMapValues { v -> Int? in
                if let i = v as? Int { return i }; if let d = v as? Double { return Int(d) }; return nil
            }
            pushStrs = o.compactMapValues { $0 as? String }
            if let arr = o["security_days"] as? [Any] {
                securityDays = arr.compactMap { ($0 as? Int) ?? ($0 as? NSNumber)?.intValue ?? Int("\($0)") }
            }
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
        // Versão do APK do carro (publicada em $prefix/app_version → state.car_app_version).
        if let (c, d) = await send("/api/state", "GET"), c == 200 {
            carVersion = (obj(d)["car_app_version"] as? String) ?? "—"
        }
    }

    func setLa(_ key: String, _ value: Bool) async { await send("/api/la-prefs", "POST", ["key": key, "value": value]); laPrefs[key] = value }
    func setPush(_ key: String, _ value: Bool) async { await send("/api/push/prefs", "POST", ["key": key, "value": value]); pushPrefs[key] = value }
    func setPushNum(_ key: String, _ value: Int) async { await send("/api/push/prefs", "POST", ["key": key, "value": value]); pushNums[key] = value }
    func setPlaceList(_ key: String, _ ids: [String]) async { await send("/api/push/prefs", "POST", ["key": key, "value": ids]); placeLists[key] = ids }
    func setPushStr(_ key: String, _ value: String) async { await send("/api/push/prefs", "POST", ["key": key, "value": value]); pushStrs[key] = value }
    func setSecurityDays(_ days: [Int]) async { let d = days.sorted(); await send("/api/push/prefs", "POST", ["key": "security_days", "value": d]); securityDays = d }

    // Locais conhecidos
    func loadPlaces() async {
        if let (c, d) = await send("/api/known-places", "GET"), c == 200,
           let arr = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] {
            places = arr.map(KnownPlace.init)
        }
    }
    // Locais de AUTOMAÇÃO (lista separada dos conhecidos de recarga/trajeto).
    func loadAutomationPlaces() async {
        if let (c, d) = await send("/api/automation-places", "GET"), c == 200,
           let arr = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] {
            automationPlaces = arr.map(KnownPlace.init)
        }
    }
    /// Cria um local de automação e recarrega. Retorna o id novo (pra já selecionar).
    func addAutomationPlace(name: String, lat: Double, lng: Double, radius: Double) async -> String? {
        guard let (c, d) = await send("/api/automation-places", "POST",
                                      ["name": name, "lat": lat, "lng": lng, "radius_m": radius]), c == 200,
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        await loadAutomationPlaces()
        return "\(o["id"] ?? "")"
    }
    /// Edita um local de automação (nome/raio/posição) e recarrega.
    func updateAutomationPlace(_ id: String, name: String, lat: Double?, lng: Double?, radius: Double) async {
        var body: [String: Any] = ["name": name, "radius_m": radius]
        if let lat { body["lat"] = lat }
        if let lng { body["lng"] = lng }
        await send("/api/automation-places/\(id)", "PUT", body); await loadAutomationPlaces()
    }
    func deleteAutomationPlace(_ id: String) async {
        automationPlaces.removeAll { $0.id == id }
        await send("/api/automation-places/\(id)", "DELETE"); await loadAutomationPlaces()
    }
    func addPlace(name: String, lat: Double, lng: Double, radius: Double) async {
        await send("/api/known-places", "POST", ["name": name, "lat": lat, "lng": lng, "radius_m": radius]); await loadPlaces()
    }
    /// Catálogo de chaves do carro (referência pra montar condições/ações).
    func loadCarKeys() async -> [CarKey] {
        guard let (c, d) = await send("/api/car-keys", "GET"), c == 200,
              let arr = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else { return [] }
        return arr.map { CarKey(key: ($0["key"] as? String) ?? "", label: ($0["label"] as? String) ?? "", values: ($0["values"] as? String) ?? "") }
    }
    func updatePlace(_ id: String, name: String, radius: Double, lat: Double? = nil, lng: Double? = nil) async {
        var body: [String: Any] = ["name": name, "radius_m": radius]
        if let lat { body["lat"] = lat }
        if let lng { body["lng"] = lng }
        await send("/api/known-places/\(id)", "PUT", body); await loadPlaces()
    }
    func deletePlace(_ id: String) async {
        places.removeAll { $0.id == id }
        await send("/api/known-places/\(id)", "DELETE"); await loadPlaces()
    }

    // Veículo
    func loadVehicle() async {
        if let (c, d) = await send("/api/vehicle", "GET"), c == 200 {
            let o = obj(d); modelName = (o["model_name"] as? String) ?? ""; chassi = (o["chassi"] as? String) ?? (o["env_value"] as? String) ?? ""
        }
    }
    func saveVehicle(model: String, chassi: String) async -> Bool {
        var b: [String: Any] = [:]
        if !model.isEmpty { b["model_name"] = model }
        if !chassi.isEmpty { b["chassi"] = chassi }
        guard let (c, _) = await send("/api/vehicle", "POST", b) else { return false }
        if c == 200 { self.modelName = model; self.chassi = chassi; return true }; return false
    }

    func setChargeLimit(_ pct: Int) async { await send("/api/charge-limit", "POST", ["pct": pct]) }
    // Alvo de corte por software (fora dos presets). pct=0 desliga.
    func setChargeTarget(_ pct: Int) async { await send("/api/charge-target", "POST", ["pct": pct]) }

    /// Reativa as Live Activities em andamento (recria as que travaram, sem reiniciar o bridge).
    func relaunchLA() async {
        if let (c, _) = await send("/api/la/relaunch", "POST", [:]), c == 200 { toast = "✓ Live Activities reativadas" }
        else { toast = "✗ Falha ao reativar" }
    }

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
    /// Reprocessa nomes de locais com force=true (re-identifica TODAS as viagens/
    /// recargas, não só as sem nome). É assíncrono no servidor (~1/seg).
    @discardableResult func reprocessPlaces() async -> Bool {
        guard let (c, _) = await send("/api/admin/reprocess-places", "POST", ["kind": "all", "force": true]) else { return false }
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
