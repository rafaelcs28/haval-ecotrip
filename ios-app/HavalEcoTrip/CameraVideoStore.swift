import Combine
import CryptoKit
import Foundation

enum CameraDownloadRoute: String, Codable, Equatable, Sendable { case lan, internet }

struct CameraVideoSegment: Codable, Equatable, Identifiable, Sendable {
    let id: UInt32
    let byteSize: UInt64
    let sha256: Data
}

struct CameraVideoTrip: Equatable, Identifiable, Sendable {
    enum Source: String, Codable, Sendable { case automatic, manual }
    let id: String
    let source: Source
    let start: Date
    let end: Date?
    let byteSize: UInt64
    let completed: Bool
    let segments: [CameraVideoSegment]
}

struct CameraVideoCatalog: Equatable, Sendable {
    let revision: UInt64
    let updatedAt: Date
    let stale: Bool
    let route: CameraDownloadRoute
    let trips: [CameraVideoTrip]

    static func decode(_ data: Data, route: CameraDownloadRoute) throws -> Self {
        guard !data.isEmpty, data.count <= 8 * 1_024 * 1_024 else { throw CameraVideoError.invalidResponse }
        let value: CatalogResponse
        do { value = try JSONDecoder().decode(CatalogResponse.self, from: data) }
        catch { throw CameraVideoError.invalidResponse }
        let trips = try value.trips.map { trip -> CameraVideoTrip in
            guard canonicalTripID(trip.tripId), trip.startMs > 0, let endMs = trip.endMs,
                  endMs >= trip.startMs, trip.byteSize > 0, trip.completed,
                  trip.segmentCount == trip.segments.count, (1...256).contains(trip.segments.count) else {
                throw CameraVideoError.invalidResponse
            }
            var aggregate: UInt64 = 0
            let segments = try trip.segments.enumerated().map { index, segment -> CameraVideoSegment in
                guard segment.segmentId == UInt64(index + 1), segment.segmentId <= UInt64(UInt32.max),
                      segment.byteSize > 0, segment.sha256.count == 64,
                      segment.sha256.allSatisfy({ $0.isNumber || ("a"..."f").contains(String($0)) }),
                      let digest = Data(cameraHex: segment.sha256), digest.count == 32 else {
                    throw CameraVideoError.invalidResponse
                }
                let (sum, overflow) = aggregate.addingReportingOverflow(segment.byteSize)
                guard !overflow else { throw CameraVideoError.invalidResponse }
                aggregate = sum
                return CameraVideoSegment(id: UInt32(segment.segmentId), byteSize: segment.byteSize, sha256: digest)
            }
            guard aggregate == trip.byteSize else { throw CameraVideoError.invalidResponse }
            return CameraVideoTrip(id: trip.tripId, source: trip.source,
                start: Date(timeIntervalSince1970: Double(trip.startMs) / 1_000),
                end: Date(timeIntervalSince1970: Double(endMs) / 1_000), byteSize: trip.byteSize,
                completed: true, segments: segments)
        }
        return Self(revision: value.catalogRevision ?? 0,
                    updatedAt: Date(timeIntervalSince1970: Double(value.updatedAt ?? 0) / 1_000),
                    stale: value.stale ?? false, route: route, trips: trips)
    }

    private static func canonicalTripID(_ value: String) -> Bool {
        guard value.range(of: "^[1-9][0-9]{0,19}$", options: .regularExpression) != nil,
              let number = UInt64(value), number > 0 else { return false }
        return String(number) == value
    }
}

private struct CatalogResponse: Decodable {
    let catalogRevision: UInt64?
    let updatedAt: Int64?
    let stale: Bool?
    let trips: [Trip]

    struct Trip: Decodable {
        let tripId: String
        let source: CameraVideoTrip.Source
        let startMs: Int64
        let endMs: Int64?
        let byteSize: UInt64
        let completed: Bool
        let segmentCount: Int
        let segments: [Segment]
    }

    struct Segment: Decodable {
        let segmentId: UInt64
        let byteSize: UInt64
        let sha256: String

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicCodingKey.self)
            let expected = Set(["segmentId", "byteSize", "sha256"])
            guard Set(container.allKeys.map(\.stringValue)) == expected else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                        debugDescription: "Non-canonical segment metadata"))
            }
            segmentId = try container.decode(UInt64.self, forKey: .init("segmentId"))
            byteSize = try container.decode(UInt64.self, forKey: .init("byteSize"))
            sha256 = try container.decode(String.self, forKey: .init("sha256"))
        }
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}

protocol CameraLANStream: AnyObject {
    var statusCode: Int { get }
    var contentRange: String? { get }
    var contentLength: UInt64? { get }
    func nextChunk() async throws -> Data?
    func cancel()
}

protocol CameraVideoFileSink: AnyObject {
    func write(_ data: Data) async throws
    func synchronize() throws
    func close() throws
}

struct CameraVideoHTTPClient {
    var data: (URLRequest) async throws -> (Data, HTTPURLResponse)
    var download: (URLRequest) async throws -> (URL, HTTPURLResponse)
    var webSocket: (URLRequest, UInt64, String) throws -> CameraTransferSocket

    static var live: Self {
        let session = CameraLanNoRedirectSession.shared
        return Self(data: { request in
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw CameraVideoError.invalidResponse }
            return (data, http)
        }, download: { request in
            let (url, response) = try await session.download(for: request)
            guard let http = response as? HTTPURLResponse else { throw CameraVideoError.invalidResponse }
            return (url, http)
        }, webSocket: { request, offset, sessionID in
            URLSessionCameraTransferSocket(request: request, session: session,
                                           authoritativeOffset: offset, sessionID: sessionID)
        })
    }
}

protocol CameraTransferSocket: AnyObject {
    var authoritativeOffset: UInt64 { get }
    func receive() async throws -> Data
    func send(_ data: Data) async throws
    func close()
}

extension CameraTransferSocket { var authoritativeOffset: UInt64 { 0 } }

enum CameraOverlayPosition: String, Codable, CaseIterable, Sendable {
    case topLeft = "top_left", topRight = "top_right", bottomLeft = "bottom_left", bottomRight = "bottom_right"
}

