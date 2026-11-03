import CryptoKit
import XCTest

#if TASK8_IMPLEMENTED
@MainActor
final class CameraVideoStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCatalogUsesLANFirstAndNeverFallsBackWithoutScopedConfirmation() async throws {
        var transport = CameraVideoTransport.testing
        var lanCalls = 0, remoteCalls = 0
        transport.fetchLANCatalog = { _, _ in lanCalls += 1; throw CameraVideoError.offline }
        transport.fetchRemoteCatalog = { _, _ in remoteCalls += 1; return Self.catalog(route: .internet) }
        let store = makeStore(transport)

        await store.loadCatalog(lanEndpoint: .init(host: "192.168.8.20", port: 8080),
                                bridgeURL: Self.bridge, bridgeToken: "paired")
        XCTAssertEqual(lanCalls, 1); XCTAssertEqual(remoteCalls, 0)
        XCTAssertEqual(store.catalogState, .askingInternet)

        await store.confirmCatalogInternet()
        XCTAssertEqual(remoteCalls, 1)
        XCTAssertEqual(store.catalogState, .loaded(route: .internet, stale: false))
        store.closeCatalogAction()
        await store.loadCatalog(lanEndpoint: nil, bridgeURL: Self.bridge, bridgeToken: "paired")
        XCTAssertEqual(remoteCalls, 1, "A new gallery action must ask again")
    }

    func testCatalogPreservesStaleTripsOfflineAndOmitsActiveOrIncompleteTrips() async {
        var transport = CameraVideoTransport.testing
        transport.fetchLANCatalog = { _, _ in
            CameraVideoCatalog(revision: 3, updatedAt: Date(), stale: true, route: .lan,
                trips: [Self.trip(), Self.trip(id: "8", completed: false), Self.trip(id: "9", end: nil)])
        }
        let store = makeStore(transport)
        await store.loadCatalog(lanEndpoint: .init(host: "192.168.8.20", port: 8080),
                                bridgeURL: Self.bridge, bridgeToken: "paired")
        XCTAssertEqual(store.trips.map(\.id), ["42"])
        XCTAssertEqual(store.catalogState, .loaded(route: .lan, stale: true))

        transport.fetchLANCatalog = { _, _ in throw CameraVideoError.offline }
        store.replaceTransportForTesting(transport)
        await store.reloadCatalog()
        XCTAssertEqual(store.trips.map(\.id), ["42"])
        XCTAssertEqual(store.catalogState, .offline(stale: true))
    }

    func testLANResumeUsesExactRangeAndRouteSpecificPartialIdentity() async throws {
        var transport = CameraVideoTransport.testing
        let bytes = Data("abcdef".utf8), segment = Self.segment(bytes)
        var observedOffset: UInt64?
        transport.downloadLANSegment = { _, _, _, offset, _, _ in
            observedOffset = offset
            return CameraLANDownload(statusCode: 206, contentRange: "bytes 3-5/6", chunks: [Data("def".utf8)])
        }
        let store = makeStore(transport)
        let lanPartial = store.partialURL(tripID: "42", segmentID: 1, route: .lan)
        let remotePartial = store.partialURL(tripID: "42", segmentID: 1, route: .internet)
        XCTAssertNotEqual(lanPartial, remotePartial)
        try FileManager.default.createDirectory(at: lanPartial.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: lanPartial)

        let result = try await store.downloadSegment(tripID: "42", segment: segment, route: .lan,
            lanEndpoint: .init(host: "192.168.8.20", port: 8080), bridgeURL: Self.bridge, bridgeToken: "paired")
        XCTAssertEqual(observedOffset, 3)
        XCTAssertEqual(try Data(contentsOf: result), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lanPartial.path))
    }

    func testChunkAndWholeDigestFailuresNeverPromoteOrAcknowledgeInvalidBytes() async throws {
        let bytes = Data("abc".utf8), segment = Self.segment(bytes)
        let badChunk = Self.hvtData(payload: bytes, digest: Data(repeating: 0, count: 32))
        let socket = FakeTransferSocket(messages: [badChunk])
        var transport = CameraVideoTransport.testing
        transport.openRemoteTransfer = { _, _, _, _, _ in socket }
        let store = makeStore(transport)
        await XCTAssertThrowsErrorAsync {
            try await store.downloadSegment(tripID: "42", segment: segment, route: .internet,
                lanEndpoint: nil, bridgeURL: Self.bridge, bridgeToken: "paired")
        }
        XCTAssertTrue(socket.sent.isEmpty)

        let wrongWhole = CameraVideoSegment(id: 1, byteSize: 3, sha256: Data(repeating: 1, count: 32))
        let socket2 = FakeTransferSocket(messages: [Self.hvtData(payload: bytes), Self.hvtEOF(bytes: bytes)])
        transport.openRemoteTransfer = { _, _, _, _, _ in socket2 }
        store.replaceTransportForTesting(transport)
        await XCTAssertThrowsErrorAsync {
            try await store.downloadSegment(tripID: "42", segment: wrongWhole, route: .internet,
                lanEndpoint: nil, bridgeURL: Self.bridge, bridgeToken: "paired")
        }
        XCTAssertEqual(socket2.sent.count, 1, "DATA ACK is durable, but invalid EOF is never ACKed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.completedURL(tripID: "42", segmentID: 1).path))
    }

    func testRemoteACKFollowsDurableWriteAndRequiresExactOffset() async throws {
        let bytes = Data("abc".utf8), segment = Self.segment(bytes)
        let socket = FakeTransferSocket(messages: [Self.hvtData(payload: bytes), Self.hvtEOF(bytes: bytes)])
        var transport = CameraVideoTransport.testing
        transport.openRemoteTransfer = { _, _, _, _, _ in socket }
        let store = makeStore(transport)
        socket.onSend = { frame in
            let ack = try CameraTransferProtocol.parse(frame)
            let partial = store.partialURL(tripID: "42", segmentID: 1, route: .internet)
            XCTAssertGreaterThanOrEqual((try? Data(contentsOf: partial).count) ?? 0, Int(ack.offset))
        }
        _ = try await store.downloadSegment(tripID: "42", segment: segment, route: .internet,
            lanEndpoint: nil, bridgeURL: Self.bridge, bridgeToken: "paired")
        XCTAssertEqual(try socket.sent.map { try CameraTransferProtocol.parse($0).offset }, [3, 3])

        let skipped = FakeTransferSocket(messages: [Self.hvtData(offset: 1, payload: bytes)])
        transport.openRemoteTransfer = { _, _, _, _, _ in skipped }
        store.replaceTransportForTesting(transport)
        try? FileManager.default.removeItem(at: store.completedURL(tripID: "42", segmentID: 1))
        await XCTAssertThrowsErrorAsync {
            try await store.downloadSegment(tripID: "42", segment: segment, route: .internet,
                lanEndpoint: nil, bridgeURL: Self.bridge, bridgeToken: "paired")
        }
        XCTAssertTrue(skipped.sent.isEmpty)
    }

    func testStorageCancellationDuplicateAndAtomicPromotionBoundaries() async throws {
        let bytes = Data("abc".utf8), segment = Self.segment(bytes)
        let noSpace = CameraVideoStore(rootURL: root, transport: .testing, availableCapacity: { _ in 2 })
        await XCTAssertThrowsErrorAsync {
            try await noSpace.downloadSegment(tripID: "42", segment: segment, route: .lan,
                lanEndpoint: .init(host: "192.168.8.20", port: 8080), bridgeURL: Self.bridge, bridgeToken: "paired")
        }

        var transport = CameraVideoTransport.testing
        var downloads = 0
        transport.downloadLANSegment = { _, _, _, _, _, _ in downloads += 1; return .init(statusCode: 200, contentRange: nil, chunks: [bytes]) }
        let store = makeStore(transport)
        let first = try await store.downloadSegment(tripID: "42", segment: segment, route: .lan,
            lanEndpoint: .init(host: "192.168.8.20", port: 8080), bridgeURL: Self.bridge, bridgeToken: "paired")
        let second = try await store.downloadSegment(tripID: "42", segment: segment, route: .lan,
            lanEndpoint: .init(host: "192.168.8.20", port: 8080), bridgeURL: Self.bridge, bridgeToken: "paired")
        XCTAssertEqual(first, second); XCTAssertEqual(downloads, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.partialURL(tripID: "42", segmentID: 1, route: .lan).path))

        transport.downloadLANSegment = { _, _, _, _, _, _ in try await Task.sleep(for: .seconds(10)); return .init(statusCode: 200, contentRange: nil, chunks: [bytes]) }
        store.replaceTransportForTesting(transport)
        try? FileManager.default.removeItem(at: first)
        let task = Task { try await store.downloadSegment(tripID: "42", segment: segment, route: .lan,
            lanEndpoint: .init(host: "192.168.8.20", port: 8080), bridgeURL: Self.bridge, bridgeToken: "paired") }
        task.cancel()
        await XCTAssertThrowsErrorAsync { _ = try await task.value }
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
    }

    func testOrderedPlaybackSafeShareAndSeparateDeletionConfirmation() async throws {
        let store = makeStore(.testing)
        let trip = Self.trip(segments: [Self.segment(Data("a".utf8), id: 1), Self.segment(Data("b".utf8), id: 2)])
        for segment in trip.segments.reversed() {
            let url = store.completedURL(tripID: trip.id, segmentID: segment.id)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(segment.id == 1 ? "a".utf8 : "b".utf8).write(to: url)
        }
        XCTAssertEqual(try store.playbackURLs(for: trip).map(\.lastPathComponent), ["000001.mp4", "000002.mp4"])
        XCTAssertEqual(try store.shareURLs(for: trip), try store.playbackURLs(for: trip))

        var transport = CameraVideoTransport.testing
        var deletions = 0
        transport.deleteRecordings = { _, _, ids, confirmation in
            XCTAssertEqual(ids, ["42"]); XCTAssertEqual(confirmation, "DELETE_COMPLETED"); deletions += 1
        }
        store.replaceTransportForTesting(transport)
        await XCTAssertThrowsErrorAsync { try await store.deleteRecordings(["42"], confirmed: false, bridgeURL: Self.bridge, bridgeToken: "paired") }
        XCTAssertEqual(deletions, 0)
        try await store.deleteRecordings(["42"], confirmed: true, bridgeURL: Self.bridge, bridgeToken: "paired")
        XCTAssertEqual(deletions, 1)
    }

    func testSettingsOptimismAuthoritativeReplacementConflictAndRollback() async throws {
        let initial = CameraSettings.fixture(quality: .standard, reserveGB: 5)
        let confirmed = CameraSettings.fixture(quality: .high, reserveGB: 1)
        var transport = CameraVideoTransport.testing
        transport.fetchSettings = { _, _ in .init(revision: 7, settings: initial, updatedAt: Date(), stale: false, conflict: false) }
        transport.updateSettings = { _, _, revision, patch in
            XCTAssertEqual(revision, 7); XCTAssertEqual(patch.reserveGB, 1)
            return .init(revision: 8, settings: confirmed, updatedAt: Date(), stale: false, conflict: false)
        }
        let store = makeStore(transport)
        await store.loadSettings(bridgeURL: Self.bridge, bridgeToken: "paired")
        await store.updateSettings(.init(reserveGB: 1), bridgeURL: Self.bridge, bridgeToken: "paired")
        XCTAssertEqual(store.settingsRevision, 8); XCTAssertEqual(store.settings, confirmed)

        let conflict = CameraSettings.fixture(quality: .economy, reserveGB: 10)
        transport.updateSettings = { _, _, _, _ in
            .init(revision: 9, settings: conflict, updatedAt: Date(), stale: false, conflict: true)
        }
        store.replaceTransportForTesting(transport)
        await store.updateSettings(.init(quality: .high), bridgeURL: Self.bridge, bridgeToken: "paired")
        XCTAssertEqual(store.settingsRevision, 9); XCTAssertEqual(store.settings, conflict)
        XCTAssertEqual(store.settingsState, .conflict)

        transport.updateSettings = { _, _, _, _ in throw CameraVideoError.offline }
        store.replaceTransportForTesting(transport)
        await store.updateSettings(.init(reserveGB: 20), bridgeURL: Self.bridge, bridgeToken: "paired")
        XCTAssertEqual(store.settings, conflict); XCTAssertEqual(store.settingsState, .failed)
    }

    private func makeStore(_ transport: CameraVideoTransport) -> CameraVideoStore {
        CameraVideoStore(rootURL: root, transport: transport, availableCapacity: { _ in 1_000_000 })
    }

    private static let bridge = URL(string: "https://bridge.example")!
    private static func segment(_ bytes: Data, id: UInt32 = 1) -> CameraVideoSegment {
        .init(id: id, byteSize: UInt64(bytes.count), sha256: Data(SHA256.hash(data: bytes)))
    }
    private static func trip(id: String = "42", completed: Bool = true, end: Date? = Date(),
                             segments: [CameraVideoSegment]? = nil) -> CameraVideoTrip {
        let segments = segments ?? [segment(Data("abc".utf8))]
        return .init(id: id, source: .automatic, start: Date(timeIntervalSince1970: 1), end: end,
                     byteSize: segments.reduce(0) { $0 + $1.byteSize }, completed: completed, segments: segments)
    }
    private static func catalog(route: CameraDownloadRoute) -> CameraVideoCatalog {
        .init(revision: 1, updatedAt: Date(), stale: false, route: route, trips: [trip()])
    }
    private static func hvtData(offset: UInt64 = 0, payload: Data, digest: Data? = nil) -> Data {
        var frame = try! CameraTransferProtocol.data(ordinal: 1, offset: offset, payload: payload)
        if let digest { frame.replaceSubrange(24..<56, with: digest) }
        return frame
    }
    private static func hvtEOF(bytes: Data) -> Data {
        try! CameraTransferProtocol.eof(ordinal: 1, totalBytes: UInt64(bytes.count), digest: Data(SHA256.hash(data: bytes)))
    }
}

