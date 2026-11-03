import AVFoundation
import Foundation

enum CameraVideoQuality: String, CaseIterable, Sendable {
    case economy, standard, high

    var estimatedGBPerHour: Double {
        switch self {
        case .economy: 0.9
        case .standard: 1.8
        case .high: 2.7
        }
    }
}

struct CameraLiveCredentials: Equatable, Sendable {
    let sessionId: String
    let viewerURL: URL
    let viewerToken: String
    let connectExpiresAt: Date
    let expiresAt: Date
}

enum CameraLiveError: Error, Equatable {
    case offline
    case disconnected
    case invalidResponse
    case insecureViewerURL
    case rejected(String)
}

protocol CameraLiveSocket: AnyObject {
    func receive() async throws -> Data
    func resume()
    func cancel()
}

struct CameraLiveTransport {
    var createSession: (URLRequest) async throws -> CameraLiveCredentials
    var openSocket: (URLRequest) -> CameraLiveSocket
    var stopSession: (URLRequest) async throws -> Void
    var openLANSocket: (URLRequest) -> CameraLiveSocket

    init(
        createSession: @escaping (URLRequest) async throws -> CameraLiveCredentials,
        openSocket: @escaping (URLRequest) -> CameraLiveSocket,
        stopSession: @escaping (URLRequest) async throws -> Void,
        openLANSocket: ((URLRequest) -> CameraLiveSocket)? = nil
    ) {
        self.createSession = createSession
        self.openSocket = openSocket
        self.stopSession = stopSession
        self.openLANSocket = openLANSocket ?? openSocket
    }

    static let live = CameraLiveTransport(
        createSession: { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw CameraLiveError.invalidResponse }
            if http.statusCode == 503 { throw CameraLiveError.offline }
            guard http.statusCode == 201 else { throw CameraLiveError.rejected("HTTP \(http.statusCode)") }
            let payload = try JSONDecoder().decode(SessionResponse.self, from: data)
            guard let viewerURL = URL(string: payload.viewerUrl) else { throw CameraLiveError.invalidResponse }
            return CameraLiveCredentials(
                sessionId: payload.sessionId,
                viewerURL: viewerURL,
                viewerToken: payload.viewerToken,
                connectExpiresAt: Date(timeIntervalSince1970: payload.connectExpiresAt / 1_000),
                expiresAt: Date(timeIntervalSince1970: payload.expiresAt / 1_000)
            )
        },
        openSocket: { URLSessionCameraLiveSocket(request: $0) },
        stopSession: { request in
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode, status == 204 || status == 404 else {
                throw CameraLiveError.invalidResponse
            }
        },
        openLANSocket: CameraLanNoRedirectSession.webSocket
    )

    private struct SessionResponse: Decodable {
        let sessionId: String
        let viewerUrl: String
        let viewerToken: String
        let connectExpiresAt: Double
        let expiresAt: Double
    }
}

struct CameraLiveDelays {
    var reconnect: (TimeInterval) async throws -> Void
    var stale: (TimeInterval) async throws -> Void
    var renewal: (TimeInterval) async throws -> Void

    static let live = CameraLiveDelays(
        reconnect: { try await Task.sleep(for: .seconds($0)) },
        stale: { try await Task.sleep(for: .seconds($0)) },
        renewal: { try await Task.sleep(for: .seconds($0)) }
    )
}

@MainActor
final class CameraLiveSession: ObservableObject {
    enum State: Equatable { case idle, connecting, askingInternet, live, degraded, offline, error(String) }
    enum Route: Equatable { case lan, internet }

    private struct ConnectionOwner: Equatable {
        let generation: Int
        let route: Route
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var route: Route?
    @Published private(set) var latencyMs: Int?
    @Published private(set) var quality: CameraVideoQuality = .standard

    let displayLayer: AVSampleBufferDisplayLayer?