struct CameraSettings: Codable, Equatable, Sendable {
    let automaticRecording: Bool
    let recordParkedLive: Bool
    let remoteLive: Bool
    let remoteDownloads: Bool
    let automaticDeletion: Bool
    let overlayMaster: Bool
    let overlayDateTime: Bool
    let overlaySpeed: Bool
    let overlayAcceleration: Bool
    let overlayDriveState: Bool
    let overlayDecelerationRegen: Bool
    let quality: CameraVideoQuality
    let reserveGB: Int
    let overlayPosition: CameraOverlayPosition

    enum CodingKeys: String, CodingKey {
        case automaticRecording, recordParkedLive, remoteLive, remoteDownloads, automaticDeletion
        case overlayMaster, overlayDateTime, overlaySpeed, overlayAcceleration, overlayDriveState
        case overlayDecelerationRegen, quality, overlayPosition
        case reserveGB = "reserveGb"
    }
}

extension CameraVideoQuality: Codable {
    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        guard let value = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "Invalid quality")
        }
        self = value
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer(); try container.encode(rawValue)
    }
}

struct CameraSettingsPatch: Codable, Equatable, Sendable {
    var automaticRecording: Bool?
    var recordParkedLive: Bool?
    var remoteLive: Bool?
    var remoteDownloads: Bool?
    var automaticDeletion: Bool?
    var overlayMaster: Bool?
    var overlayDateTime: Bool?
    var overlaySpeed: Bool?
    var overlayAcceleration: Bool?
    var overlayDriveState: Bool?
    var overlayDecelerationRegen: Bool?
    var quality: CameraVideoQuality?
    var reserveGB: Int?
    var overlayPosition: CameraOverlayPosition?

    init(automaticRecording: Bool? = nil, recordParkedLive: Bool? = nil, remoteLive: Bool? = nil,
         remoteDownloads: Bool? = nil, automaticDeletion: Bool? = nil, overlayMaster: Bool? = nil,
         overlayDateTime: Bool? = nil, overlaySpeed: Bool? = nil, overlayAcceleration: Bool? = nil,
         overlayDriveState: Bool? = nil, overlayDecelerationRegen: Bool? = nil,
         quality: CameraVideoQuality? = nil, reserveGB: Int? = nil,
         overlayPosition: CameraOverlayPosition? = nil) {
        self.automaticRecording = automaticRecording; self.recordParkedLive = recordParkedLive
        self.remoteLive = remoteLive; self.remoteDownloads = remoteDownloads
        self.automaticDeletion = automaticDeletion; self.overlayMaster = overlayMaster
        self.overlayDateTime = overlayDateTime; self.overlaySpeed = overlaySpeed
        self.overlayAcceleration = overlayAcceleration; self.overlayDriveState = overlayDriveState
        self.overlayDecelerationRegen = overlayDecelerationRegen; self.quality = quality
        self.reserveGB = reserveGB; self.overlayPosition = overlayPosition
    }

    enum CodingKeys: String, CodingKey {
        case automaticRecording, recordParkedLive, remoteLive, remoteDownloads, automaticDeletion
        case overlayMaster, overlayDateTime, overlaySpeed, overlayAcceleration, overlayDriveState
        case overlayDecelerationRegen, quality, overlayPosition
        case reserveGB = "reserveGb"
    }

    func applying(to value: CameraSettings) -> CameraSettings {
        CameraSettings(
            automaticRecording: automaticRecording ?? value.automaticRecording,
            recordParkedLive: recordParkedLive ?? value.recordParkedLive,
            remoteLive: remoteLive ?? value.remoteLive,
            remoteDownloads: remoteDownloads ?? value.remoteDownloads,
            automaticDeletion: automaticDeletion ?? value.automaticDeletion,
            overlayMaster: overlayMaster ?? value.overlayMaster,
            overlayDateTime: overlayDateTime ?? value.overlayDateTime,
            overlaySpeed: overlaySpeed ?? value.overlaySpeed,
            overlayAcceleration: overlayAcceleration ?? value.overlayAcceleration,
            overlayDriveState: overlayDriveState ?? value.overlayDriveState,
            overlayDecelerationRegen: overlayDecelerationRegen ?? value.overlayDecelerationRegen,
            quality: quality ?? value.quality,
            reserveGB: reserveGB ?? value.reserveGB,
            overlayPosition: overlayPosition ?? value.overlayPosition)
    }
}

struct CameraSettingsSnapshot: Equatable, Sendable {
    let revision: UInt64
    let settings: CameraSettings
    let updatedAt: Date
    let stale: Bool
    let conflict: Bool
}

enum CameraVideoError: Error, Equatable {
    case offline, disconnected, invalidResponse, invalidSelection, invalidOffset
    case digestMismatch, insufficientStorage, duplicateSegment, deletionNotConfirmed, unsupportedCatalog
    case internetConfirmationRequired, duplicateDownload, incompleteFiles
}

struct CameraVideoTransport {
    var fetchLANCatalog: (CameraLanEndpoint, String) async throws -> CameraVideoCatalog
    var fetchRemoteCatalog: (URL, String) async throws -> CameraVideoCatalog
    var openLANSegment: (String, CameraVideoSegment, UInt32, UInt64, CameraLanEndpoint, String) async throws -> CameraLANStream
    var closeLANCatalogSession: (CameraLanEndpoint) async -> Void
    var openRemoteTransfer: (String, CameraVideoSegment, UInt64, URL, String) async throws -> CameraTransferSocket
    var releaseRemoteTransfer: (String, UInt32, URL, String, Bool) async -> Void
    var fetchSettings: (URL, String) async throws -> CameraSettingsSnapshot
    var updateSettings: (URL, String, UInt64, CameraSettingsPatch) async throws -> CameraSettingsSnapshot
    var deleteRecordings: (URL, String, [String], String) async throws -> Void