private final class FakeTransferSocket: CameraTransferSocket {
    private var messages: [Data]
    var sent: [Data] = []
    var onSend: ((Data) throws -> Void)?
    init(messages: [Data]) { self.messages = messages }
    func receive() async throws -> Data {
        guard !messages.isEmpty else { throw CameraVideoError.disconnected }
        return messages.removeFirst()
    }
    func send(_ data: Data) async throws { try onSend?(data); sent.append(data) }
    func close() {}
}

private extension CameraSettings {
    static func fixture(quality: CameraVideoQuality, reserveGB: Int) -> Self {
        .init(automaticRecording: true, recordParkedLive: false, remoteLive: true,
              remoteDownloads: true, automaticDeletion: true, overlayMaster: true,
              overlayDateTime: true, overlaySpeed: true, overlayAcceleration: true,
              overlayDriveState: true, overlayDecelerationRegen: true, quality: quality,
              reserveGB: reserveGB, overlayPosition: .topLeft)
    }
}

private func XCTAssertThrowsErrorAsync<T>(_ expression: () async throws -> T,
                                          file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await expression(); XCTFail("Expected error", file: file, line: line) }
    catch { }
}
#else
final class CameraVideoStoreTests: XCTestCase {
    func testTask8StoreContractIsImplemented() {
        XCTFail("Task 8 RED: camera recordings store is not implemented")
    }
}
#endif
