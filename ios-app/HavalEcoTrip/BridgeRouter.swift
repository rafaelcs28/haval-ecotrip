//  BridgeRouter.swift
//  Escolhe o caminho mais rápido pro bridge entre o URL configurado (DuckDNS
//  público) e o hostname Tailscale (mac-mini.tailacc6e7.ts.net). Quando o
//  Tailscale está ativo no iPhone, o MagicDNS resolve pra 100.x e o WireGuard
//  faz P2P (~5-15ms). Sem Tailscale, o mesmo hostname cai no Funnel CDN (lento,
//  ~1.8s) — aí o duckdns vence a corrida. Acontece transparente.

import Foundation
import Network

extension Notification.Name {
    static let bridgeURLChanged = Notification.Name("bridgeURLChanged")
}

final class BridgeRouter {
    static let shared = BridgeRouter()

    /// Hostname Tailscale (Funnel + MagicDNS). Mesmo cert, mesma rota TLS.
    private let tsURL = "https://mac-mini.tailacc6e7.ts.net"
    /// Timeout do probe — generoso o bastante pra DERP/hairpin mas curto pra
    /// não dar UX ruim na primeira request quando o vencedor demora.
    private let probeTimeout: TimeInterval = 1.5

    private(set) var currentURL: String
    private var lastProbeAt: Date = .distantPast
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "bridgerouter.monitor")

    private init() {
        currentURL = Self.configured()
        Task { await self.probe() }
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { await self?.probe(force: true) }
        }
        monitor.start(queue: monitorQueue)
    }

    /// URL "lógica" configurada pelo login (Settings) ou default (AuthConfig).
    static func configured() -> String {
        let raw = Settings.bridgeURL.isEmpty ? AuthConfig.bridgeURL : Settings.bridgeURL
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }

    /// Roda uma corrida entre os candidatos e adota o vencedor. Chamado em init,
    /// em mudança de rede, e on-demand quando o WS falha. Cooldown 15s pra não
    /// martelar quando rajada de eventos de rede.
    func probe(force: Bool = false) async {
        if !force, Date().timeIntervalSince(lastProbeAt) < 15 { return }
        lastProbeAt = Date()

        let cfg = Self.configured()
        var candidates = [cfg]
        if !candidates.contains(tsURL) { candidates.append(tsURL) }

        guard let winner = await Self.race(candidates: candidates, timeout: probeTimeout) else {
            return
        }
        if winner != currentURL {
            currentURL = winner
            NotificationCenter.default.post(name: .bridgeURLChanged, object: nil)
        }
    }

    /// HEAD em "/" — endpoint estático, sem auth. Primeiro a responder vence.
    private static func race(candidates: [String], timeout: TimeInterval) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            for c in candidates {
                group.addTask {
                    guard let url = URL(string: c + "/") else { return nil }
                    var req = URLRequest(url: url, timeoutInterval: timeout)
                    req.httpMethod = "HEAD"
                    do {
                        let (_, resp) = try await URLSession.shared.data(for: req)
                        if let http = resp as? HTTPURLResponse, http.statusCode < 500 {
                            return c
                        }
                    } catch {}
                    return nil
                }
            }
            for await result in group {
                if let r = result {
                    group.cancelAll()
                    return r
                }
            }
            return nil
        }
    }
}