    static var testing: Self {
        Self(
            fetchLANCatalog: { _, _ in throw CameraVideoError.offline },
            fetchRemoteCatalog: { _, _ in throw CameraVideoError.offline },
            openLANSegment: { _, _, _, _, _, _ in throw CameraVideoError.offline },
            closeLANCatalogSession: { _ in },
            openRemoteTransfer: { _, _, _, _, _ in throw CameraVideoError.offline },
            releaseRemoteTransfer: { _, _, _, _, _ in },
            fetchSettings: { _, _ in throw CameraVideoError.offline },
            updateSettings: { _, _, _, _ in throw CameraVideoError.offline },
            deleteRecordings: { _, _, _, _ in throw CameraVideoError.offline })
    }

    @MainActor static var live: Self {
        let network = CameraVideoNetwork()
        return Self(
            fetchLANCatalog: network.fetchLANCatalog,
            fetchRemoteCatalog: network.fetchRemoteCatalog,
            openLANSegment: network.openLANSegment,
            closeLANCatalogSession: network.closeLANCatalogSession,
            openRemoteTransfer: network.openRemoteTransfer,
            releaseRemoteTransfer: network.releaseRemoteTransfer,
            fetchSettings: network.fetchSettings,
            updateSettings: network.updateSettings,
            deleteRecordings: network.deleteRecordings)
    }
}

@MainActor
final class CameraVideoStore: ObservableObject {
    enum CatalogState: Equatable {
        case idle, loading, askingInternet, loaded(route: CameraDownloadRoute, stale: Bool), offline(stale: Bool)
    }
    enum DownloadState: Equatable {
        case idle, askingInternet, downloading(route: CameraDownloadRoute, progress: Double), complete(URL), cancelled, failed
    }
    enum SettingsState: Equatable { case idle, loading, loaded(stale: Bool), saving, conflict, failed }
    enum SegmentLocalState: Equatable { case missing, partial(route: CameraDownloadRoute, bytes: UInt64), verified(URL), invalid }

    @Published private(set) var trips: [CameraVideoTrip] = []
    @Published private(set) var catalogState: CatalogState = .idle
    @Published private(set) var downloadState: DownloadState = .idle
    @Published private(set) var settings: CameraSettings?
    @Published private(set) var settingsRevision: UInt64?
    @Published private(set) var settingsState: SettingsState = .idle
    @Published private(set) var activeDownloadKeys: Set<String> = []
    @Published private(set) var operationError: String?

    private let rootURL: URL
    private var transport: CameraVideoTransport
    private let availableCapacity: (URL) -> Int64?
    private let fileSinkFactory: (URL) throws -> CameraVideoFileSink
    private let catalogPolicy = CameraRoutePolicy()
    private let downloadPolicy = CameraRoutePolicy()
    private var catalogContext: (CameraLanEndpoint?, URL, String)?
    private var activeDownloads: [String: Task<URL, Error>] = [:]
    private var settingsGeneration: UInt64 = 0

    init(rootURL: URL? = nil, transport: CameraVideoTransport? = nil,
         availableCapacity: @escaping (URL) -> Int64? = CameraVideoStore.systemCapacity,
         fileSinkFactory: @escaping (URL) throws -> CameraVideoFileSink = { try FileHandleCameraVideoSink(url: $0) }) {
        self.rootURL = rootURL ?? Self.applicationSupportRoot()
        self.transport = transport ?? .live
        self.availableCapacity = availableCapacity
        self.fileSinkFactory = fileSinkFactory
    }

    func loadCatalog(lanEndpoint: CameraLanEndpoint?, bridgeURL: URL, bridgeToken: String) async {
        catalogContext = (lanEndpoint, bridgeURL, bridgeToken)
        catalogState = .loading
        switch catalogPolicy.beginAction(lanAvailable: lanEndpoint != nil) {
        case .useLAN:
            guard let lanEndpoint else { return }
            do { applyCatalog(try await transport.fetchLANCatalog(lanEndpoint, bridgeToken), route: .lan) }
            catch {
                await transport.closeLANCatalogSession(lanEndpoint)
                catalogState = trips.isEmpty ? .askingInternet : .offline(stale: true)
            }
        case .askInternet: catalogState = .askingInternet
        case .offline: catalogState = .offline(stale: !trips.isEmpty)
        }
    }

    func reloadCatalog() async {
        guard let context = catalogContext else { return }
        if let endpoint = context.0 {
            catalogState = .loading
            do { applyCatalog(try await transport.fetchLANCatalog(endpoint, context.2), route: .lan) }
            catch {
                await transport.closeLANCatalogSession(endpoint)
                catalogState = .offline(stale: !trips.isEmpty)
            }
        } else if catalogPolicy.internetAllowed {
            await fetchRemoteCatalog(context)
        } else { catalogState = .askingInternet }
    }

    func confirmCatalogInternet() async {
        guard catalogState == .askingInternet, let context = catalogContext else { return }
        catalogPolicy.confirmInternet(); catalogState = .loading
        await fetchRemoteCatalog(context)
    }

    func closeCatalogAction() async {
        await closeDownloadAction()
        if let endpoint = catalogContext?.0 { await transport.closeLANCatalogSession(endpoint) }
        catalogPolicy.stop(); catalogContext = nil; catalogState = .idle
    }

    private func fetchRemoteCatalog(_ context: (CameraLanEndpoint?, URL, String)) async {
        do { applyCatalog(try await transport.fetchRemoteCatalog(context.1, context.2), route: .internet) }
        catch { catalogState = .offline(stale: !trips.isEmpty) }
    }

    private func applyCatalog(_ catalog: CameraVideoCatalog, route: CameraDownloadRoute) {
        trips = catalog.trips.filter { $0.completed && $0.end != nil }.sorted { $0.start > $1.start }
        catalogState = .loaded(route: route, stale: catalog.stale)
    }

    @discardableResult
    func beginDownloadAction(lanAvailable: Bool) -> CameraRoutePolicy.Decision {
        let decision = downloadPolicy.beginAction(lanAvailable: lanAvailable)
        downloadState = decision == .askInternet ? .askingInternet : .idle
        return decision
    }