    private let transport: CameraLiveTransport
    private let renderer: CameraVideoRendering
    private let bridgeURL: () -> String
    private let bridgeToken: () -> String
    private let now: () -> Date
    private let delays: CameraLiveDelays
    private let lanClient: CameraLanClient
    private let routePolicy = CameraRoutePolicy()
    private let discovery: LANDiscovery?
    private var socket: CameraLiveSocket?
    private var credentials: CameraLiveCredentials?
    private var localSession: CameraLanSession?
    private var localSessionEndpoint: CameraLanEndpoint?
    private var lanEndpoint: CameraLanEndpoint?
    private var receiveTask: Task<Void, Never>?
    private var staleTask: Task<Void, Never>?
    private var renewalTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var setupTask: Task<Void, Never>?
    private var setupID = 0
    private var activeConnection: ConnectionOwner?
    private var wantsLive = false
    private var generation = 0
    private var ptsAnchor: TimeInterval?

    init(
        transport: CameraLiveTransport = .live,
        renderer: CameraVideoRendering? = nil,
        bridgeURL: @escaping () -> String,
        bridgeToken: @escaping () -> String,
        now: @escaping () -> Date = Date.init,
        delays: CameraLiveDelays = .live,
        lanClient: CameraLanClient = .live,
        discovery: LANDiscovery? = nil
    ) {
        let selectedRenderer = renderer ?? CameraVideoDecoder()
        self.transport = transport
        self.renderer = selectedRenderer
        self.displayLayer = (selectedRenderer as? CameraVideoDecoder)?.displayLayer
        self.bridgeURL = bridgeURL
        self.bridgeToken = bridgeToken
        self.now = now
        self.delays = delays
        self.lanClient = lanClient
        self.discovery = discovery ?? LANDiscovery()
        selectedRenderer.setFailureHandler {}
    }

    func startDiscovery() {
        discovery?.onResolve = { [weak self] value in
            Task { @MainActor in
                await self?.updateLANEndpoint(value.map { CameraLanEndpoint(host: $0.0, port: $0.1) })
            }
        }
        discovery?.start()
    }

    func stopDiscovery() {
        discovery?.stop()
    }

    func start() async {
        guard !wantsLive else { return }
        wantsLive = true
        generation &+= 1
        switch routePolicy.beginAction(lanAvailable: lanEndpoint != nil) {
        case .useLAN:
            state = .connecting
            let attemptGeneration = generation
            await runSetup { [weak self] in await self?.connectLAN(attemptGeneration: attemptGeneration) }
        case .askInternet:
            state = .askingInternet
        case .offline:
            state = .offline
        }
    }

    func confirmInternet() async {
        guard wantsLive, state == .askingInternet else { return }
        routePolicy.confirmInternet()
        state = .connecting
        generation &+= 1
        let attemptGeneration = generation
        await runSetup { [weak self] in await self?.connectInternet(attemptGeneration: attemptGeneration) }
    }

    func cancelInternet() async {
        guard state == .askingInternet else { return }
        _ = routePolicy.refuseInternet()
        await stop()
    }

    func stop() async {
        wantsLive = false
        routePolicy.stop()
        generation &+= 1
        activeConnection = nil
        renderer.setFailureHandler {}
        cancelTasksAndSocket()
        let oldCredentials = credentials
        let oldLocal = localSession
        let oldLocalEndpoint = localSessionEndpoint
        credentials = nil
        localSession = nil
        localSessionEndpoint = nil
        renderer.clear()
        latencyMs = nil
        route = nil
        state = .idle
        if let oldCredentials { try? await stopRemote(oldCredentials) }
        if let oldLocal, let oldLocalEndpoint { try? await lanClient.stopLiveSession(oldLocal, endpoint: oldLocalEndpoint) }
    }

