import XCTest

@MainActor
final class CameraLiveSessionTests: XCTestCase {
    func testAuthenticatedStartUsesOwnerTokenAndViewerBearer() async throws {
        let socket = FakeCameraLiveSocket()
        let requestSeen = expectation(description: "owner request")
        let socketSeen = expectation(description: "viewer request")
        let transport = CameraLiveTransport(
            createSession: { request in
                XCTAssertEqual(request.url?.absoluteString, "https://bridge.example/api/video/live/session")
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer owner-token")
                requestSeen.fulfill()
                return Self.credentials()
            },
            openSocket: { request in
                XCTAssertEqual(request.url?.absoluteString, "wss://bridge.example/ws/video/live/viewer?session=session-1")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer viewer-token")
                XCTAssertFalse(request.url?.absoluteString.contains("viewer-token") ?? true)
                socketSeen.fulfill()
                return socket
            },
            stopSession: { _ in }
        )
        let session = CameraLiveSession(transport: transport, renderer: FakeRenderer(), bridgeURL: { "https://bridge.example" }, bridgeToken: { "owner-token" })

        await session.start()

        await fulfillment(of: [requestSeen, socketSeen], timeout: 1)
        XCTAssertEqual(session.state, .connecting)
        await session.stop()
    }

    func testOfflineResponsePublishesOfflineClearsFrameAndAllowsRetry() async {
        let renderer = FakeRenderer()
        var attempts = 0
        let transport = CameraLiveTransport(
            createSession: { _ in attempts += 1; throw CameraLiveError.offline },
            openSocket: { _ in XCTFail("socket must not open"); return FakeCameraLiveSocket() },
            stopSession: { _ in }
        )
        let session = CameraLiveSession(transport: transport, renderer: renderer, bridgeURL: { "https://bridge.example" }, bridgeToken: { "owner" })

        await session.start()

        XCTAssertEqual(session.state, .offline)
        await session.start()
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(renderer.clearCount, 2)
    }

    func testDisconnectBlanksFrameAndReconnects() async {
        let first = FakeCameraLiveSocket(); let second = FakeCameraLiveSocket()
        var createCount = 0
        let reconnected = expectation(description: "reconnected")
        let renderer = FakeRenderer()
        let transport = CameraLiveTransport(
            createSession: { _ in createCount += 1; return Self.credentials(session: "session-\(createCount)") },
            openSocket: { _ in createCount == 1 ? first : { reconnected.fulfill(); return second }() },
            stopSession: { _ in }
        )
        let delays = CameraLiveDelays(reconnect: { _ in }, stale: CameraLiveDelays.live.stale, renewal: CameraLiveDelays.live.renewal)
        let session = CameraLiveSession(transport: transport, renderer: renderer, bridgeURL: { "https://bridge.example" }, bridgeToken: { "owner" }, delays: delays)
        await session.start()

        first.fail(CameraLiveError.disconnected)

        await fulfillment(of: [reconnected], timeout: 1)
        XCTAssertGreaterThanOrEqual(renderer.clearCount, 1)
        XCTAssertEqual(createCount, 2)
        await session.stop()
    }

    func testStaleFrameIsBlanked() async {
        let socket = FakeCameraLiveSocket()
        let cleared = expectation(description: "stale frame cleared")
        let renderer = FakeRenderer(onClear: { cleared.fulfill() })
        let transport = CameraLiveTransport(createSession: { _ in Self.credentials() }, openSocket: { _ in socket }, stopSession: { _ in })
        let delays = CameraLiveDelays(reconnect: CameraLiveDelays.live.reconnect, stale: { _ in try await Task.sleep(nanoseconds: 5_000_000) }, renewal: CameraLiveDelays.live.renewal)
        let session = CameraLiveSession(transport: transport, renderer: renderer, bridgeURL: { "https://bridge.example" }, bridgeToken: { "owner" }, delays: delays)
        await session.start()
        socket.yield(CameraVideoProtocolTests.config())
        socket.yield(CameraVideoProtocolTests.access())

        await fulfillment(of: [cleared], timeout: 1)
        XCTAssertEqual(session.state, .degraded)
        await session.stop()
    }

