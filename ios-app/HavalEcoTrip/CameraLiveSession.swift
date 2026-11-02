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
    func messages() -> AsyncThrowingStream<Data, Error>
    func resume()
    func cancel()
}

struct CameraLiveTransport {
    var createSession: (URLRequest) async throws -> CameraLiveCredentials
    var openSocket: (URLRequest) -> CameraLiveSocket
    var stopSession: (URLRequest) async throws -> Void

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
        }
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
    enum State: Equatable { case idle, connecting, live, degraded, offline, error(String) }

    @Published private(set) var state: State = .idle
    @Published private(set) var latencyMs: Int?
    @Published private(set) var quality: CameraVideoQuality = .standard

    let displayLayer: AVSampleBufferDisplayLayer?

    private let transport: CameraLiveTransport
    private let renderer: CameraVideoRendering
    private let bridgeURL: () -> String
    private let bridgeToken: () -> String
    private let now: () -> Date
    private let delays: CameraLiveDelays
    private var socket: CameraLiveSocket?
    private var credentials: CameraLiveCredentials?
    private var receiveTask: Task<Void, Never>?
    private var staleTask: Task<Void, Never>?
    private var renewalTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var wantsLive = false
    private var generation = 0
    private var ptsAnchor: TimeInterval?

    init(
        transport: CameraLiveTransport = .live,
        renderer: CameraVideoRendering? = nil,
        bridgeURL: @escaping () -> String = { BridgeRouter.shared.currentURL },
        bridgeToken: @escaping () -> String = { Settings.bridgeToken },
        now: @escaping () -> Date = Date.init,
        delays: CameraLiveDelays = .live
    ) {
        let selectedRenderer = renderer ?? CameraVideoDecoder()
        self.transport = transport
        self.renderer = selectedRenderer
        self.displayLayer = (selectedRenderer as? CameraVideoDecoder)?.displayLayer
        self.bridgeURL = bridgeURL
        self.bridgeToken = bridgeToken
        self.now = now
        self.delays = delays
    }

    func start() async {
        guard !wantsLive else { return }
        wantsLive = true
        state = .connecting
        await connect()
    }

    func stop() async {
        wantsLive = false
        generation &+= 1
        cancelTasksAndSocket()
        let oldCredentials = credentials
        credentials = nil
        renderer.clear()
        latencyMs = nil
        state = .idle
        if let oldCredentials { try? await stopRemote(oldCredentials) }
    }

    private func connect() async {
        guard wantsLive else { return }
        do {
            let request = try ownerRequest(path: "/api/video/live/session", method: "POST")
            let newCredentials = try await transport.createSession(request)
            try validate(newCredentials)
            guard wantsLive else {
                try? await stopRemote(newCredentials)
                return
            }
            generation &+= 1
            let currentGeneration = generation
            credentials = newCredentials
            var requestForSocket = URLRequest(url: newCredentials.viewerURL, timeoutInterval: 15)
            requestForSocket.addValue("Bearer " + newCredentials.viewerToken, forHTTPHeaderField: "Authorization")
            let newSocket = transport.openSocket(requestForSocket)
            socket = newSocket
            ptsAnchor = nil
            newSocket.resume()
            state = .connecting
            scheduleRenewal(newCredentials, generation: currentGeneration)
            receiveTask = Task { [weak self] in
                do {
                    for try await data in newSocket.messages() {
                        guard let self, self.wantsLive, self.generation == currentGeneration else { return }
                        let packet = try await Task.detached(priority: .userInitiated) {
                            try CameraVideoProtocol.parse(data)
                        }.value
                        try self.handle(packet, generation: currentGeneration)
                    }
                    throw CameraLiveError.disconnected
                } catch is CancellationError {
                    return
                } catch {
                    await self?.handleDisconnect(generation: currentGeneration)
                }
            }
        } catch CameraLiveError.offline {
            renderer.clear()
            state = .offline
        } catch {
            renderer.clear()
            state = .error(Self.message(for: error))
        }
    }

    private func handle(_ packet: CameraVideoPacket, generation: Int) throws {
        guard self.generation == generation else { return }
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
            guard let self, self.wantsLive, self.generation == generation else { return }
            self.renderer.clear()
            self.latencyMs = nil
            self.state = .degraded
        }
    }

    private func handleDisconnect(generation: Int) async {
        guard wantsLive, self.generation == generation else { return }
        renderer.clear()
        latencyMs = nil
        state = .degraded
        staleTask?.cancel(); renewalTask?.cancel()
        socket?.cancel(); socket = nil
        let oldCredentials = credentials
        credentials = nil
        if let oldCredentials { try? await stopRemote(oldCredentials) }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            do { try await self?.delays.reconnect(1) } catch { return }
            guard let self, self.wantsLive, self.generation == generation else { return }
            await self.connect()
        }
    }

    private func scheduleRenewal(_ current: CameraLiveCredentials, generation: Int) {
        renewalTask?.cancel()
        let delay = max(0, current.expiresAt.timeIntervalSince(now()) - 60)
        renewalTask = Task { [weak self] in
            do { try await self?.delays.renewal(delay) } catch { return }
            guard let self, self.wantsLive, self.generation == generation else { return }
            self.generation &+= 1
            self.renderer.clear()
            self.socket?.cancel()
            self.socket = nil
            try? await self.stopRemote(current)
            await self.connect()
        }
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

    private func cancelTasksAndSocket() {
        receiveTask?.cancel(); receiveTask = nil
        staleTask?.cancel(); staleTask = nil
        renewalTask?.cancel(); renewalTask = nil
        reconnectTask?.cancel(); reconnectTask = nil
        socket?.cancel(); socket = nil
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

private final class URLSessionCameraLiveSocket: CameraLiveSocket {
    private let task: URLSessionWebSocketTask

    init(request: URLRequest) {
        task = URLSession.shared.webSocketTask(with: request)
    }

    func messages() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let receiveTask = Task {
                do {
                    while !Task.isCancelled {
                        switch try await task.receive() {
                        case .data(let data): continuation.yield(data)
                        case .string: throw CameraLiveError.invalidResponse
                        @unknown default: throw CameraLiveError.invalidResponse
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in receiveTask.cancel() }
        }
    }

    func resume() { task.resume() }
    func cancel() { task.cancel(with: .goingAway, reason: nil) }
}