    func updateLANEndpoint(_ endpoint: CameraLanEndpoint?) async {
        guard endpoint != lanEndpoint else { return }
        lanEndpoint = endpoint
        guard wantsLive else { return }
        if endpoint == nil {
            if let owner = activeConnection, owner.route == .lan {
                await handleLANLoss(owner: owner)
            } else if route == nil && state == .connecting {
                generation &+= 1
                let promptGeneration = generation
                activeConnection = nil
                renderer.setFailureHandler {}
                cancelTasksAndSocket()
                renderer.clear()
                latencyMs = nil
                await publishInternetPrompt(generation: promptGeneration)
            }
            return
        }
        guard route != .lan else { return }
        generation &+= 1
        let currentGeneration = generation
        activeConnection = nil
        renderer.setFailureHandler {}
        cancelTasksAndSocket()
        let oldCredentials = credentials
        credentials = nil
        renderer.clear()
        latencyMs = nil
        route = nil
        _ = routePolicy.lanAvailable()
        state = .connecting
        if let oldCredentials { try? await stopRemote(oldCredentials) }
        await runSetup { [weak self] in await self?.connectLAN(attemptGeneration: currentGeneration) }
    }

    private func connectLAN(attemptGeneration: Int) async {
        guard wantsLive, generation == attemptGeneration, let endpoint = lanEndpoint else {
            await publishInternetPrompt(generation: attemptGeneration)
            return
        }
        do {
            let session = try await lanClient.createLiveSession(endpoint: endpoint, bridgeToken: bridgeToken())
            guard wantsLive, generation == attemptGeneration, lanEndpoint == endpoint else {
                await revokeLocal(session, endpoint: endpoint)
                return
            }
            localSession = session
            localSessionEndpoint = endpoint
            route = .lan
            attachSocket(request: session.viewerRequest, expiresAt: session.expiresAt, owner: ConnectionOwner(generation: attemptGeneration, route: .lan), open: transport.openLANSocket)
        } catch is CancellationError {
            return
        } catch {
            guard wantsLive, generation == attemptGeneration else { return }
            await publishInternetPrompt(generation: attemptGeneration)
        }
    }

    private func connectInternet(attemptGeneration: Int) async {
        guard internetIsAllowed(generation: attemptGeneration) else { return }
        do {
            let request = try ownerRequest(path: "/api/video/live/session", method: "POST")
            guard internetIsAllowed(generation: attemptGeneration) else { return }
            let newCredentials = try await transport.createSession(request)
            try validate(newCredentials)
            guard wantsLive, generation == attemptGeneration else {
                try? await stopRemote(newCredentials)
                return
            }
            credentials = newCredentials
            var requestForSocket = URLRequest(url: newCredentials.viewerURL, timeoutInterval: 15)
            requestForSocket.addValue("Bearer " + newCredentials.viewerToken, forHTTPHeaderField: "Authorization")
            route = .internet
            attachSocket(request: requestForSocket, expiresAt: newCredentials.expiresAt, owner: ConnectionOwner(generation: attemptGeneration, route: .internet), open: transport.openSocket)
        } catch CameraLiveError.offline {
            guard wantsLive, generation == attemptGeneration else { return }
            wantsLive = false
            renderer.clear()
            state = .offline
        } catch {
            guard wantsLive, generation == attemptGeneration else { return }
            wantsLive = false
            renderer.clear()
            state = .error(Self.message(for: error))
        }
    }

    private func attachSocket(
        request: URLRequest,
        expiresAt: Date,
        owner: ConnectionOwner,
        open: (URLRequest) -> CameraLiveSocket
    ) {
        let newSocket = open(request)
        socket = newSocket
        activeConnection = owner
        renderer.setFailureHandler { [weak self] in self?.handleRendererFailure(owner: owner) }
        ptsAnchor = nil
        newSocket.resume()
        state = .connecting
        scheduleRenewal(expiresAt: expiresAt, owner: owner)
        receiveTask = Task { [weak self] in
            do {
                while let self, self.owns(owner) {
                    let data = try await newSocket.receive()
                    guard self.owns(owner) else { return }
                    let packet = try await Task.detached(priority: .userInitiated) {
                        try CameraVideoProtocol.parse(data)
                    }.value
                    try self.handle(packet, owner: owner)
                }
            } catch is CancellationError {
                return
            } catch {
                await self?.handleDisconnect(owner: owner)
            }
        }
    }

