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

    func testRendererFailureBlanksAndWaitsForKeyframe() async {
        let socket = FakeCameraLiveSocket()
        let renderer = FakeRenderer()
        let transport = CameraLiveTransport(createSession: { _ in Self.credentials() }, openSocket: { _ in socket }, stopSession: { _ in })
        let session = CameraLiveSession(transport: transport, renderer: renderer, bridgeURL: { "https://bridge.example" }, bridgeToken: { "owner" })
        await session.start()
        socket.yield(CameraVideoProtocolTests.config())
        socket.yield(CameraVideoProtocolTests.access())
        await renderer.waitForDisplayedFrames(1)
        XCTAssertEqual(session.state, .live)

        renderer.failAsynchronously()
        await Task.yield()
        XCTAssertEqual(session.state, .degraded)

        socket.yield(CameraVideoProtocolTests.access(sequence: 3, keyframe: false))
        await Task.yield()
        XCTAssertEqual(session.state, .degraded)
        socket.yield(CameraVideoProtocolTests.access(sequence: 4, keyframe: true))
        await renderer.waitForDisplayedFrames(2)
        XCTAssertEqual(session.state, .live)
        await session.stop()
    }

    func testSocketReceptionKeepsOnlyOneOutstandingDemand() async {
        let socket = FakeCameraLiveSocket()
        let renderer = FakeRenderer()
        let transport = CameraLiveTransport(createSession: { _ in Self.credentials() }, openSocket: { _ in socket }, stopSession: { _ in })
        let session = CameraLiveSession(transport: transport, renderer: renderer, bridgeURL: { "https://bridge.example" }, bridgeToken: { "owner" })
        await session.start()
        await socket.waitForReceiveCalls(1)
        socket.yield(CameraVideoProtocolTests.config())
        await socket.waitForReceiveCalls(2)
        socket.yield(CameraVideoProtocolTests.access())
        await socket.waitForReceiveCalls(3)

        XCTAssertEqual(socket.maximumConcurrentReceives, 1)
        await session.stop()
    }

    func testSupersededStartDeletesOldCredentialsWithoutReplacingNewSession() async {
        let deferred = DeferredCredentials()
        var opened: [String] = []
        var stopped: [String] = []
        let transport = CameraLiveTransport(
            createSession: { _ in try await deferred.next() },
            openSocket: { request in
                opened.append(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value ?? "")
                return FakeCameraLiveSocket()
            },
            stopSession: { request in stopped.append(request.url!.lastPathComponent) }
        )
        let session = CameraLiveSession(transport: transport, renderer: FakeRenderer(), bridgeURL: { "https://bridge.example" }, bridgeToken: { "owner" })

        let oldStart = Task { await session.start() }
        await deferred.waitForRequests(1)
        await session.stop()
        let newStart = Task { await session.start() }
        await deferred.waitForRequests(2)
        deferred.succeed(index: 1, with: Self.credentials(session: "new"))
        await newStart.value
        deferred.succeed(index: 0, with: Self.credentials(session: "old"))
        await oldStart.value

        XCTAssertEqual(opened, ["new"])
        XCTAssertTrue(stopped.contains("old"))
        XCTAssertEqual(session.state, .connecting)
        await session.stop()
    }

    func testSupersededStartFailureCannotDisableNewSession() async {
        let deferred = DeferredCredentials()
        var opened: [String] = []
        let transport = CameraLiveTransport(
            createSession: { _ in try await deferred.next() },
            openSocket: { request in
                opened.append(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value ?? "")
                return FakeCameraLiveSocket()
            },
            stopSession: { _ in }
        )
        let session = CameraLiveSession(transport: transport, renderer: FakeRenderer(), bridgeURL: { "https://bridge.example" }, bridgeToken: { "owner" })

        let oldStart = Task { await session.start() }
        await deferred.waitForRequests(1)
        await session.stop()
        let newStart = Task { await session.start() }
        await deferred.waitForRequests(2)
        deferred.succeed(index: 1, with: Self.credentials(session: "new"))
        await newStart.value
        deferred.fail(index: 0, with: CameraLiveError.offline)
        await oldStart.value

        XCTAssertEqual(opened, ["new"])
        XCTAssertEqual(session.state, .connecting)
        await session.stop()
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
    private var failureHandler: (() -> Void)?
    private var requiresKeyframe = false
    private var displayedFrames = 0
    private var displayWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    init(onClear: @escaping () -> Void = {}) { self.onClear = onClear }
    func consume(_ packet: CameraVideoPacket) throws -> Bool {
        if case .accessUnit(_, let keyframe) = packet.payload {
            if requiresKeyframe && !keyframe { return false }
            requiresKeyframe = false
            displayedFrames += 1
            let ready = displayWaiters.filter { displayedFrames >= $0.0 }
            displayWaiters.removeAll { displayedFrames >= $0.0 }
            ready.forEach { $0.1.resume() }
            return true
        }
        return false
    }
    func setFailureHandler(_ handler: @escaping () -> Void) { failureHandler = handler }
    func failAsynchronously() { failureHandler?() }
    func waitForDisplayedFrames(_ count: Int) async {
        if displayedFrames >= count { return }
        await withCheckedContinuation { displayWaiters.append((count, $0)) }
    }
    func clear() {
        clearCount += 1
        requiresKeyframe = true
        let callback = onClear
        onClear = nil
        callback?()
    }
}