    func confirmDownloadInternet() {
        guard downloadState == .askingInternet else { return }
        downloadPolicy.confirmInternet()
        downloadState = .idle
    }

    func closeDownloadAction() async {
        let tasks = Array(activeDownloads.values)
        tasks.forEach { $0.cancel() }
        for task in tasks { _ = await task.result }
        downloadPolicy.stop()
        if downloadState == .askingInternet { downloadState = .idle }
    }

    func startDownload(tripID: String, segment: CameraVideoSegment, route: CameraDownloadRoute,
                       lanEndpoint: CameraLanEndpoint?, bridgeURL: URL, bridgeToken: String) throws -> Task<URL, Error> {
        let key = try downloadKey(tripID: tripID, segmentID: segment.id)
        guard activeDownloads[key] == nil else { throw CameraVideoError.duplicateDownload }
        let task = Task { [weak self] () throws -> URL in
            guard let self else { throw CancellationError() }
            do {
                let result = try await self.performDownload(tripID: tripID, segment: segment, route: route,
                    lanEndpoint: lanEndpoint, bridgeURL: bridgeURL, bridgeToken: bridgeToken)
                self.finishDownload(key, stopPolicy: true)
                return result
            } catch {
                self.finishDownload(key, stopPolicy: (error as? CameraVideoError) != .internetConfirmationRequired)
                throw error
            }
        }
        activeDownloads[key] = task
        activeDownloadKeys.insert(key)
        return task
    }

    func downloadSegment(tripID: String, segment: CameraVideoSegment, route: CameraDownloadRoute,
                         lanEndpoint: CameraLanEndpoint?, bridgeURL: URL, bridgeToken: String) async throws -> URL {
        try await startDownload(tripID: tripID, segment: segment, route: route, lanEndpoint: lanEndpoint,
                                bridgeURL: bridgeURL, bridgeToken: bridgeToken).value
    }

    func cancelDownload(tripID: String, segmentID: UInt32) async {
        guard let key = try? downloadKey(tripID: tripID, segmentID: segmentID),
              let task = activeDownloads[key] else { return }
        task.cancel()
        _ = await task.result
    }

    func isDownloading(tripID: String, segmentID: UInt32) -> Bool {
        guard let key = try? downloadKey(tripID: tripID, segmentID: segmentID) else { return false }
        return activeDownloadKeys.contains(key)
    }

    func hasActiveDownload(for trip: CameraVideoTrip) -> Bool {
        trip.segments.contains { isDownloading(tripID: trip.id, segmentID: $0.id) }
    }

    private func finishDownload(_ key: String, stopPolicy: Bool) {
        activeDownloads.removeValue(forKey: key)
        activeDownloadKeys.remove(key)
        if stopPolicy { downloadPolicy.stop() }
    }

    private func performDownload(tripID: String, segment: CameraVideoSegment, route: CameraDownloadRoute,
                                 lanEndpoint: CameraLanEndpoint?, bridgeURL: URL,
                                 bridgeToken: String) async throws -> URL {
        if route == .internet, !downloadPolicy.internetAllowed {
            downloadState = .askingInternet
            throw CameraVideoError.internetConfirmationRequired
        }
        guard Self.isCanonicalTripID(tripID), segment.id > 0, segment.byteSize > 0, segment.sha256.count == 32 else {
            throw CameraVideoError.invalidSelection
        }
        let final = try completedURL(tripID: tripID, segmentID: segment.id)
        if FileManager.default.fileExists(atPath: final.path) {
            guard try verify(final, segment: segment) else { throw CameraVideoError.duplicateSegment }
            return final
        }
        let partial = try partialURL(tripID: tripID, segmentID: segment.id, route: route)
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        let offset = try fileSize(partial)
        guard offset <= segment.byteSize else { throw CameraVideoError.invalidOffset }
        let remaining = segment.byteSize - offset
        guard let capacity = availableCapacity(rootURL), capacity >= 0, UInt64(capacity) >= remaining else {
            throw CameraVideoError.insufficientStorage
        }
        downloadState = .downloading(route: route, progress: segment.byteSize == 0 ? 0 : Double(offset) / Double(segment.byteSize))
        do {
            switch route {
            case .lan:
                guard let lanEndpoint else { throw CameraVideoError.offline }
                do {
                    try await downloadLAN(tripID: tripID, segment: segment, offset: offset, partial: partial,
                                          endpoint: lanEndpoint, bridgeToken: bridgeToken)
                } catch {
                    await transport.closeLANCatalogSession(lanEndpoint)
                    throw error
                }
            case .internet:
                do {
                    try await downloadRemote(tripID: tripID, segment: segment, offset: offset, partial: partial,
                                             bridgeURL: bridgeURL, bridgeToken: bridgeToken)
                    await transport.releaseRemoteTransfer(tripID, segment.id, bridgeURL, bridgeToken, false)
                } catch {
                    await transport.releaseRemoteTransfer(tripID, segment.id, bridgeURL, bridgeToken, true)
                    throw error
                }
            }
            try promote(partial: partial, final: final, segment: segment)
            downloadState = .complete(final)
            return final
        } catch is CancellationError {
            downloadState = .cancelled; throw CancellationError()
        } catch {
            downloadState = .failed; throw error
        }
    }

    private func downloadLAN(tripID: String, segment: CameraVideoSegment, offset: UInt64, partial: URL,
                             endpoint: CameraLanEndpoint, bridgeToken: String) async throws {
        let response = try await transport.openLANSegment(tripID, segment, segment.id, offset, endpoint, bridgeToken)
        defer { response.cancel() }
        let expectedRange = "bytes \(offset)-\(segment.byteSize - 1)/\(segment.byteSize)"
        let expectedLength = segment.byteSize - offset
        if offset == 0 {
            guard response.statusCode == 200, response.contentRange == nil,
                  response.contentLength == expectedLength else {
                throw CameraVideoError.invalidOffset
            }
        } else {
            guard response.statusCode == 206,
                  response.contentRange == expectedRange, response.contentLength == expectedLength else {
                throw CameraVideoError.invalidOffset
            }
        }
        let sink = try fileSinkFactory(partial)
        defer { try? sink.close() }
        var written = offset
        while let chunk = try await response.nextChunk() {
            try Task.checkCancellation()
            guard !chunk.isEmpty, written <= segment.byteSize,
                  UInt64(chunk.count) <= segment.byteSize - written else { throw CameraVideoError.invalidOffset }
            let remaining = segment.byteSize - written
            guard let capacity = availableCapacity(rootURL), capacity >= 0,
                  UInt64(capacity) >= remaining else { throw CameraVideoError.insufficientStorage }
            try await sink.write(chunk)
            try Task.checkCancellation()
            try sink.synchronize()
            written += UInt64(chunk.count)
            downloadState = .downloading(route: .lan, progress: Double(written) / Double(segment.byteSize))
        }
        guard written == segment.byteSize else { throw CameraVideoError.invalidOffset }
    }