    private func handle(_ packet: CameraVideoPacket, owner: ConnectionOwner) throws {
        guard owns(owner) else { return }
        let displayed = try renderer.consume(packet)
        guard displayed else { return }
        let seconds = Double(packet.presentationTimeUs) / 1_000_000
        let current = now().timeIntervalSince1970
        if ptsAnchor == nil { ptsAnchor = current - seconds }
        latencyMs = max(0, Int((current - (ptsAnchor! + seconds)) * 1_000))
        state = .live
        staleTask?.cancel()
        staleTask = Task { [weak self] in
            do { try await self?.delays.stale(2) } catch { return }
            guard let self, self.owns(owner) else { return }
            await self.handleDisconnect(owner: owner)
        }
    }

    private func handleDisconnect(owner: ConnectionOwner) async {
        guard owns(owner) else { return }
        if owner.route == .lan {
            await handleLANLoss(owner: owner)
            return
        }
        generation &+= 1
        let reconnectGeneration = generation
        activeConnection = nil
        renderer.setFailureHandler {}
        receiveTask?.cancel(); receiveTask = nil
        staleTask?.cancel(); staleTask = nil
        renewalTask?.cancel(); renewalTask = nil
        socket?.cancel(); socket = nil
        renderer.clear()
        latencyMs = nil
        state = .degraded
        let oldCredentials = credentials
        credentials = nil
        if let oldCredentials { try? await stopRemote(oldCredentials) }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            do { try await self?.delays.reconnect(1) } catch { return }
            guard let self, self.internetIsAllowed(generation: reconnectGeneration) else { return }
            await self.runSetup { [weak self] in
                guard let self, self.internetIsAllowed(generation: reconnectGeneration) else { return }
                await self.connectInternet(attemptGeneration: reconnectGeneration)
            }
        }
    }

    private func handleLANLoss(owner: ConnectionOwner) async {
        guard owns(owner) else { return }
        generation &+= 1
        let promptGeneration = generation
        activeConnection = nil
        renderer.setFailureHandler {}
        receiveTask?.cancel(); receiveTask = nil
        staleTask?.cancel(); staleTask = nil
        renewalTask?.cancel(); renewalTask = nil
        socket?.cancel(); socket = nil
        renderer.clear()
        latencyMs = nil
        let oldLocal = localSession
        let oldEndpoint = localSessionEndpoint
        localSession = nil
        localSessionEndpoint = nil
        route = nil
        if let oldLocal, let oldEndpoint { try? await lanClient.stopLiveSession(oldLocal, endpoint: oldEndpoint) }
        await publishInternetPrompt(generation: promptGeneration)
    }

    private func publishInternetPrompt(generation: Int) async {
        guard wantsLive, self.generation == generation else { return }
        renderer.clear()
        latencyMs = nil
        route = nil
        state = routePolicy.lanUnavailable() == .askInternet ? .askingInternet : .offline
    }

    private func scheduleRenewal(expiresAt: Date, owner: ConnectionOwner) {
        renewalTask?.cancel()
        let delay = max(0, expiresAt.timeIntervalSince(now()) - 60)
        renewalTask = Task { [weak self] in
            do { try await self?.delays.renewal(delay) } catch { return }
            guard let self, self.owns(owner) else { return }
            self.generation &+= 1
            let nextGeneration = self.generation
            self.activeConnection = nil
            self.renderer.setFailureHandler {}
            self.receiveTask?.cancel(); self.receiveTask = nil
            self.staleTask?.cancel(); self.staleTask = nil
            self.socket?.cancel(); self.socket = nil
            self.renderer.clear()
            if owner.route == .lan {
                let oldLocal = self.localSession
                let oldEndpoint = self.localSessionEndpoint
                self.localSession = nil
                self.localSessionEndpoint = nil
                if let oldLocal, let oldEndpoint { try? await self.lanClient.stopLiveSession(oldLocal, endpoint: oldEndpoint) }
                await self.runSetup { [weak self] in await self?.connectLAN(attemptGeneration: nextGeneration) }
            } else {
                let oldRemote = self.credentials
                self.credentials = nil
                if let oldRemote { try? await self.stopRemote(oldRemote) }
                guard self.internetIsAllowed(generation: nextGeneration) else { return }
                await self.runSetup { [weak self] in await self?.connectInternet(attemptGeneration: nextGeneration) }
            }
        }
    }