private final class FakeCameraLiveSocket: CameraLiveSocket {
    private(set) var cancelled = false
    private(set) var maximumConcurrentReceives = 0
    private var activeReceives = 0
    private var receiveCalls = 0
    private var queued: [Result<Data, Error>] = []
    private var waiter: CheckedContinuation<Data, Error>?
    private var callWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func receive() async throws -> Data {
        receiveCalls += 1
        activeReceives += 1
        maximumConcurrentReceives = max(maximumConcurrentReceives, activeReceives)
        let ready = callWaiters.filter { receiveCalls >= $0.0 }
        callWaiters.removeAll { receiveCalls >= $0.0 }
        ready.forEach { $0.1.resume() }
        defer { activeReceives -= 1 }
        if !queued.isEmpty { return try queued.removeFirst().get() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func resume() {}
    func cancel() {
        cancelled = true
        waiter?.resume(throwing: CancellationError())
        waiter = nil
    }
    func yield(_ data: Data) { complete(.success(data)) }
    func fail(_ error: Error) { complete(.failure(error)) }
    func waitForReceiveCalls(_ count: Int) async {
        if receiveCalls >= count { return }
        await withCheckedContinuation { callWaiters.append((count, $0)) }
    }
    private func complete(_ result: Result<Data, Error>) {
        if let waiter {
            self.waiter = nil
            waiter.resume(with: result)
        } else {
            queued.append(result)
        }
    }
}

@MainActor
private final class DeferredCredentials {
    private var continuations: [CheckedContinuation<CameraLiveCredentials, Error>?] = []
    private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func next() async throws -> CameraLiveCredentials {
        let index = continuations.count
        continuations.append(nil)
        let ready = requestWaiters.filter { index + 1 >= $0.0 }
        requestWaiters.removeAll { index + 1 >= $0.0 }
        ready.forEach { $0.1.resume() }
        return try await withCheckedThrowingContinuation { continuations[index] = $0 }
    }

    func waitForRequests(_ count: Int) async {
        if continuations.count >= count { return }
        await withCheckedContinuation { requestWaiters.append((count, $0)) }
    }

    func succeed(index: Int, with value: CameraLiveCredentials) {
        continuations[index]?.resume(returning: value)
        continuations[index] = nil
    }

    func fail(index: Int, with error: Error) {
        continuations[index]?.resume(throwing: error)
        continuations[index] = nil
    }
}