    private func downloadRemote(tripID: String, segment: CameraVideoSegment, offset: UInt64, partial: URL,
                                bridgeURL: URL, bridgeToken: String) async throws {
        let socket = try await transport.openRemoteTransfer(tripID, segment, offset, bridgeURL, bridgeToken)
        defer { socket.close() }
        guard socket.authoritativeOffset == offset else { throw CameraVideoError.invalidOffset }
        let sink = try fileSinkFactory(partial)
        defer { try? sink.close() }
        var expected = offset
        while true {
            try Task.checkCancellation()
            let message = try CameraTransferProtocol.parse(try await socket.receive())
            guard message.ordinal == segment.id else { throw CameraVideoError.invalidSelection }
            switch message.type {
            case .data:
                guard message.offset == expected, expected <= segment.byteSize,
                      UInt64(message.payload.count) <= segment.byteSize - expected else { throw CameraVideoError.invalidOffset }
                try await sink.write(message.payload)
                try Task.checkCancellation()
                try sink.synchronize()
                expected += UInt64(message.payload.count)
                try await socket.send(CameraTransferProtocol.ack(ordinal: segment.id, nextOffset: expected))
                downloadState = .downloading(route: .internet, progress: Double(expected) / Double(segment.byteSize))
            case .eof:
                guard message.offset == segment.byteSize, expected == segment.byteSize,
                      message.sha256 == segment.sha256, try verify(partial, segment: segment) else {
                    throw CameraVideoError.digestMismatch
                }
                try sink.synchronize()
                try await socket.send(CameraTransferProtocol.ack(ordinal: segment.id, nextOffset: expected))
                return
            case .error: throw CameraVideoError.offline
            case .ack: throw CameraVideoError.invalidResponse
            }
        }
    }

    func completedURL(tripID: String, segmentID: UInt32) throws -> URL {
        guard segmentID > 0 else { throw CameraVideoError.invalidSelection }
        return try safeChild(try tripDirectory(tripID), String(format: "%06u.mp4", segmentID))
    }

    func partialURL(tripID: String, segmentID: UInt32, route: CameraDownloadRoute) throws -> URL {
        guard segmentID > 0 else { throw CameraVideoError.invalidSelection }
        return try safeChild(try tripDirectory(tripID), String(format: "%06u.%@.partial", segmentID, route.rawValue))
    }

    func localState(tripID: String, segment: CameraVideoSegment) -> SegmentLocalState {
        guard let final = try? completedURL(tripID: tripID, segmentID: segment.id) else { return .invalid }
        if FileManager.default.fileExists(atPath: final.path) {
            return ((try? verify(final, segment: segment)) == true) ? .verified(final) : .invalid
        }
        for route in [CameraDownloadRoute.lan, .internet] {
            if let partial = try? partialURL(tripID: tripID, segmentID: segment.id, route: route),
               FileManager.default.fileExists(atPath: partial.path), let bytes = try? fileSize(partial) {
                return .partial(route: route, bytes: bytes)
            }
        }
        return .missing
    }

    func isTripReadyForPlayback(_ trip: CameraVideoTrip) -> Bool {
        !trip.segments.isEmpty && trip.segments.allSatisfy {
            if case .verified = localState(tripID: trip.id, segment: $0) { return true }
            return false
        }
    }

    func playbackURLs(for trip: CameraVideoTrip) throws -> [URL] {
        try trip.segments.sorted { $0.id < $1.id }.map { segment in
            let url = try completedURL(tripID: trip.id, segmentID: segment.id)
            guard try verify(url, segment: segment) else {
                throw CameraVideoError.incompleteFiles
            }
            return url
        }
    }

    func shareURLs(for trip: CameraVideoTrip) throws -> [URL] { try playbackURLs(for: trip) }

    func deleteRecordings(_ tripIDs: [String], confirmed: Bool, bridgeURL: URL, bridgeToken: String) async throws {
        guard confirmed else { throw CameraVideoError.deletionNotConfirmed }
        guard !tripIDs.isEmpty, tripIDs.count <= 256, Set(tripIDs).count == tripIDs.count,
              tripIDs.allSatisfy(Self.isCanonicalTripID),
              !activeDownloadKeys.contains(where: { key in tripIDs.contains { key.hasPrefix("\($0)/") } }) else {
            throw CameraVideoError.invalidSelection
        }
        try await transport.deleteRecordings(bridgeURL, bridgeToken, tripIDs, "DELETE_COMPLETED")
    }

    func loadSettings(bridgeURL: URL, bridgeToken: String) async {
        settingsGeneration &+= 1
        let generation = settingsGeneration
        settingsState = .loading
        do {
            let snapshot = try await transport.fetchSettings(bridgeURL, bridgeToken)
            guard generation == settingsGeneration else { return }
            settings = snapshot.settings; settingsRevision = snapshot.revision
            settingsState = .loaded(stale: snapshot.stale)
        } catch { if generation == settingsGeneration { settingsState = .failed } }
    }

