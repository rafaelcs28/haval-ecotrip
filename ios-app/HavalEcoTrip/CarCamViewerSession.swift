import Combine
import Foundation
import WebRTC

@MainActor
final class CarCamViewerSession: ObservableObject {
    enum State: Equatable {
        case idle
        case connecting
        case playing
        case failed(CarCamViewerError)
    }

    typealias MakePeer = @MainActor () throws -> CarCamPeerConnectioning
    typealias CreateRemote = (String) async throws -> CarCamWHEPSession
    typealias StopRemote = (URL) async throws -> Void

    @Published private(set) var state: State = .idle
    @Published private(set) var videoTrack: CarCamVideoTrack?

    private let makePeer: MakePeer
    private let createRemote: CreateRemote
    private let stopRemote: StopRemote
    private var peer: CarCamPeerConnectioning?
    private var remoteLocation: URL?
    private var generation = 0

    init(
        makePeer: @escaping MakePeer,
        createRemote: @escaping CreateRemote,
        stopRemote: @escaping StopRemote
    ) {
        self.makePeer = makePeer
        self.createRemote = createRemote
        self.stopRemote = stopRemote
    }

    static func live(token: String) throws -> CarCamViewerSession {
        let storedToken = try CarCamCredentialStore.synchronize(currentToken: token)
        let configuration = try CarCamBridgeConfiguration.fixed(token: storedToken)
        let transport = CarCamWHEPClient(configuration: configuration)
        return CarCamViewerSession(
            makePeer: { try CarCamPeerConnection.make() },
            createRemote: { try await transport.createSession(offerSDP: $0) },
            stopRemote: { try await transport.stopSession(at: $0) }
        )
    }

    func start() async {
        guard state != .connecting, state != .playing else { return }
        generation += 1
        let run = generation
        state = .connecting
        do {
            let newPeer = try makePeer()
            peer = newPeer
            let offer = try await newPeer.makeOffer()
            guard run == generation else { return }
            let remote = try await createRemote(offer)
            guard run == generation else {
                try? await stopRemote(remote.location)
                return
            }
            remoteLocation = remote.location
            try await newPeer.applyAnswer(remote.answerSDP)
            guard run == generation else { return }
            videoTrack = newPeer.videoTrack
            state = .playing
        } catch {
            guard run == generation else { return }
            await cleanupCurrentRemote()
            peer?.close()
            peer = nil
            videoTrack = nil
            state = .failed((error as? CarCamViewerError) ?? .peerConnectionFailed)
        }
    }

    func stop() async {
        let hadSession = peer != nil || remoteLocation != nil || state != .idle
        guard hadSession else { return }
        generation += 1
        let currentPeer = peer
        peer = nil
        videoTrack = nil
        state = .idle
        currentPeer?.close()
        await cleanupCurrentRemote()
    }

    private func cleanupCurrentRemote() async {
        guard let location = remoteLocation else { return }
        remoteLocation = nil
        try? await stopRemote(location)
    }
}