    func testStopCancelsViewerAndDeletesSession() async {
        let socket = FakeCameraLiveSocket()
        let stopped = expectation(description: "delete")
        let transport = CameraLiveTransport(
            createSession: { _ in Self.credentials() },
            openSocket: { _ in socket },
            stopSession: { request in
                XCTAssertEqual(request.url?.path, "/api/video/live/session/session-1")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer owner")
                stopped.fulfill()
            }
        )
        let renderer = FakeRenderer()
        let session = CameraLiveSession(transport: transport, renderer: renderer, bridgeURL: { "https://bridge.example" }, bridgeToken: { "owner" })
        await session.start()

        await session.stop()

        await fulfillment(of: [stopped], timeout: 1)
        XCTAssertTrue(socket.cancelled)
        XCTAssertEqual(session.state, .idle)
        XCTAssertGreaterThanOrEqual(renderer.clearCount, 1)
    }

    func testThirtyMinuteSessionRenewsOneMinuteEarly() async {
        let scheduled = expectation(description: "renewal scheduled")
        var renewalDelay: TimeInterval?
        let delays = CameraLiveDelays(
            reconnect: CameraLiveDelays.live.reconnect,
            stale: CameraLiveDelays.live.stale,
            renewal: { delay in renewalDelay = delay; scheduled.fulfill(); throw CancellationError() }
        )
        let transport = CameraLiveTransport(createSession: { _ in Self.credentials(expiresAt: Date(timeIntervalSince1970: 1_800)) }, openSocket: { _ in FakeCameraLiveSocket() }, stopSession: { _ in })
        let session = CameraLiveSession(transport: transport, renderer: FakeRenderer(), bridgeURL: { "https://bridge.example" }, bridgeToken: { "owner" }, now: { Date(timeIntervalSince1970: 0) }, delays: delays)

        await session.start()

        await fulfillment(of: [scheduled], timeout: 1)
        XCTAssertNotNil(renewalDelay)
        XCTAssertEqual(renewalDelay!, 1_740, accuracy: 0.001)
        await session.stop()
    }

    func testSelectedQualityShowsEstimatedDataUse() {
        XCTAssertEqual(CameraVideoQuality.economy.estimatedGBPerHour, 0.9, accuracy: 0.001)
        XCTAssertEqual(CameraVideoQuality.standard.estimatedGBPerHour, 1.8, accuracy: 0.001)
        XCTAssertEqual(CameraVideoQuality.high.estimatedGBPerHour, 2.7, accuracy: 0.001)
    }

    private static func credentials(session: String = "session-1", expiresAt: Date = Date().addingTimeInterval(1_800)) -> CameraLiveCredentials {
        CameraLiveCredentials(
            sessionId: session,
            viewerURL: URL(string: "wss://bridge.example/ws/video/live/viewer?session=\(session)")!,
            viewerToken: "viewer-token",
            connectExpiresAt: Date().addingTimeInterval(60),
            expiresAt: expiresAt
        )
    }
}

@MainActor
private final class FakeRenderer: CameraVideoRendering {
    private(set) var clearCount = 0
    private var onClear: (() -> Void)?
    init(onClear: @escaping () -> Void = {}) { self.onClear = onClear }
    func consume(_ packet: CameraVideoPacket) throws -> Bool {
        if case .accessUnit = packet.payload { return true }
        return false
    }
    func clear() {
        clearCount += 1
        let callback = onClear
        onClear = nil
        callback?()
    }
}

private final class FakeCameraLiveSocket: CameraLiveSocket {
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private(set) var cancelled = false

    init() {
        var saved: AsyncThrowingStream<Data, Error>.Continuation!
        stream = AsyncThrowingStream { saved = $0 }
        continuation = saved
    }

    func messages() -> AsyncThrowingStream<Data, Error> { stream }
    func resume() {}
    func cancel() { cancelled = true; continuation.finish() }
    func yield(_ data: Data) { continuation.yield(data) }
    func fail(_ error: Error) { continuation.finish(throwing: error) }
}