    func updateSettings(_ patch: CameraSettingsPatch, bridgeURL: URL, bridgeToken: String) async {
        guard let current = settings, let revision = settingsRevision else { settingsState = .failed; return }
        settingsGeneration &+= 1
        let generation = settingsGeneration
        let previous = current
        settings = patch.applying(to: current); settingsState = .saving
        do {
            let snapshot = try await transport.updateSettings(bridgeURL, bridgeToken, revision, patch)
            guard generation == settingsGeneration else { return }
            settings = snapshot.settings; settingsRevision = snapshot.revision
            if snapshot.conflict {
                let authoritative = try await transport.fetchSettings(bridgeURL, bridgeToken)
                guard generation == settingsGeneration else { return }
                settings = authoritative.settings; settingsRevision = authoritative.revision
                settingsState = .conflict
            } else {
                settingsState = .loaded(stale: snapshot.stale)
            }
        } catch {
            if generation == settingsGeneration { settings = previous; settingsState = .failed }
        }
    }

    func replaceTransportForTesting(_ value: CameraVideoTransport) { transport = value }

    private func tripDirectory(_ tripID: String) throws -> URL {
        guard Self.isCanonicalTripID(tripID) else { throw CameraVideoError.invalidSelection }
        return try safeChild(rootURL, tripID, isDirectory: true)
    }

    private func downloadKey(tripID: String, segmentID: UInt32) throws -> String {
        guard Self.isCanonicalTripID(tripID), segmentID > 0 else { throw CameraVideoError.invalidSelection }
        return "\(tripID)/\(segmentID)"
    }

    private func safeChild(_ parent: URL, _ component: String, isDirectory: Bool = false) throws -> URL {
        let root = rootURL.standardizedFileURL
        let child = parent.appendingPathComponent(component, isDirectory: isDirectory).standardizedFileURL
        guard child.path.hasPrefix(root.path + "/") else { throw CameraVideoError.invalidSelection }
        return child
    }

    private static func isCanonicalTripID(_ value: String) -> Bool {
        guard value.range(of: "^[1-9][0-9]{0,19}$", options: .regularExpression) != nil,
              let parsed = UInt64(value), parsed > 0 else { return false }
        return String(parsed) == value
    }

    private func promote(partial: URL, final: URL, segment: CameraVideoSegment) throws {
        guard try verify(partial, segment: segment), !FileManager.default.fileExists(atPath: final.path) else {
            throw CameraVideoError.digestMismatch
        }
        try FileManager.default.moveItem(at: partial, to: final)
    }

    private func verify(_ url: URL, segment: CameraVideoSegment) throws -> Bool {
        guard try fileSize(url) == segment.byteSize else { return false }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while true {
            let data = try handle.read(upToCount: 64 * 1_024) ?? Data()
            if data.isEmpty { break }
            hash.update(data: data)
        }
        return Data(hash.finalize()) == segment.sha256
    }

    private func fileSize(_ url: URL) throws -> UInt64 {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let value = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        return value?.uint64Value ?? 0
    }

    private static func applicationSupportRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("HavalCamera", isDirectory: true)
    }

    nonisolated static func systemCapacity(_ url: URL) -> Int64? {
        try? url.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }
}

private final class FileHandleCameraVideoSink: CameraVideoFileSink {
    private let handle: FileHandle
    init(url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw CameraVideoError.invalidResponse
            }
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }
    func write(_ data: Data) async throws { try handle.write(contentsOf: data) }
    func synchronize() throws { try handle.synchronize() }
    func close() throws { try handle.close() }
}

private final class TemporaryFileLANStream: CameraLANStream {
    let statusCode: Int
    let contentRange: String?
    let contentLength: UInt64?
    private let url: URL
    private var handle: FileHandle?
    private var cancelled = false

    init(downloadURL: URL, statusCode: Int, contentRange: String?, contentLength: UInt64?) throws {
        self.statusCode = statusCode
        self.contentRange = contentRange
        self.contentLength = contentLength
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("haval-camera-lan-\(UUID().uuidString).download")
        try FileManager.default.moveItem(at: downloadURL, to: url)
        handle = try FileHandle(forReadingFrom: url)
    }

    func nextChunk() async throws -> Data? {
        try Task.checkCancellation()
        guard !cancelled, let handle else { throw CancellationError() }
        let data = try handle.read(upToCount: 64 * 1_024) ?? Data()
        return data.isEmpty ? nil : data
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: url)
    }

    deinit { cancel() }
}

@MainActor
final class CameraVideoNetwork {
    private struct LANCredential {
        let id: String
        let downloadToken: String
        let controlToken: String
        let expiresAt: Int64
    }

    private let http: CameraVideoHTTPClient
    private let now: () -> Int64
    private var lanSessions: [String: LANCredential] = [:]
    private var transferSessions: [String: String] = [:]

