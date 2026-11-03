import AVFoundation
import Foundation
import WebRTC

typealias CarCamVideoTrack = RTCVideoTrack

@MainActor
protocol CarCamPeerConnectioning: AnyObject {
    var videoTrack: CarCamVideoTrack? { get }
    func makeOffer() async throws -> String
    func applyAnswer(_ sdp: String) async throws
    func close()
}

@MainActor
final class CarCamPeerConnection: NSObject, CarCamPeerConnectioning {
    private static let initializeWebRTC: Void = { RTCInitializeSSL() }()

    private let connection: RTCPeerConnection
    private var closed = false
    private(set) var videoTrack: CarCamVideoTrack?

    static func make() throws -> CarCamPeerConnection {
        _ = Self.initializeWebRTC
        let configuration = RTCConfiguration()
        configuration.iceServers = []
        configuration.sdpSemantics = .unifiedPlan
        configuration.continualGatheringPolicy = .gatherOnce
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let factory = RTCPeerConnectionFactory()
        guard let connection = factory.peerConnection(
            with: configuration, constraints: constraints, delegate: nil) else {
            throw CarCamViewerError.peerConnectionFailed
        }
        let result = CarCamPeerConnection(connection: connection)
        let receiveOnly = RTCRtpTransceiverInit()
        receiveOnly.direction = .recvOnly
        guard connection.addTransceiver(of: .audio, init: receiveOnly) != nil,
              connection.addTransceiver(of: .video, init: receiveOnly) != nil else {
            connection.close()
            throw CarCamViewerError.peerConnectionFailed
        }
        return result
    }

    private init(connection: RTCPeerConnection) {
        self.connection = connection
        super.init()
        connection.delegate = self
    }

    func makeOffer() async throws -> String {
        guard !closed else { throw CarCamViewerError.peerConnectionFailed }
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playback, mode: .moviePlayback)
        try audio.setActive(true)

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let offer = try await withCheckedThrowingContinuation { continuation in
            connection.offer(for: constraints) { description, error in
                if let description { continuation.resume(returning: description) }
                else { continuation.resume(throwing: error ?? CarCamViewerError.peerConnectionFailed) }
            }
        }
        try await setLocalDescription(offer)
        for _ in 0..<300 {
            try Task.checkCancellation()
            if connection.iceGatheringState == .complete {
                guard let sdp = connection.localDescription?.sdp, !sdp.isEmpty else {
                    throw CarCamViewerError.invalidSDP
                }
                return sdp
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw CarCamViewerError.setupTimeout
    }

    func applyAnswer(_ sdp: String) async throws {
        guard !closed, !sdp.isEmpty else { throw CarCamViewerError.invalidSDP }
        let answer = RTCSessionDescription(type: .answer, sdp: sdp)
        try await withCheckedThrowingContinuation { continuation in
            connection.setRemoteDescription(answer) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        for receiver in connection.receivers {
            receiver.track?.isEnabled = true
            if videoTrack == nil { videoTrack = receiver.track as? RTCVideoTrack }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        videoTrack = nil
        connection.close()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func setLocalDescription(_ description: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { continuation in
            connection.setLocalDescription(description) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}

extension CarCamPeerConnection: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