    private func handleRendererFailure(owner: ConnectionOwner) {
        guard owns(owner) else { return }
        staleTask?.cancel()
        Task { [weak self] in await self?.handleDisconnect(owner: owner) }
    }

    private func validate(_ value: CameraLiveCredentials) throws {
        guard !value.sessionId.isEmpty, !value.viewerToken.isEmpty,
              value.viewerURL.scheme?.lowercased() == "wss",
              value.viewerURL.user == nil, value.viewerURL.password == nil, value.viewerURL.fragment == nil,
              let components = URLComponents(url: value.viewerURL, resolvingAgainstBaseURL: false),
              components.queryItems == [URLQueryItem(name: "session", value: value.sessionId)] else {
            throw CameraLiveError.insecureViewerURL
        }
    }

    private func ownerRequest(path: String, method: String) throws -> URLRequest {
        let base = bridgeURL().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + path), url.scheme?.lowercased() == "https" else {
            throw CameraLiveError.invalidResponse
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = method
        request.addValue("Bearer " + bridgeToken(), forHTTPHeaderField: "Authorization")
        return request
    }

    private func stopRemote(_ value: CameraLiveCredentials) async throws {
        try await transport.stopSession(ownerRequest(path: "/api/video/live/session/" + value.sessionId, method: "DELETE"))
    }

    private func revokeLocal(_ session: CameraLanSession, endpoint: CameraLanEndpoint) async {
        await Task { try? await lanClient.stopLiveSession(session, endpoint: endpoint) }.value
    }

    private func cancelTasksAndSocket() {
        setupID &+= 1
        setupTask?.cancel(); setupTask = nil
        receiveTask?.cancel(); receiveTask = nil
        staleTask?.cancel(); staleTask = nil
        renewalTask?.cancel(); renewalTask = nil
        reconnectTask?.cancel(); reconnectTask = nil
        socket?.cancel(); socket = nil
    }

    private func owns(_ owner: ConnectionOwner) -> Bool {
        wantsLive && generation == owner.generation && activeConnection == owner
    }

    private func internetIsAllowed(generation expectedGeneration: Int) -> Bool {
        wantsLive && generation == expectedGeneration && routePolicy.internetAllowed
    }

    private func runSetup(_ operation: @escaping @MainActor () async -> Void) async {
        setupTask?.cancel()
        setupID &+= 1
        let currentID = setupID
        let task = Task { await operation() }
        setupTask = task
        await task.value
        if setupID == currentID { setupTask = nil }
    }

    private static func message(for error: Error) -> String {
        if let error = error as? CameraLiveError {
            switch error {
            case .offline: return "Carro offline"
            case .disconnected: return "Conexão encerrada"
            case .invalidResponse: return "Resposta inválida"
            case .insecureViewerURL: return "Sessão de vídeo insegura"
            case .rejected(let reason): return reason
            }
        }
        return error.localizedDescription
    }
}

final class URLSessionCameraLiveSocket: CameraLiveSocket {
    private let task: URLSessionWebSocketTask

    init(request: URLRequest, session: URLSession = .shared) {
        task = session.webSocketTask(with: request)
    }

    func receive() async throws -> Data {
        switch try await task.receive() {
        case .data(let data): return data
        case .string: throw CameraLiveError.invalidResponse
        @unknown default: throw CameraLiveError.invalidResponse
        }
    }

    func resume() { task.resume() }
    func cancel() { task.cancel(with: .goingAway, reason: nil) }
}
