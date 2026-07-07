//
//  OfflineSync.swift
//  Cache local em disco + sincronização incremental (?since= e tombstones) +
//  fila de edições offline. Cada coleção (recargas, viagens, abastecimentos,
//  eventos, manutenção) persiste no Documents e só baixa o que é novo.
//
//  - App abre → carrega do disco (instantâneo, funciona OFFLINE) e em seguida
//    sincroniza só o novo com o servidor.
//  - Edições offline entram numa fila e são reenviadas quando há internet.
//  - "Limpar cache" apaga o disco; a próxima abertura baixa tudo de novo.
//

import Foundation

extension Notification.Name {
    /// Disparada por OfflineCache.clearAll() — loaders ativos zeram a memória e re-sincronizam.
    static let offlineCacheCleared = Notification.Name("OfflineCacheCleared")
}

/// Operação de escrita pendente (reenviada quando online).
struct PendingOp: Codable { let method: String; let path: String; let bodyJSON: Data? }

@MainActor
final class SyncedList: ObservableObject {
    @Published private(set) var items: [[String: Any]] = []
    @Published private(set) var lastSyncMs: Double = 0
    @Published private(set) var pendingCount = 0

    let name: String
    private let path: String
    private let idKeys: [String]      // chaves de id, em ordem de preferência
    private let incremental: Bool     // suporta ?since=
    private let arrayKey: String?     // resposta é { arrayKey: [...] } em vez de [...]
    private let tombstoneKey: String? // nome no header X-Tombstones (se houver)
    private var pending: [PendingOp] = []

