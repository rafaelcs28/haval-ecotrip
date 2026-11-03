import CryptoKit
import Foundation
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
        await store.closeCatalogAction()
        await store.loadCatalog(lanEndpoint: nil, bridgeURL: Self.bridge, bridgeToken: "paired")
        XCTAssertEqual(remoteCalls, 1, "A new gallery action must ask again")
    }

    func testRemoteDownloadRequiresFreshActionScopedConfirmation() async throws {
        let bytes = Data("abc".utf8), segment = Self.segment(bytes)
        var remoteCalls = 0
        var transport = CameraVideoTransport.testing
        transport.openRemoteTransfer = { _, _, _, _, _ in
            remoteCalls += 1
            return FakeTransferSocket(messages: [Self.hvtData(payload: bytes), Self.hvtEOF(bytes: bytes)])
        }
        let store = makeStore(transport)

        XCTAssertEqual(store.beginDownloadAction(lanAvailable: false), .askInternet)
        await XCTAssertThrowsErrorAsync {
            try await store.downloadSegment(tripID: "42", segment: segment, route: .internet,
                lanEndpoint: nil, bridgeURL: Self.bridge, bridgeToken: "paired")
        }
        XCTAssertEqual(remoteCalls, 0)

        store.confirmDownloadInternet()
        _ = try await store.downloadSegment(tripID: "42", segment: segment, route: .internet,
            lanEndpoint: nil, bridgeURL: Self.bridge, bridgeToken: "paired")
        XCTAssertEqual(remoteCalls, 1)

        try FileManager.default.removeItem(at: try store.completedURL(tripID: "42", segmentID: 1))
        XCTAssertEqual(store.beginDownloadAction(lanAvailable: false), .askInternet,
                       "A new download must invalidate the previous consent")
        await XCTAssertThrowsErrorAsync {
            try await store.downloadSegment(tripID: "42", segment: segment, route: .internet,
                lanEndpoint: nil, bridgeURL: Self.bridge, bridgeToken: "paired")
        }
        XCTAssertEqual(remoteCalls, 1)

        store.confirmDownloadInternet()
        XCTAssertEqual(store.beginDownloadAction(lanAvailable: true), .useLAN,
                       "Returning to LAN must invalidate remote consent")
        await XCTAssertThrowsErrorAsync {
            try await store.downloadSegment(tripID: "42", segment: segment, route: .internet,
                lanEndpoint: nil, bridgeURL: Self.bridge, bridgeToken: "paired")
        }
        XCTAssertEqual(remoteCalls, 1)
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

    func testCanonicalCatalogMetadataMakesARealSegmentDownloadEligible() async throws {
        let sha = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let data = Data(("{\"ok\":true,\"catalogRevision\":7,\"updatedAt\":1000,\"stale\":false," +
            "\"trips\":[{\"tripId\":\"42\",\"source\":\"automatic\",\"startMs\":1,\"endMs\":2," +
            "\"byteSize\":3,\"completed\":true,\"segmentCount\":1,\"segments\":[{" +
            "\"segmentId\":1,\"byteSize\":3,\"sha256\":\"\(sha)\"}]}]}").utf8)
        let catalog = try CameraVideoCatalog.decode(data, route: .lan)
        var transport = CameraVideoTransport.testing
        transport.fetchLANCatalog = { _, _ in catalog }
        transport.openLANSegment = { _, _, _, _, _, _ in
            FakeLANStream(statusCode: 200, contentRange: nil, contentLength: 3,
                          chunks: [Data("abc".utf8)])
        }
        let store = makeStore(transport)
        await store.loadCatalog(lanEndpoint: Self.lan, bridgeURL: Self.bridge, bridgeToken: "paired")

        XCTAssertEqual(store.trips.count, 1)
        XCTAssertEqual(store.trips[0].segments.count, 1)
        let segment = store.trips[0].segments[0]
        let url = try await store.downloadSegment(tripID: "42", segment: segment, route: .lan,
            lanEndpoint: Self.lan, bridgeURL: Self.bridge, bridgeToken: "paired")

        XCTAssertEqual(try Data(contentsOf: url), Data("abc".utf8))
        XCTAssertEqual(store.localState(tripID: "42", segment: segment), .verified(url))
    }

    func testCatalogRejectsUntrustedIdentityOrderingSizeDigestAndLegacyCount() {
        let sha = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let validSegment = "{\"segmentId\":1,\"byteSize\":3,\"sha256\":\"\(sha)\"}"
        let invalidTrips = [
            ("01", 3, "[\(validSegment)]"),
            ("../42", 3, "[\(validSegment)]"),
            ("18446744073709551616", 3, "[\(validSegment)]"),
            ("42", 3, "[{\"segmentId\":2,\"byteSize\":3,\"sha256\":\"\(sha)\"}]"),
            ("42", 6, "[\(validSegment),\(validSegment)]"),
            ("42", 3, "[{\"segmentId\":1,\"byteSize\":0,\"sha256\":\"\(sha)\"}]"),
            ("42", 4, "[\(validSegment)]"),
            ("42", 3, "[{\"segmentId\":1,\"byteSize\":3,\"sha256\":\"00\"}]"),
        ]
        for (tripID, byteSize, segments) in invalidTrips {
            let json = "{\"trips\":[{\"tripId\":\"\(tripID)\",\"source\":\"automatic\",\"startMs\":1," +
                "\"endMs\":2,\"byteSize\":\(byteSize),\"completed\":true,\"segments\":\(segments)}]}"
            XCTAssertThrowsError(try CameraVideoCatalog.decode(Data(json.utf8), route: .lan), tripID)
        }
        let legacy = "{\"trips\":[{\"tripId\":\"42\",\"source\":\"automatic\",\"startMs\":1," +
            "\"endMs\":2,\"byteSize\":3,\"completed\":true,\"segments\":1}]}"
        XCTAssertThrowsError(try CameraVideoCatalog.decode(Data(legacy.utf8), route: .lan))
    }

    func testGalleryReusesOneLANSessionAndRevokesOnCloseAndFailure() async {
        var transport = CameraVideoTransport.testing
        var fetches = 0, revocations = 0
        transport.fetchLANCatalog = { _, _ in fetches += 1; return Self.catalog(route: .lan) }
        transport.closeLANCatalogSession = { _ in revocations += 1 }
        let store = makeStore(transport)
        for _ in 0..<20 {
            await store.loadCatalog(lanEndpoint: Self.lan, bridgeURL: Self.bridge, bridgeToken: "paired")
            await store.reloadCatalog()
            await store.closeCatalogAction()
        }
        XCTAssertEqual(fetches, 40)
        XCTAssertEqual(revocations, 20, "Repeated galleries must not consume the 16-session server cap")

        transport.fetchLANCatalog = { _, _ in throw CameraVideoError.offline }
        store.replaceTransportForTesting(transport)
        await store.loadCatalog(lanEndpoint: Self.lan, bridgeURL: Self.bridge, bridgeToken: "paired")
        XCTAssertEqual(revocations, 21, "Terminal LAN failure must revoke the action session")
    }

    func testLANHTTPAdapterReusesShortCredentialStreamsTempFileAndRevokes() async throws {
        let sessionID = "0123456789abcdef0123456789abcdef"
        let downloadToken = "download-token-012345678901234567890123"
        let controlToken = "control-token-0123456789012345678901234"
        let bridgeToken = "paired"
        let nonce = "000102030405060708090a0b0c0d0e0f"
        let expires: Int64 = 31_000
        let key = SymmetricKey(data: Data(bridgeToken.utf8))
        let proof = Data(HMAC<SHA256>.authenticationCode(
            for: Data("haval-camera-lan-server-v1|car-1|\(nonce)|\(expires)".utf8), using: key)).hex
        let catalog = Self.catalogJSON()
        var sessionCreates = 0, deletes = 0
        let temp = root.appendingPathComponent("adapter-body")
        try Data("bc".utf8).write(to: temp)
        let http = CameraVideoHTTPClient(data: { request in
            let path = try XCTUnwrap(request.url?.path)
            switch (request.httpMethod ?? "GET", path) {
            case ("GET", "/api/capabilities"):
                return (Data("{\"cameraDownloadLan\":1,\"hvtVersion\":1}".utf8), Self.response(request, 200))
            case ("POST", "/api/video/lan/challenge"):
                return (Data("{\"deviceId\":\"car-1\",\"nonce\":\"\(nonce)\",\"expiresAt\":\(expires),\"serverProof\":\"\(proof)\"}".utf8), Self.response(request, 200))
            case ("POST", "/api/video/lan/session"):
                sessionCreates += 1
                return (Data("{\"sessionId\":\"\(sessionID)\",\"scope\":\"download\",\"downloadToken\":\"\(downloadToken)\",\"controlToken\":\"\(controlToken)\",\"expiresAt\":301000}".utf8), Self.response(request, 201))
            case ("GET", "/api/video/lan/catalog"):
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(downloadToken)")
                return (catalog, Self.response(request, 200))
            case ("DELETE", "/api/video/lan/session/\(sessionID)"):
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(controlToken)")
                deletes += 1
                return (Data(), Self.response(request, 204))
            default: throw CameraVideoError.invalidResponse
            }
        }, download: { request in
            XCTAssertEqual(request.url?.path, "/api/video/lan/trips/42/segments/1")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(downloadToken)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=1-")
            return (temp, Self.response(request, 206,
                headers: ["Content-Range": "bytes 1-2/3", "Content-Length": "2"]))
        }, webSocket: { _, _, _ in throw CameraVideoError.invalidResponse })
        let network = CameraVideoNetwork(http: http, now: { 1_000 })

        _ = try await network.fetchLANCatalog(endpoint: Self.lan, bridgeToken: bridgeToken)
        let stream = try await network.openLANSegment(tripID: "42", segment: Self.segment(Data("abc".utf8)),
            ordinal: 1, offset: 1, endpoint: Self.lan, bridgeToken: bridgeToken)
        let streamedCount = try await stream.nextChunk()?.count ?? 0
        XCTAssertLessThanOrEqual(streamedCount, 64 * 1_024)
        await network.closeLANCatalogSession(endpoint: Self.lan)

        XCTAssertEqual(sessionCreates, 1)
        XCTAssertEqual(deletes, 1)
    }

    func testRemoteHTTPAndWebSocketAdapterDeletesTerminalSessionAndDropsCachedID() async throws {
        let sessionID = "remote_session_1"
        var posts = 0, deletes = 0
        let socket = FakeTransferSocket(messages: [])
        let http = CameraVideoHTTPClient(data: { request in
            switch (request.httpMethod ?? "GET", request.url?.path ?? "") {
            case ("POST", "/api/video/transfer/session"):
                posts += 1
                return (Data("{\"sessionId\":\"\(sessionID)\",\"viewerUrl\":\"wss://bridge.example/ws/video/transfer/viewer?session=remote_session_1\",\"viewerToken\":\"short-viewer-token\",\"offsets\":{\"1\":\"0\"}}".utf8), Self.response(request, 201))
            case ("DELETE", "/api/video/transfer/session/\(sessionID)"):
                deletes += 1
                return (Data(), Self.response(request, 204))
            default: throw CameraVideoError.invalidResponse
            }
        }, download: { _ in throw CameraVideoError.invalidResponse }, webSocket: { request, offset, id in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer short-viewer-token")
            XCTAssertEqual(offset, 0); XCTAssertEqual(id, sessionID)
            return socket
        })
        let network = CameraVideoNetwork(http: http)
        _ = try await network.openRemoteTransfer(tripID: "42", segment: Self.segment(Data("abc".utf8)),
                                                  offset: 0, base: Self.bridge, token: "paired")
        await network.releaseRemoteTransfer(tripID: "42", segmentID: 1, base: Self.bridge,
                                            token: "paired", terminate: true)
        await network.releaseRemoteTransfer(tripID: "42", segmentID: 1, base: Self.bridge,
                                            token: "paired", terminate: true)
        XCTAssertEqual(posts, 1); XCTAssertEqual(deletes, 1)
    }

    func testLANResumeUsesExactRangeAndRouteSpecificPartialIdentity() async throws {
        var transport = CameraVideoTransport.testing
        let bytes = Data("abcdef".utf8), segment = Self.segment(bytes)
        var observedOffset: UInt64?
        transport.openLANSegment = { _, _, _, offset, _, _ in
            observedOffset = offset
            return FakeLANStream(statusCode: 206, contentRange: "bytes 3-5/6", contentLength: 3,
                                 chunks: [Data("def".utf8)])
        }
        let store = makeStore(transport)
        let lanPartial = try store.partialURL(tripID: "42", segmentID: 1, route: .lan)
        let remotePartial = try store.partialURL(tripID: "42", segmentID: 1, route: .internet)
        XCTAssertNotEqual(lanPartial, remotePartial)
        try FileManager.default.createDirectory(at: lanPartial.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: lanPartial)

        let result = try await store.downloadSegment(tripID: "42", segment: segment, route: .lan,
            lanEndpoint: .init(host: "192.168.8.20", port: 8080), bridgeURL: Self.bridge, bridgeToken: "paired")
        XCTAssertEqual(observedOffset, 3)
        XCTAssertEqual(try Data(contentsOf: result), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lanPartial.path))
    }

    func testLANRequiresExactStatusRangeAndLengthForFreshAndResumedResponses() async throws {
        let bytes = Data("abc".utf8), segment = Self.segment(bytes)
        let invalid: [(UInt64, Int, String?, UInt64?)] = [
            (0, 206, nil, 3),
            (0, 200, "bytes 0-2/3", 3),
            (0, 200, nil, 2),
            (0, 200, nil, nil),
            (1, 200, "bytes 1-2/3", 2),
            (1, 206, "bytes 0-2/3", 3),
            (1, 206, "bytes 1-2/3", 1),
        ]
        for (offset, status, range, length) in invalid {
            let caseRoot = root.appendingPathComponent(UUID().uuidString)
            var transport = CameraVideoTransport.testing
            transport.openLANSegment = { _, _, _, _, _, _ in
                FakeLANStream(statusCode: status, contentRange: range, contentLength: length,
                              chunks: [Data(bytes.dropFirst(Int(offset)))])
            }
            let store = CameraVideoStore(rootURL: caseRoot, transport: transport, availableCapacity: { _ in 100 })
            if offset > 0 {
                let partial = try store.partialURL(tripID: "42", segmentID: 1, route: .lan)
                try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(bytes.prefix(Int(offset))).write(to: partial)
            }
            await XCTAssertThrowsErrorAsync {
                try await store.downloadSegment(tripID: "42", segment: segment, route: .lan,
                    lanEndpoint: Self.lan, bridgeURL: Self.bridge, bridgeToken: "paired")
            }
        }
    }

    func testChunkAndWholeDigestFailuresNeverPromoteOrAcknowledgeInvalidBytes() async throws {
        let bytes = Data("abc".utf8), segment = Self.segment(bytes)
        let badChunk = Self.hvtData(payload: bytes, digest: Data(repeating: 0, count: 32))
        let socket = FakeTransferSocket(messages: [badChunk])
        var transport = CameraVideoTransport.testing
        transport.openRemoteTransfer = { _, _, _, _, _ in socket }
        let store = makeStore(transport)
        authorizeRemoteDownload(store)
        await XCTAssertThrowsErrorAsync {
            try await store.downloadSegment(tripID: "42", segment: segment, route: .internet,
                lanEndpoint: nil, bridgeURL: Self.bridge, bridgeToken: "paired")
        }
        XCTAssertTrue(socket.sent.isEmpty)

        let wrongWhole = CameraVideoSegment(id: 1, byteSize: 3, sha256: Data(repeating: 1, count: 32))
        let socket2 = FakeTransferSocket(messages: [Self.hvtData(payload: bytes), Self.hvtEOF(bytes: bytes)])
        transport.openRemoteTransfer = { _, _, _, _, _ in socket2 }
        store.replaceTransportForTesting(transport)
        authorizeRemoteDownload(store)
        await XCTAssertThrowsErrorAsync {
            try await store.downloadSegment(tripID: "42", segment: wrongWhole, route: .internet,
                lanEndpoint: nil, bridgeURL: Self.bridge, bridgeToken: "paired")
        }
        XCTAssertEqual(socket2.sent.count, 1, "DATA ACK is durable, but invalid EOF is never ACKed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store.completedURL(tripID: "42", segmentID: 1).path))
    }

    func testRemoteACKFollowsDurableWriteAndRequiresExactOffset() async throws {
        let bytes = Data("abc".utf8), segment = Self.segment(bytes)
        let socket = FakeTransferSocket(messages: [Self.hvtData(payload: bytes), Self.hvtEOF(bytes: bytes)])
        var transport = CameraVideoTransport.testing
        transport.openRemoteTransfer = { _, _, _, _, _ in socket }
        let store = makeStore(transport)
        authorizeRemoteDownload(store)
        socket.onSend = { frame in
            let ack = try CameraTransferProtocol.parse(frame)
            let partial = try store.partialURL(tripID: "42", segmentID: 1, route: .internet)
            XCTAssertGreaterThanOrEqual((try? Data(contentsOf: partial).count) ?? 0, Int(ack.offset))
        }
        _ = try await store.downloadSegment(tripID: "42", segment: segment, route: .internet,
            lanEndpoint: nil, bridgeURL: Self.bridge, bridgeToken: "paired")
        XCTAssertEqual(try socket.sent.map { try CameraTransferProtocol.parse($0).offset }, [3, 3])

        let skipped = FakeTransferSocket(messages: [Self.hvtData(offset: 1, payload: bytes)])
        transport.openRemoteTransfer = { _, _, _, _, _ in skipped }
        store.replaceTransportForTesting(transport)
        try? FileManager.default.removeItem(at: try store.completedURL(tripID: "42", segmentID: 1))
        authorizeRemoteDownload(store)
        await XCTAssertThrowsErrorAsync {
            try await store.downloadSegment(tripID: "42", segment: segment, route: .internet,
                lanEndpoint: nil, bridgeURL: Self.bridge, bridgeToken: "paired")
        }
        XCTAssertTrue(skipped.sent.isEmpty)
    }

    func testRemoteResumeUsesPartialOffsetAndWriteSynchronizePrecedeACK() async throws {
        let bytes = Data("abcd".utf8), segment = Self.segment(bytes)
        let socket = FakeTransferSocket(messages: [Self.hvtData(offset: 2, payload: Data("cd".utf8)),
                                                    Self.hvtEOF(bytes: bytes)], authoritativeOffset: 2)
        var openedOffset: UInt64?
        var transport = CameraVideoTransport.testing
        transport.openRemoteTransfer = { _, _, offset, _, _ in openedOffset = offset; return socket }
        let events = EventLog()
        socket.onSend = { _ in events.values.append("ack") }
        let store = CameraVideoStore(rootURL: root, transport: transport, availableCapacity: { _ in 100 },
            fileSinkFactory: { try ObservingFileSink(url: $0, events: events) })
        let partial = try store.partialURL(tripID: "42", segmentID: 1, route: .internet)
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("ab".utf8).write(to: partial)
        authorizeRemoteDownload(store)

        let url = try await store.downloadSegment(tripID: "42", segment: segment, route: .internet,
            lanEndpoint: nil, bridgeURL: Self.bridge, bridgeToken: "paired")

        XCTAssertEqual(openedOffset, 2)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(Array(events.values.prefix(3)), ["write", "synchronize", "ack"])
    }

    func testRemoteSessionsReleaseSlotsAfterCompletionCancellationAndDeletion() async throws {
        let bytes = Data("abc".utf8), segment = Self.segment(bytes)
        var transport = CameraVideoTransport.testing
        var releases: [Bool] = []
        transport.releaseRemoteTransfer = { _, _, _, _, terminate in releases.append(terminate) }
        transport.deleteRecordings = { _, _, _, _ in }
        transport.openRemoteTransfer = { _, _, _, _, _ in
            FakeTransferSocket(messages: [Self.hvtData(payload: bytes), Self.hvtEOF(bytes: bytes)])
        }
        let store = makeStore(transport)
        authorizeRemoteDownload(store)
        _ = try await store.downloadSegment(tripID: "42", segment: segment, route: .internet,
            lanEndpoint: nil, bridgeURL: Self.bridge, bridgeToken: "paired")
        XCTAssertEqual(releases, [false])

        try FileManager.default.removeItem(at: try store.completedURL(tripID: "42", segmentID: 1))
        transport.openRemoteTransfer = { _, _, _, _, _ in
            FakeTransferSocket(messages: [], receiveDelay: .seconds(10))
        }
        store.replaceTransportForTesting(transport)
        authorizeRemoteDownload(store)
        let task = try store.startDownload(tripID: "42", segment: segment, route: .internet,
            lanEndpoint: nil, bridgeURL: Self.bridge, bridgeToken: "paired")
        await Task.yield()
        await store.cancelDownload(tripID: "42", segmentID: 1)
        _ = await task.result
        XCTAssertEqual(releases, [false, true])

        try await store.deleteRecordings(["42"], confirmed: true, bridgeURL: Self.bridge, bridgeToken: "paired")
        XCTAssertEqual(releases, [false, true], "Deletion adapter owns cleanup of any cached remote IDs")
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
        transport.openLANSegment = { _, _, _, _, _, _ in
            downloads += 1
            return FakeLANStream(statusCode: 200, contentRange: nil, contentLength: 3, chunks: [bytes])
        }
        let store = makeStore(transport)
        let first = try await store.downloadSegment(tripID: "42", segment: segment, route: .lan,
            lanEndpoint: .init(host: "192.168.8.20", port: 8080), bridgeURL: Self.bridge, bridgeToken: "paired")
        let second = try await store.downloadSegment(tripID: "42", segment: segment, route: .lan,
            lanEndpoint: .init(host: "192.168.8.20", port: 8080), bridgeURL: Self.bridge, bridgeToken: "paired")
        XCTAssertEqual(first, second); XCTAssertEqual(downloads, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store.partialURL(tripID: "42", segmentID: 1, route: .lan).path))

        transport.openLANSegment = { _, _, _, _, _, _ in
            FakeLANStream(statusCode: 200, contentRange: nil, contentLength: 3,
                          chunks: [], delay: .seconds(10))
        }
        store.replaceTransportForTesting(transport)
        try? FileManager.default.removeItem(at: first)
        let task = try store.startDownload(tripID: "42", segment: segment, route: .lan,
            lanEndpoint: Self.lan, bridgeURL: Self.bridge, bridgeToken: "paired")
        await Task.yield()
        XCTAssertTrue(store.isDownloading(tripID: "42", segmentID: 1))
        XCTAssertThrowsError(try store.startDownload(tripID: "42", segment: segment, route: .lan,
            lanEndpoint: Self.lan, bridgeURL: Self.bridge, bridgeToken: "paired"))
        await store.cancelDownload(tripID: "42", segmentID: 1)
        if case .success = await task.result { XCTFail("Cancellation must not complete") }
        XCTAssertFalse(store.isDownloading(tripID: "42", segmentID: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
    }

    func testCloseActionCancelsAndJoinsStreamWithoutPromotingCorruptFile() async throws {
        let bytes = Data("abc".utf8), segment = Self.segment(bytes)
        let stream = FakeLANStream(statusCode: 200, contentRange: nil, contentLength: 3,
                                   chunks: [Data("a".utf8)], delayAfterChunks: .seconds(10))
        var transport = CameraVideoTransport.testing
        transport.openLANSegment = { _, _, _, _, _, _ in stream }
        let store = makeStore(transport)
        let task = try store.startDownload(tripID: "42", segment: segment, route: .lan,
            lanEndpoint: Self.lan, bridgeURL: Self.bridge, bridgeToken: "paired")
        while stream.readCount == 0 { await Task.yield() }

        await store.closeDownloadAction()

        if case .success = await task.result { XCTFail("Closed action must cancel its transfer") }
        XCTAssertTrue(stream.cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store.completedURL(tripID: "42", segmentID: 1).path))
        XCTAssertEqual(try Data(contentsOf: try store.partialURL(tripID: "42", segmentID: 1, route: .lan)), Data("a".utf8))
    }

    func testCancellationDuringFileWriteNeverPromotesAndJoinsOwnedTask() async throws {
        let bytes = Data("abc".utf8), segment = Self.segment(bytes)
        var transport = CameraVideoTransport.testing
        transport.openLANSegment = { _, _, _, _, _, _ in
            FakeLANStream(statusCode: 200, contentRange: nil, contentLength: 3, chunks: [bytes])
        }
        var sink: BlockingFileSink?
        let store = CameraVideoStore(rootURL: root, transport: transport, availableCapacity: { _ in 100 },
            fileSinkFactory: { url in
                let value = try BlockingFileSink(url: url); sink = value; return value
            })
        let task = try store.startDownload(tripID: "42", segment: segment, route: .lan,
            lanEndpoint: Self.lan, bridgeURL: Self.bridge, bridgeToken: "paired")
        while sink?.didWrite != true { await Task.yield() }

        await store.cancelDownload(tripID: "42", segmentID: 1)

        if case .success = await task.result { XCTFail("Cancellation during write must fail") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store.completedURL(tripID: "42", segmentID: 1).path))
        XCTAssertFalse(store.isDownloading(tripID: "42", segmentID: 1))
    }

    func testCapacityIsRecheckedWhileStreaming() async throws {
        let bytes = Data("abcd".utf8), segment = Self.segment(bytes)
        var checks = 0
        var transport = CameraVideoTransport.testing
        transport.openLANSegment = { _, _, _, _, _, _ in
            FakeLANStream(statusCode: 200, contentRange: nil, contentLength: 4,
                          chunks: [Data("ab".utf8), Data("cd".utf8)])
        }
        let store = CameraVideoStore(rootURL: root, transport: transport, availableCapacity: { _ in
            checks += 1; return checks < 3 ? 100 : 0
        })
        await XCTAssertThrowsErrorAsync {
            try await store.downloadSegment(tripID: "42", segment: segment, route: .lan,
                lanEndpoint: Self.lan, bridgeURL: Self.bridge, bridgeToken: "paired")
        }
        XCTAssertGreaterThanOrEqual(checks, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store.completedURL(tripID: "42", segmentID: 1).path))
    }

    func testCanonicalTripPathsCannotEscapeCameraRoot() async throws {
        let store = makeStore(.testing)
        for value in ["", "0", "01", "../42", "42/../../tmp", "18446744073709551616"] {
            XCTAssertThrowsError(try store.completedURL(tripID: value, segmentID: 1), value)
            await XCTAssertThrowsErrorAsync {
                try await store.downloadSegment(tripID: value, segment: Self.segment(Data("a".utf8)), route: .lan,
                    lanEndpoint: Self.lan, bridgeURL: Self.bridge, bridgeToken: "paired")
            }
        }
        let valid = try store.completedURL(tripID: "42", segmentID: 1).standardizedFileURL
        XCTAssertTrue(valid.path.hasPrefix(root.standardizedFileURL.path + "/"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("42").path))
    }

    func testOrderedPlaybackSafeShareAndSeparateDeletionConfirmation() async throws {
        let store = makeStore(.testing)
        let trip = Self.trip(segments: [Self.segment(Data("a".utf8), id: 1), Self.segment(Data("b".utf8), id: 2)])
        for segment in trip.segments.reversed() {
            let url = try store.completedURL(tripID: trip.id, segmentID: segment.id)
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

    func testPerSegmentLocalStateRequiresEveryVerifiedFileForPlaybackAndShare() throws {
        let store = makeStore(.testing)
        let first = Self.segment(Data("a".utf8), id: 1)
        let second = Self.segment(Data("b".utf8), id: 2)
        let trip = Self.trip(segments: [first, second])
        let firstURL = try store.completedURL(tripID: trip.id, segmentID: 1)
        try FileManager.default.createDirectory(at: firstURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: firstURL)

        XCTAssertEqual(store.localState(tripID: trip.id, segment: first), .verified(firstURL))
        XCTAssertEqual(store.localState(tripID: trip.id, segment: second), .missing)
        XCTAssertFalse(store.isTripReadyForPlayback(trip))
        XCTAssertThrowsError(try store.playbackURLs(for: trip))
        XCTAssertThrowsError(try store.shareURLs(for: trip))

        let secondURL = try store.completedURL(tripID: trip.id, segmentID: 2)
        try Data("b".utf8).write(to: secondURL)
        XCTAssertTrue(store.isTripReadyForPlayback(trip))
        XCTAssertEqual(try store.playbackURLs(for: trip), [firstURL, secondURL])
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
        var refetched = false
        transport.updateSettings = { _, _, _, _ in
            .init(revision: 9, settings: conflict, updatedAt: Date(), stale: false, conflict: true)
        }
        transport.fetchSettings = { _, _ in refetched = true; return .init(revision: 9, settings: conflict,
            updatedAt: Date(), stale: false, conflict: false) }
        store.replaceTransportForTesting(transport)
        await store.updateSettings(.init(quality: .high), bridgeURL: Self.bridge, bridgeToken: "paired")
        XCTAssertEqual(store.settingsRevision, 9); XCTAssertEqual(store.settings, conflict)
        XCTAssertEqual(store.settingsState, .conflict)
        XCTAssertTrue(refetched)

        transport.updateSettings = { _, _, _, _ in throw CameraVideoError.offline }
        store.replaceTransportForTesting(transport)
        await store.updateSettings(.init(reserveGB: 20), bridgeURL: Self.bridge, bridgeToken: "paired")
        XCTAssertEqual(store.settings, conflict); XCTAssertEqual(store.settingsState, .failed)
    }

    func testDelayedOlderSettingsResponseCannotOverwriteNewerAuthoritativeEdit() async {
        let initial = CameraSettings.fixture(quality: .standard, reserveGB: 5)
        let older = CameraSettings.fixture(quality: .standard, reserveGB: 1)
        let newer = CameraSettings.fixture(quality: .high, reserveGB: 1)
        var transport = CameraVideoTransport.testing
        transport.fetchSettings = { _, _ in .init(revision: 7, settings: initial, updatedAt: Date(), stale: false, conflict: false) }
        transport.updateSettings = { _, _, _, patch in
            if patch.reserveGB == 1 {
                try await Task.sleep(for: .milliseconds(150))
                return .init(revision: 8, settings: older, updatedAt: Date(), stale: false, conflict: false)
            }
            return .init(revision: 9, settings: newer, updatedAt: Date(), stale: false, conflict: false)
        }
        let store = makeStore(transport)
        await store.loadSettings(bridgeURL: Self.bridge, bridgeToken: "paired")
        let first = Task { await store.updateSettings(.init(reserveGB: 1), bridgeURL: Self.bridge, bridgeToken: "paired") }
        await Task.yield()
        let second = Task { await store.updateSettings(.init(quality: .high), bridgeURL: Self.bridge, bridgeToken: "paired") }
        await second.value; await first.value

        XCTAssertEqual(store.settingsRevision, 9)
        XCTAssertEqual(store.settings, newer)
        XCTAssertEqual(store.settingsState, .loaded(stale: false))
    }

    private func makeStore(_ transport: CameraVideoTransport) -> CameraVideoStore {
        CameraVideoStore(rootURL: root, transport: transport, availableCapacity: { _ in 1_000_000 })
    }

    private func authorizeRemoteDownload(_ store: CameraVideoStore) {
        XCTAssertEqual(store.beginDownloadAction(lanAvailable: false), .askInternet)
        store.confirmDownloadInternet()
    }

    private static let bridge = URL(string: "https://bridge.example")!
    private static let lan = CameraLanEndpoint(host: "192.168.8.20", port: 8080)
    private static func catalogJSON() -> Data {
        let sha = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        return Data(("{\"ok\":true,\"catalogRevision\":1,\"updatedAt\":1000,\"trips\":[{" +
            "\"tripId\":\"42\",\"source\":\"automatic\",\"startMs\":1,\"endMs\":2," +
            "\"byteSize\":3,\"completed\":true,\"segmentCount\":1,\"segments\":[{" +
            "\"segmentId\":1,\"byteSize\":3,\"sha256\":\"\(sha)\"}]}]}").utf8)
    }
    private static func response(_ request: URLRequest, _ status: Int,
                                 headers: [String: String]? = nil) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                        headerFields: headers)!
    }
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
    let authoritativeOffset: UInt64
    private let receiveDelay: Duration?
    var sent: [Data] = []
    var onSend: ((Data) throws -> Void)?
    init(messages: [Data], authoritativeOffset: UInt64 = 0, receiveDelay: Duration? = nil) {
        self.messages = messages
        self.authoritativeOffset = authoritativeOffset
        self.receiveDelay = receiveDelay
    }
    func receive() async throws -> Data {
        if let receiveDelay { try await Task.sleep(for: receiveDelay) }
        guard !messages.isEmpty else { throw CameraVideoError.disconnected }
        return messages.removeFirst()
    }
    func send(_ data: Data) async throws { try onSend?(data); sent.append(data) }
    func close() {}
}