    init(http: CameraVideoHTTPClient = .live,
         now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }) {
        self.http = http
        self.now = now
    }

    func fetchLANCatalog(endpoint: CameraLanEndpoint, bridgeToken: String) async throws -> CameraVideoCatalog {
        try await requireDownloadCapability(endpoint)
        let credential = try await lanCredential(endpoint: endpoint, bridgeToken: bridgeToken)
        do {
            var request = URLRequest(url: try lanURL(endpoint, "/api/video/lan/catalog?session=\(credential.id)"))
            request.setValue("Bearer \(credential.downloadToken)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await http.data(request)
            guard response.statusCode == 200 else { throw CameraVideoError.offline }
            return try CameraVideoCatalog.decode(data, route: .lan)
        } catch {
            await closeLANCatalogSession(endpoint: endpoint)
            throw error
        }
    }

    func fetchRemoteCatalog(base: URL, token: String) async throws -> CameraVideoCatalog {
        let (data, response) = try await http.data(try ownerRequest(base, "/api/video/catalog", token, "GET"))
        guard response.statusCode == 200 else { throw CameraVideoError.offline }
        return try CameraVideoCatalog.decode(data, route: .internet)
    }

    func openLANSegment(tripID: String, segment: CameraVideoSegment, ordinal: UInt32, offset: UInt64,
                        endpoint: CameraLanEndpoint, bridgeToken: String) async throws -> CameraLANStream {
        guard Self.canonicalTripID(tripID), ordinal > 0, ordinal == segment.id else {
            throw CameraVideoError.invalidSelection
        }
        try await requireDownloadCapability(endpoint)
        let credential = try await lanCredential(endpoint: endpoint, bridgeToken: bridgeToken)
        let path = "/api/video/lan/trips/\(tripID)/segments/\(ordinal)?session=\(credential.id)"
        var request = URLRequest(url: try lanURL(endpoint, path))
        request.setValue("Bearer \(credential.downloadToken)", forHTTPHeaderField: "Authorization")
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        do {
            let (url, response) = try await http.download(request)
            let length = response.value(forHTTPHeaderField: "Content-Length").flatMap(UInt64.init)
            return try TemporaryFileLANStream(downloadURL: url, statusCode: response.statusCode,
                contentRange: response.value(forHTTPHeaderField: "Content-Range"), contentLength: length)
        } catch {
            await closeLANCatalogSession(endpoint: endpoint)
            throw error
        }
    }

    func closeLANCatalogSession(endpoint: CameraLanEndpoint) async {
        let key = endpointKey(endpoint)
        guard let credential = lanSessions.removeValue(forKey: key) else { return }
        guard let url = try? lanURL(endpoint, "/api/video/lan/session/\(credential.id)") else { return }
        var request = URLRequest(url: url); request.httpMethod = "DELETE"
        request.setValue("Bearer \(credential.controlToken)", forHTTPHeaderField: "Authorization")
        _ = try? await http.data(request)
    }

    func openRemoteTransfer(tripID: String, segment: CameraVideoSegment, offset: UInt64,
                            base: URL, token: String) async throws -> CameraTransferSocket {
        let key = "\(tripID)/\(segment.id)"
        var body: [String: Any] = ["tripId": tripID, "segmentIds": [String(segment.id)]]
        if let existing = transferSessions[key] { body["sessionId"] = existing }
        var request = try ownerRequest(base, "/api/video/transfer/session", token, "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await http.data(request)
        guard response.statusCode == 201 else { throw CameraVideoError.offline }
        let value = try JSONDecoder().decode(TransferResponse.self, from: data)
        guard let url = URL(string: value.viewerUrl), url.scheme == "wss", url.user == nil, url.fragment == nil,
              url.path == "/ws/video/transfer/viewer", url.query == "session=\(value.sessionId)",
              Self.sessionID(value.sessionId), value.viewerToken.count >= 16,
              value.offsets[String(segment.id)].flatMap(UInt64.init) == offset else { throw CameraVideoError.invalidOffset }
        transferSessions[key] = value.sessionId
        var socketRequest = URLRequest(url: url)
        socketRequest.setValue("Bearer \(value.viewerToken)", forHTTPHeaderField: "Authorization")
        return try http.webSocket(socketRequest, offset, value.sessionId)
    }

    func releaseRemoteTransfer(tripID: String, segmentID: UInt32, base: URL,
                               token: String, terminate: Bool) async {
        let key = "\(tripID)/\(segmentID)"
        guard let sessionID = transferSessions.removeValue(forKey: key), terminate,
              Self.sessionID(sessionID),
              let request = try? ownerRequest(base, "/api/video/transfer/session/\(sessionID)", token, "DELETE") else { return }
        _ = try? await http.data(request)
    }

    func fetchSettings(base: URL, token: String) async throws -> CameraSettingsSnapshot {
        let (data, response) = try await http.data(try ownerRequest(base, "/api/video/settings", token, "GET"))
        guard response.statusCode == 200 else { throw CameraVideoError.offline }
        return try decodeSettings(data, conflict: false)
    }

    func updateSettings(base: URL, token: String, revision: UInt64,
                        patch: CameraSettingsPatch) async throws -> CameraSettingsSnapshot {
        var request = try ownerRequest(base, "/api/video/settings", token, "PATCH")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(SettingsPatchRequest(expectedRevision: revision, patch: patch))
        let (data, response) = try await http.data(request)
        let status = response.statusCode
        guard status == 200 || status == 409 else {
            throw CameraVideoError.offline
        }
        return try decodeSettings(data, conflict: status == 409)
    }

    func deleteRecordings(base: URL, token: String, ids: [String], confirmation: String) async throws {
        let keys = transferSessions.keys.filter { key in ids.contains { key.hasPrefix("\($0)/") } }
        for key in keys {
            let parts = key.split(separator: "/")
            if parts.count == 2, let ordinal = UInt32(parts[1]) {
                await releaseRemoteTransfer(tripID: String(parts[0]), segmentID: ordinal,
                                            base: base, token: token, terminate: true)
            }
        }
        var request = try ownerRequest(base, "/api/video/recordings", token, "DELETE")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["tripIds": ids, "confirmation": confirmation])
        let (_, response) = try await http.data(request)
        guard response.statusCode == 204 else { throw CameraVideoError.offline }
    }

    private func lanCredential(endpoint: CameraLanEndpoint, bridgeToken: String) async throws -> LANCredential {
        guard !bridgeToken.isEmpty else { throw CameraVideoError.offline }
        let keyName = endpointKey(endpoint)
        if let current = lanSessions[keyName] {
            if current.expiresAt > now() { return current }
            await closeLANCatalogSession(endpoint: endpoint)
        }
        var challengeRequest = URLRequest(url: try lanURL(endpoint, "/api/video/lan/challenge")); challengeRequest.httpMethod = "POST"
        let (challengeData, challengeResponse) = try await http.data(challengeRequest)
        guard challengeResponse.statusCode == 200 else { throw CameraVideoError.offline }
        let challenge = try JSONDecoder().decode(LANChallenge.self, from: challengeData)
        let currentTime = now()
        guard challenge.nonce.count == 32, challenge.nonce.allSatisfy({ $0.isNumber || ("a"..."f").contains(String($0)) }),
              challenge.serverProof.count == 64, challenge.expiresAt > currentTime,
              challenge.expiresAt <= currentTime + 30_000 else { throw CameraVideoError.invalidResponse }
        let key = SymmetricKey(data: Data(bridgeToken.utf8))
        let serverInput = Data("haval-camera-lan-server-v1|\(challenge.deviceId)|\(challenge.nonce)|\(challenge.expiresAt)".utf8)
        guard let proof = Data(cameraHex: challenge.serverProof),
              HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: serverInput, using: key) else {
            throw CameraVideoError.invalidResponse
        }
        let input = Data("haval-camera-lan-v1|\(challenge.deviceId)|\(challenge.nonce)|\(challenge.expiresAt)".utf8)
        let hmac = Data(HMAC<SHA256>.authenticationCode(for: input, using: key)).cameraHex
        var request = URLRequest(url: try lanURL(endpoint, "/api/video/lan/session")); request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(LANSessionRequest(deviceId: challenge.deviceId, nonce: challenge.nonce,
                                                                       expiresAt: challenge.expiresAt, hmac: hmac, scope: "download"))
        let (data, response) = try await http.data(request)
        guard response.statusCode == 201 else { throw CameraVideoError.offline }
        let value = try JSONDecoder().decode(LANSessionResponse.self, from: data)
        guard value.scope == "download", value.sessionId.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil,
              value.downloadToken.count >= 32, value.controlToken.count >= 32,
              value.expiresAt > currentTime, value.expiresAt <= currentTime + 300_000 else {
            throw CameraVideoError.invalidResponse
        }
        let credential = LANCredential(id: value.sessionId, downloadToken: value.downloadToken,
                                       controlToken: value.controlToken, expiresAt: value.expiresAt)
        lanSessions[keyName] = credential
        return credential
    }

    private func lanURL(_ endpoint: CameraLanEndpoint, _ path: String) throws -> URL {
        guard (1...65_535).contains(endpoint.port), !endpoint.host.isEmpty,
              endpoint.host == endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines),
              !endpoint.host.contains("/"), !endpoint.host.contains("@"), !endpoint.host.contains("?"),
              !endpoint.host.contains("#") else { throw CameraVideoError.invalidResponse }
        let encoded = endpoint.host.replacingOccurrences(of: "%", with: "%25")
        let host = endpoint.host.contains(":") ? "[\(encoded)]" : encoded
        guard let url = URL(string: "http://\(host):\(endpoint.port)\(path)") else { throw CameraVideoError.invalidResponse }
        return url
    }

    private func ownerRequest(_ base: URL, _ path: String, _ token: String, _ method: String) throws -> URLRequest {
        guard base.scheme?.lowercased() == "https", base.user == nil, base.password == nil, base.fragment == nil,
              !token.isEmpty, let url = URL(string: path, relativeTo: base)?.absoluteURL,
              url.scheme?.lowercased() == "https" else { throw CameraVideoError.invalidResponse }
        var request = URLRequest(url: url); request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func requireDownloadCapability(_ endpoint: CameraLanEndpoint) async throws {
        let request = URLRequest(url: try lanURL(endpoint, "/api/capabilities"))
        let (data, response) = try await http.data(request)
        guard response.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["cameraDownloadLan"] as? Int == 1, object["hvtVersion"] as? Int == 1 else {
            throw CameraVideoError.offline
        }
    }

    private func decodeSettings(_ data: Data, conflict: Bool) throws -> CameraSettingsSnapshot {
        let value = try JSONDecoder().decode(SettingsResponse.self, from: data)
        return CameraSettingsSnapshot(revision: value.revision, settings: value.settings,
                                      updatedAt: Date(timeIntervalSince1970: Double(value.updatedAt) / 1_000),
                                      stale: value.stale, conflict: conflict || value.conflict == true)
    }

    private struct LANChallenge: Decodable { let deviceId, nonce: String; let expiresAt: Int64; let serverProof: String }
    private struct LANSessionRequest: Encodable { let deviceId, nonce: String; let expiresAt: Int64; let hmac, scope: String }
    private struct LANSessionResponse: Decodable { let sessionId, scope, downloadToken, controlToken: String; let expiresAt: Int64 }
    private struct TransferResponse: Decodable {
        let sessionId, viewerUrl, viewerToken: String
        let offsets: [String: String]
    }
    private struct SettingsPatchRequest: Encodable { let expectedRevision: UInt64; let patch: CameraSettingsPatch }
    private struct SettingsResponse: Decodable {
        let revision: UInt64; let settings: CameraSettings; let updatedAt: Int64; let stale: Bool; let conflict: Bool?
    }
    private func endpointKey(_ endpoint: CameraLanEndpoint) -> String { "\(endpoint.host):\(endpoint.port)" }
    private static func sessionID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil
    }
    private static func canonicalTripID(_ value: String) -> Bool {
        guard value.range(of: "^[1-9][0-9]{0,19}$", options: .regularExpression) != nil,
              let number = UInt64(value), number > 0 else { return false }
        return String(number) == value
    }
}

