import Foundation
import Network

/// Descobre o APK do carro na mesma LAN via mDNS (`_havalobd._tcp`).
///
/// Quando achado, expõe URL HTTP local pro `BridgePublisher` usar como atalho
/// (sem passar pelo Mac mini via Tailscale). Failover automático: se o serviço
/// some (carro saiu da rede), volta a publicar `localUrl = nil`.
@MainActor
final class LocalDiscovery: ObservableObject {
    @Published var localUrl: URL? = nil
    @Published var lastSeen: Date? = nil
    @Published var serviceName: String = ""

    private var browser: NWBrowser? = nil
    private var enabled = false

    /// Liga ou desliga descoberta. Quando desliga, `localUrl` vira nil.
    func setEnabled(_ on: Bool) {
        guard enabled != on else { return }
        enabled = on
        if on { start() } else { stop() }
    }

    private func start() {
        let params = NWParameters()
        params.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjour(type: "_havalobd._tcp.", domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self = self else { return }
            // Acha primeiro endpoint ativo
            guard let result = results.first else {
                Task { @MainActor in
                    self.localUrl = nil
                    self.serviceName = ""
                }
                return
            }
            // Resolve nome + porta. Pega o endpoint Bonjour e tenta resolver IP.
            if case let .service(name, _, _, _) = result.endpoint {
                Task { @MainActor in self.serviceName = name }
            }
            Task { @MainActor in self.resolve(endpoint: result.endpoint) }
        }
        browser.stateUpdateHandler = { state in
            switch state {
            case .failed(let err):
                NSLog("[LocalDiscovery] browser failed: \(err)")
            default: break
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func stop() {
        browser?.cancel()
        browser = nil
        localUrl = nil
        serviceName = ""
    }

    /// Resolve um endpoint Bonjour pra IP/porta abrindo uma conexão e lendo
    /// o `currentPath`. É uma técnica padrão pra extrair host + port.
    private func resolve(endpoint: NWEndpoint) {
        let conn = NWConnection(to: endpoint, using: .tcp)
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let conn = conn else { return }
            switch state {
            case .ready:
                // Extrai host/port do path resolvido
                if let resolved = conn.currentPath?.remoteEndpoint, case let .hostPort(host, port) = resolved {
                    // IPv4Address.debugDescription às vezes inclui "%interface"
                    // (ex: "192.168.0.169%en0") que faz URL(string:) retornar nil.
                    // Tira tudo depois do %.
                    let hostStr: String = {
                        switch host {
                        case .ipv4(let addr):
                            let raw = "\(addr)"
                            return raw.split(separator: "%").first.map(String.init) ?? raw
                        case .ipv6(let addr):
                            let raw = "\(addr)"
                            let clean = raw.split(separator: "%").first.map(String.init) ?? raw
                            return "[\(clean)]"
                        case .name(let name, _): return name
                        @unknown default: return ""
                        }
                    }()
                    NSLog("[LocalDiscovery] resolved host='\(hostStr)' port=\(port.rawValue)")
                    if !hostStr.isEmpty {
                        let urlStr = "http://\(hostStr):\(port.rawValue)"
                        let url = URL(string: urlStr)
                        Task { @MainActor in
                            self?.localUrl = url
                            self?.lastSeen = Date()
                            NSLog("[LocalDiscovery] APK em '\(urlStr)' → \(url?.absoluteString ?? "URL nil!")")
                        }
                    }
                }
                conn.cancel()
            case .failed, .cancelled:
                conn.cancel()
            default: break
            }
        }
        conn.start(queue: .main)
    }
}