private final class FakeLANStream: CameraLANStream {
    let statusCode: Int
    let contentRange: String?
    let contentLength: UInt64?
    private var chunks: [Data]
    private let delay: Duration?
    private let delayAfterChunks: Duration?
    private(set) var readCount = 0
    private(set) var cancelled = false

    init(statusCode: Int, contentRange: String?, contentLength: UInt64?, chunks: [Data],
         delay: Duration? = nil, delayAfterChunks: Duration? = nil) {
        self.statusCode = statusCode; self.contentRange = contentRange; self.contentLength = contentLength
        self.chunks = chunks; self.delay = delay; self.delayAfterChunks = delayAfterChunks
    }
    func nextChunk() async throws -> Data? {
        readCount += 1
        if let delay { try await Task.sleep(for: delay) }
        if !chunks.isEmpty { return chunks.removeFirst() }
        if let delayAfterChunks { try await Task.sleep(for: delayAfterChunks) }
        return nil
    }
    func cancel() { cancelled = true }
}

private final class EventLog { var values: [String] = [] }

private final class ObservingFileSink: CameraVideoFileSink {
    private let handle: FileHandle
    private let events: EventLog
    init(url: URL, events: EventLog) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        self.events = events
    }
    func write(_ data: Data) async throws { events.values.append("write"); try handle.write(contentsOf: data) }
    func synchronize() throws { events.values.append("synchronize"); try handle.synchronize() }
    func close() throws { try handle.close() }
}

private final class BlockingFileSink: CameraVideoFileSink {
    private let handle: FileHandle
    private(set) var didWrite = false
    init(url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }
    func write(_ data: Data) async throws {
        try handle.write(contentsOf: data)
        didWrite = true
        try await Task.sleep(for: .seconds(10))
    }
    func synchronize() throws { try handle.synchronize() }
    func close() throws { try handle.close() }
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

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
#else
final class CameraVideoStoreTests: XCTestCase {
    func testTask8StoreContractIsImplemented() {
        XCTFail("Task 8 RED: camera recordings store is not implemented")
    }
}
#endif
