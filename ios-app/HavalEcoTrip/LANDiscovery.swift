//
//  LANDiscovery.swift
//  Descobre o APK do carro na mesma LAN via mDNS (_havalobd._tcp) e resolve
//  host+porta. Mesma lógica do app do iPad (ios-obd/LocalDiscovery).
//

import Foundation
import Network

@MainActor
final class LANDiscovery {
    /// Chamado quando acha/perde o serviço. nil = sumiu da rede.
    var onResolve: ((String, Int)?) -> Void = { _ in }

    private var browser: NWBrowser?
    private var running = false
    private var current: (String, Int)?

    func start() {
        guard !running else { return }
        running = true
        let params = NWParameters(); params.includePeerToPeer = false
        let b = NWBrowser(for: .bonjour(type: "_havalobd._tcp.", domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            guard let result = results.first else {
                Task { @MainActor in if self.current != nil { self.current = nil; self.onResolve(nil) } }
                return
            }
            Task { @MainActor in self.resolve(result.endpoint) }
        }
        b.stateUpdateHandler = { st in if case .failed(let e) = st { NSLog("[LAN] browser failed: \(e)") } }
        b.start(queue: .main)
        browser = b
    }

    func stop() {
        running = false
        browser?.cancel(); browser = nil
        if current != nil { current = nil; onResolve(nil) }
    }

    /// Resolve um endpoint Bonjour em host/porta abrindo uma conexão TCP e lendo
    /// o currentPath (técnica padrão).
    private func resolve(_ endpoint: NWEndpoint) {
        let conn = NWConnection(to: endpoint, using: .tcp)
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let conn else { return }
            switch state {
            case .ready:
                if let r = conn.currentPath?.remoteEndpoint, case let .hostPort(host, port) = r {
                    let hostStr: String = {
                        switch host {
                        case .ipv4(let a): let raw = "\(a)"; return raw.split(separator: "%").first.map(String.init) ?? raw
                        case .ipv6(let a): let raw = "\(a)"; let c = raw.split(separator: "%").first.map(String.init) ?? raw; return "[\(c)]"
                        case .name(let n, _): return n
                        @unknown default: return ""
                        }
                    }()
                    let p = Int(port.rawValue)
                    if !hostStr.isEmpty {
                        Task { @MainActor in
                            let new = (hostStr, p)
                            if self?.current?.0 != new.0 || self?.current?.1 != new.1 {
                                self?.current = new
                                self?.onResolve(new)
                            }
                        }
                    }
                }
                conn.cancel()
            case .failed, .cancelled: conn.cancel()
            default: break
            }
        }
        conn.start(queue: .main)
    }
}
