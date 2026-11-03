import XCTest

@MainActor
final class CarCamViewerSessionTests: XCTestCase {
    private let remote = CarCamWHEPSession(
        answerSDP: "v=0\r\n",
        location: URL(string: "https://100.105.51.56:8443/api/v1/live/sessions/test")!
    )

    func testStartCreatesOnePeerAndOneRemoteSession() async {
        let peer = PeerSpy()
        let calls = CallCounter()
        let viewer = CarCamViewerSession(
            makePeer: { peer },
            createRemote: { offer in
                XCTAssertEqual(offer, "offer")
                await calls.created()
                return self.remote
            },
            stopRemote: { _ in await calls.stopped() }
        )

        await viewer.start()

        XCTAssertEqual(viewer.state, .playing)
        XCTAssertEqual(peer.offers, 1)
        XCTAssertEqual(peer.answers, [remote.answerSDP])
        let snapshot = await calls.snapshot()
        XCTAssertEqual(snapshot.creates, 1)
        XCTAssertEqual(snapshot.stops, 0)
    }

    func testStopIsIdempotentAndDeletesRemoteSessionOnce() async {
        let peer = PeerSpy()
        let calls = CallCounter()
        let viewer = CarCamViewerSession(
            makePeer: { peer },
            createRemote: { _ in self.remote },
            stopRemote: { location in
                XCTAssertEqual(location, self.remote.location)
                await calls.stopped()
            }
        )
        await viewer.start()

        await viewer.stop()
        await viewer.stop()

        XCTAssertEqual(viewer.state, .idle)
        XCTAssertEqual(peer.closes, 1)
        let snapshot = await calls.snapshot()
        XCTAssertEqual(snapshot.stops, 1)
    }

    func testStopDuringCreateClosesPeerAndDeletesLateRemoteSession() async {
        let peer = PeerSpy()
        let gate = RemoteGate()
        let calls = CallCounter()
        let viewer = CarCamViewerSession(
            makePeer: { peer },
            createRemote: { _ in await gate.wait() },
            stopRemote: { _ in await calls.stopped() }
        )

        let start = Task { await viewer.start() }
        await gate.waitUntilRequested()
        await viewer.stop()
        await gate.release(remote)
        await start.value

        XCTAssertEqual(viewer.state, .idle)
        XCTAssertEqual(peer.closes, 1)
        let snapshot = await calls.snapshot()
        XCTAssertEqual(snapshot.stops, 1)
    }

    func testStableTransportErrorRemainsVisibleForManualRetry() async {
        let peer = PeerSpy()
        let viewer = CarCamViewerSession(
            makePeer: { peer },
            createRemote: { _ in throw CarCamViewerError.tailscaleUnavailable },
            stopRemote: { _ in XCTFail("No remote session exists") }
        )

        await viewer.start()

        XCTAssertEqual(viewer.state, .failed(.tailscaleUnavailable))
        XCTAssertEqual(peer.closes, 1)
    }

    func testPeerFailureDeletesRemoteSessionAndAllowsManualRetry() async {
        let peer = PeerSpy()
        let calls = CallCounter()
        let viewer = CarCamViewerSession(
            makePeer: { peer },
            createRemote: { _ in self.remote },
            stopRemote: { _ in await calls.stopped() }
        )
        await viewer.start()

        await peer.fail(.peerConnectionFailed)

        XCTAssertEqual(viewer.state, .failed(.peerConnectionFailed))
        XCTAssertEqual(peer.closes, 1)
        let snapshot = await calls.snapshot()
        XCTAssertEqual(snapshot.stops, 1)
    }
}

@MainActor
private final class PeerSpy: CarCamPeerConnectioning {
    var offers = 0
    var answers: [String] = []
    var closes = 0
    var videoTrack: CarCamVideoTrack? { nil }
    var onFailure: (@MainActor (CarCamViewerError) async -> Void)?

    func makeOffer() async throws -> String {
        offers += 1
        return "offer"
    }

    func applyAnswer(_ sdp: String) async throws {
        answers.append(sdp)
    }

    func close() {
        closes += 1
    }

    func fail(_ error: CarCamViewerError) async {
        await onFailure?(error)
    }
}

private actor CallCounter {
    private var creates = 0
    private var stops = 0

    func created() { creates += 1 }
    func stopped() { stops += 1 }
    func snapshot() -> (creates: Int, stops: Int) { (creates, stops) }
}

private actor RemoteGate {
    private var continuation: CheckedContinuation<CarCamWHEPSession, Never>?
    private var requestedContinuation: CheckedContinuation<Void, Never>?
    private var requested = false

    func wait() async -> CarCamWHEPSession {
        requested = true
        requestedContinuation?.resume()
        requestedContinuation = nil
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilRequested() async {
        if requested { return }
        await withCheckedContinuation { requestedContinuation = $0 }
    }

    func release(_ session: CarCamWHEPSession) {
        continuation?.resume(returning: session)
        continuation = nil
    }
}