    init(name: String, path: String, idKeys: [String], incremental: Bool, arrayKey: String? = nil, tombstoneKey: String? = nil) {
        self.name = name; self.path = path; self.idKeys = idKeys
        self.incremental = incremental; self.arrayKey = arrayKey; self.tombstoneKey = tombstoneKey
        loadFromDisk()
        // "Limpar cache local" (OfflineCache.clearAll) só apaga o disco; sem isto,
        // os loaders já abertos seguiam com os dados antigos em memória até o app
        // reabrir. Aqui cada loader ativo zera a memória e re-sincroniza na hora.
        NotificationCenter.default.addObserver(forName: .offlineCacheCleared, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.items = []; self.lastSyncMs = 0; self.pending = []; self.pendingCount = 0
                await self.sync()
            }
        }
    }

    private var base: String {
        let u = BridgeRouter.shared.currentURL
        return u.hasSuffix("/") ? String(u.dropLast()) : u
    }
    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("sync_\(name).json")
    }
    private func idOf(_ d: [String: Any]) -> String {
        for k in idKeys { if let v = d[k] { return SyncedList.canonId(v) } }
        return UUID().uuidString
    }
    // Id canônico: "\(v)" interpolava Int como "123" mas Double como "123.0" — então
    // um localId derivado de Double nunca casava com o item (edit virava no-op). Normaliza
    // todo número inteiro pro mesmo string, independente de ser armazenado Int/Double/NSNumber.
    nonisolated static func canonId(_ v: Any) -> String {
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            let d = n.doubleValue
            if d.rounded() == d && abs(d) < 9e15 { return String(Int64(d)) }
            return "\(d)"
        }
        if let i = v as? Int { return String(i) }
        if let d = v as? Double { return (d.rounded() == d && abs(d) < 9e15) ? String(Int64(d)) : "\(d)" }
        return "\(v)"
    }

    // MARK: disco
    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        items = (obj["items"] as? [[String: Any]]) ?? []
        // JSONSerialization pode devolver Int — `as? Double` falhava e zerava o cursor,
        // forçando re-fetch completo a cada cold start.
        lastSyncMs = (obj["lastSyncMs"] as? NSNumber)?.doubleValue ?? 0
        if let pj = obj["pending"] as? Data { pending = (try? JSONDecoder().decode([PendingOp].self, from: pj)) ?? [] }
        else if let arr = obj["pending"] as? [[String: Any]] {
            pending = arr.compactMap { p in
                guard let m = p["method"] as? String, let pa = p["path"] as? String else { return nil }
                let body = (p["body"] as? [String: Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                return PendingOp(method: m, path: pa, bodyJSON: body)
            }
        }
        pendingCount = pending.count
    }
    private func saveToDisk() {
        let pendingArr: [[String: Any]] = pending.map { op in
            var d: [String: Any] = ["method": op.method, "path": op.path]
            if let b = op.bodyJSON, let o = try? JSONSerialization.jsonObject(with: b) { d["body"] = o }
            return d
        }
        let obj: [String: Any] = ["items": items, "lastSyncMs": lastSyncMs, "pending": pendingArr]
        if let data = try? JSONSerialization.data(withJSONObject: obj) { try? data.write(to: fileURL) }
        pendingCount = pending.count
    }

    func clear() {
        items = []; lastSyncMs = 0; pending = []; pendingCount = 0
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: sync
    func sync() async {
        await replayPending()
        await fetchNew()
    }

    private func fetchNew() async {
        guard Settings.isConfigured else { return }
        var urlStr = "\(base)\(path)"
        if incremental, lastSyncMs > 0 { urlStr += "?since=\(Int(lastSyncMs))" }
        guard let url = URL(string: urlStr) else { return }
        var req = URLRequest(url: url); req.timeoutInterval = 15
        req.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return }   // offline → mantém cache

        // Parse + dedup + cursor rodam FORA do main: com autotrips (centenas de itens)
        // o Dictionary(items.map...) + Array(byId.values) travavam a UI a cada sync.
        let snapshot = items, prevSync = lastSyncMs, inc = incremental, ak = arrayKey, keys = idKeys
        let tomb = http.value(forHTTPHeaderField: "X-Tombstones")
        let syncMs = http.value(forHTTPHeaderField: "X-Sync-Ms")
        let result = await Task.detached(priority: .userInitiated) {
            SyncedList.computeMerge(data: data, current: snapshot, prevSync: prevSync,
                                    incremental: inc, arrayKey: ak, idKeys: keys,
                                    tombstones: tomb, syncMsHeader: syncMs)
        }.value
        items = result.items
        lastSyncMs = result.lastSyncMs
        saveToDisk()
    }

    /// Parse/merge/cursor puro (sem estado de instância) — roda off-main em Task.detached.
    nonisolated static func computeMerge(data: Data, current: [[String: Any]], prevSync: Double,
                                         incremental: Bool, arrayKey: String?, idKeys: [String],
                                         tombstones: String?, syncMsHeader: String?)
    -> (items: [[String: Any]], lastSyncMs: Double) {
        func idOf(_ d: [String: Any]) -> String {
            for k in idKeys { if let v = d[k] { return SyncedList.canonId(v) } }
            return UUID().uuidString
        }
        let any = try? JSONSerialization.jsonObject(with: data)
        let arr: [[String: Any]]
        if let k = arrayKey { arr = ((any as? [String: Any])?[k] as? [[String: Any]]) ?? [] }
        else { arr = (any as? [[String: Any]]) ?? ((any as? [String: Any])?["items"] as? [[String: Any]]) ?? [] }

        var outItems: [[String: Any]]
        if incremental {
            // upsert por id; `uniquingKeysWith` tolera duplicata no cache (senão crash).
            var byId = Dictionary(current.map { (idOf($0), $0) }, uniquingKeysWith: { _, b in b })
            for d in arr { byId[idOf(d)] = d }
            if let h = tombstones, !h.isEmpty {
                for id in h.split(separator: ",") { byId.removeValue(forKey: String(id)) }
            }
            outItems = Array(byId.values)
        } else {
            outItems = arr   // full refresh
        }
        var maxMs = prevSync
        for d in arr {
            for key in ["_updated_ms", "timestamp_ms", "ts", "startMs", "id", "date_ms"] {
                if let v = d[key] as? Double { maxMs = max(maxMs, v) }
                else if let v = d[key] as? Int { maxMs = max(maxMs, Double(v)) }
            }
        }
        let cursor: Double
        if let h = syncMsHeader, let serverMs = Double(h), serverMs > 0 {
            cursor = serverMs   // X-Sync-Ms: relógio do servidor (autoritativo)
        } else {
            let nowMs = Date().timeIntervalSince1970 * 1000   // fallback: clampa ao cliente
            cursor = min(max(maxMs, prevSync), nowMs)
        }
        return (outItems, cursor)
    }

    // MARK: edições (offline-first)
    /// Aplica a mudança no item local (otimista), enfileira o PATCH/POST/DELETE e
    /// tenta enviar já. Se offline, fica na fila pra reenviar no próximo sync.
    func mutate(localId: String, apply: ([String: Any]) -> [String: Any], method: String, opPath: String, body: [String: Any]?) async {
        if let i = items.firstIndex(where: { idOf($0) == localId }) {
            if method == "DELETE" { items.remove(at: i) } else { items[i] = apply(items[i]) }
        }
        let bodyData = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        pending.append(PendingOp(method: method, path: opPath, bodyJSON: bodyData))
        saveToDisk()
        await replayPending()
    }

    private func replayPending() async {
        guard Settings.isConfigured, !pending.isEmpty else { return }
        var remaining: [PendingOp] = []
        for op in pending {
            guard let url = URL(string: "\(base)\(op.path)") else { continue }
            var r = URLRequest(url: url); r.httpMethod = op.method; r.timeoutInterval = 12
            r.addValue("Bearer " + Settings.bridgeToken, forHTTPHeaderField: "Authorization")
            if let b = op.bodyJSON { r.addValue("application/json", forHTTPHeaderField: "Content-Type"); r.httpBody = b }
            if let (_, resp) = try? await URLSession.shared.data(for: r),
               let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                continue   // enviado com sucesso → remove da fila
            }
            remaining.append(op)   // falhou (offline) → mantém
        }
        pending = remaining
        saveToDisk()
    }
}

/// Apaga todos os caches locais (chamado pelo "Limpar cache" das Configurações).
enum OfflineCache {
    static func clearAll() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in files where f.lastPathComponent.hasPrefix("sync_") || f.lastPathComponent.hasPrefix("traj_") {
                try? FileManager.default.removeItem(at: f)
            }
        }
        URLCache.shared.removeAllCachedResponses()
        // Avisa os loaders ativos pra zerar a memória + re-sincronizar (sem isso,
        // só o disco era limpo e a tela aberta seguia com dados antigos).
        NotificationCenter.default.post(name: .offlineCacheCleared, object: nil)
    }

    // Cache sob demanda do trajeto (samples de /api/telemetry/:id). Só viagens
    // abertas são gravadas — ~0,27 MB por 100 km. Abre offline depois.
    private static func trajURL(_ id: String) -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("traj_\(id).json")
    }
    static func saveTraj(_ id: String, _ data: Data) { try? data.write(to: trajURL(id)) }
    static func loadTraj(_ id: String) -> Data? { try? Data(contentsOf: trajURL(id)) }
    /// Quando o trajeto foi gravado (ms). 0 se não há cache. Usado pra decidir se
    /// o cache está velho (trip._updated_ms > mtime → re-baixa).
    static func trajMtimeMs(_ id: String) -> Double {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: trajURL(id).path),
              let d = attrs[.modificationDate] as? Date else { return 0 }
        return d.timeIntervalSince1970 * 1000
    }
}