private final class URLSessionCameraTransferSocket: CameraTransferSocket {
    let authoritativeOffset: UInt64
    private let task: URLSessionWebSocketTask
    private let sessionID: String
    init(request: URLRequest, session: URLSession, authoritativeOffset: UInt64, sessionID: String) {
        self.authoritativeOffset = authoritativeOffset
        self.sessionID = sessionID
        task = session.webSocketTask(with: request); task.resume()
    }
    func receive() async throws -> Data {
        switch try await task.receive() {
        case .data(let data): return data
        case .string: throw CameraVideoError.invalidResponse
        @unknown default: throw CameraVideoError.invalidResponse
        }
    }
    func send(_ data: Data) async throws { try await task.send(.data(data)) }
    func close() { task.cancel(with: .goingAway, reason: nil) }
}

private extension Data {
    init?(cameraHex: String) {
        guard cameraHex.count.isMultiple(of: 2) else { return nil }
        var bytes = Data(); var index = cameraHex.startIndex
        while index < cameraHex.endIndex {
            let next = cameraHex.index(index, offsetBy: 2)
            guard let byte = UInt8(cameraHex[index..<next], radix: 16) else { return nil }
            bytes.append(byte); index = next
        }
        self = bytes
    }
    var cameraHex: String { map { String(format: "%02x", $0) }.joined() }
}
