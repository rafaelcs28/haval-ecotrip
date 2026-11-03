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
}

struct CameraLANDownload: Equatable, Sendable {
    let statusCode: Int
    let contentRange: String?
    let chunks: [Data]
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
}

struct CameraVideoTransport {
    var fetchLANCatalog: (CameraLanEndpoint, String) async throws -> CameraVideoCatalog
    var fetchRemoteCatalog: (URL, String) async throws -> CameraVideoCatalog
    var downloadLANSegment: (String, CameraVideoSegment, UInt32, UInt64, CameraLanEndpoint, String) async throws -> CameraLANDownload
    var openRemoteTransfer: (String, CameraVideoSegment, UInt64, URL, String) async throws -> CameraTransferSocket
    var fetchSettings: (URL, String) async throws -> CameraSettingsSnapshot
    var updateSettings: (URL, String, UInt64, CameraSettingsPatch) async throws -> CameraSettingsSnapshot
    var deleteRecordings: (URL, String, [String], String) async throws -> Void

    static var testing: Self {
        Self(
            fetchLANCatalog: { _, _ in throw CameraVideoError.offline },
            fetchRemoteCatalog: { _, _ in throw CameraVideoError.offline },
            downloadLANSegment: { _, _, _, _, _, _ in throw CameraVideoError.offline },
            openRemoteTransfer: { _, _, _, _, _ in throw CameraVideoError.offline },
            fetchSettings: { _, _ in throw CameraVideoError.offline },
            updateSettings: { _, _, _, _ in throw CameraVideoError.offline },
            deleteRecordings: { _, _, _, _ in throw CameraVideoError.offline })
    }

    static var live: Self {
        let network = CameraVideoNetwork()
        return Self(
            fetchLANCatalog: network.fetchLANCatalog,
            fetchRemoteCatalog: network.fetchRemoteCatalog,
            downloadLANSegment: network.downloadLANSegment,
            openRemoteTransfer: network.openRemoteTransfer,
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

    @Published private(set) var trips: [CameraVideoTrip] = []
    @Published private(set) var catalogState: CatalogState = .idle
    @Published private(set) var downloadState: DownloadState = .idle
    @Published private(set) var settings: CameraSettings?
    @Published private(set) var settingsRevision: UInt64?
    @Published private(set) var settingsState: SettingsState = .idle

    private let rootURL: URL
    private var transport: CameraVideoTransport
    private let availableCapacity: (URL) -> Int64?
    private let catalogPolicy = CameraRoutePolicy()
    private var catalogContext: (CameraLanEndpoint?, URL, String)?

    init(rootURL: URL? = nil, transport: CameraVideoTransport = .live,
         availableCapacity: @escaping (URL) -> Int64? = CameraVideoStore.systemCapacity) {
        self.rootURL = rootURL ?? Self.applicationSupportRoot()
        self.transport = transport
        self.availableCapacity = availableCapacity
    }

    func loadCatalog(lanEndpoint: CameraLanEndpoint?, bridgeURL: URL, bridgeToken: String) async {
        catalogContext = (lanEndpoint, bridgeURL, bridgeToken)
        catalogState = .loading
        switch catalogPolicy.beginAction(lanAvailable: lanEndpoint != nil) {
        case .useLAN:
            guard let lanEndpoint else { return }
            do { applyCatalog(try await transport.fetchLANCatalog(lanEndpoint, bridgeToken), route: .lan) }
            catch { catalogState = trips.isEmpty ? .askingInternet : .offline(stale: true) }
        case .askInternet: catalogState = .askingInternet
        case .offline: catalogState = .offline(stale: !trips.isEmpty)
        }
    }

    func reloadCatalog() async {
        guard let context = catalogContext else { return }
        if let endpoint = context.0 {
            catalogState = .loading
            do { applyCatalog(try await transport.fetchLANCatalog(endpoint, context.2), route: .lan) }
            catch { catalogState = .offline(stale: !trips.isEmpty) }
        } else if catalogPolicy.internetAllowed {
            await fetchRemoteCatalog(context)
        } else { catalogState = .askingInternet }
    }

    func confirmCatalogInternet() async {
        guard catalogState == .askingInternet, let context = catalogContext else { return }
        catalogPolicy.confirmInternet(); catalogState = .loading
        await fetchRemoteCatalog(context)
    }

    func closeCatalogAction() {
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

    func downloadSegment(tripID: String, segment: CameraVideoSegment, route: CameraDownloadRoute,
                         lanEndpoint: CameraLanEndpoint?, bridgeURL: URL, bridgeToken: String) async throws -> URL {
        guard !tripID.isEmpty, segment.id > 0, segment.byteSize > 0, segment.sha256.count == 32 else {
            throw CameraVideoError.invalidSelection
        }
        let final = completedURL(tripID: tripID, segmentID: segment.id)
        if FileManager.default.fileExists(atPath: final.path) {
            guard try verify(final, segment: segment) else { throw CameraVideoError.duplicateSegment }
            return final
        }
        let partial = partialURL(tripID: tripID, segmentID: segment.id, route: route)
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
                try await downloadLAN(tripID: tripID, segment: segment, offset: offset, partial: partial,
                                      endpoint: lanEndpoint, bridgeToken: bridgeToken)
            case .internet:
                try await downloadRemote(tripID: tripID, segment: segment, offset: offset, partial: partial,
                                         bridgeURL: bridgeURL, bridgeToken: bridgeToken)
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
        let response = try await transport.downloadLANSegment(tripID, segment, segment.id, offset, endpoint, bridgeToken)
        if offset == 0 {
            guard response.statusCode == 200 || response.contentRange == "bytes 0-\(segment.byteSize - 1)/\(segment.byteSize)" else {
                throw CameraVideoError.invalidOffset
            }
        } else {
            guard response.statusCode == 206,
                  response.contentRange == "bytes \(offset)-\(segment.byteSize - 1)/\(segment.byteSize)" else {
                throw CameraVideoError.invalidOffset
            }
        }
        let handle = try appendHandle(partial)
        defer { try? handle.close() }
        var written = offset
        for chunk in response.chunks {
            try Task.checkCancellation()
            guard !chunk.isEmpty, written <= segment.byteSize,
                  UInt64(chunk.count) <= segment.byteSize - written else { throw CameraVideoError.invalidOffset }
            try handle.write(contentsOf: chunk); try handle.synchronize()
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
        let handle = try appendHandle(partial)
        defer { try? handle.close() }
        var expected = offset
        while true {
            try Task.checkCancellation()
            let message = try CameraTransferProtocol.parse(try await socket.receive())
            guard message.ordinal == segment.id else { throw CameraVideoError.invalidSelection }
            switch message.type {
            case .data:
                guard message.offset == expected, expected <= segment.byteSize,
                      UInt64(message.payload.count) <= segment.byteSize - expected else { throw CameraVideoError.invalidOffset }
                try handle.write(contentsOf: message.payload)
                try handle.synchronize()
                expected += UInt64(message.payload.count)
                try await socket.send(CameraTransferProtocol.ack(ordinal: segment.id, nextOffset: expected))
                downloadState = .downloading(route: .internet, progress: Double(expected) / Double(segment.byteSize))
            case .eof:
                guard message.offset == segment.byteSize, expected == segment.byteSize,
                      message.sha256 == segment.sha256, try verify(partial, segment: segment) else {
                    throw CameraVideoError.digestMismatch
                }
                try handle.synchronize()
                try await socket.send(CameraTransferProtocol.ack(ordinal: segment.id, nextOffset: expected))
                return
            case .error: throw CameraVideoError.offline
            case .ack: throw CameraVideoError.invalidResponse
            }
        }
    }

    func completedURL(tripID: String, segmentID: UInt32) -> URL {
        tripDirectory(tripID).appendingPathComponent(String(format: "%06u.mp4", segmentID))
    }

    func partialURL(tripID: String, segmentID: UInt32, route: CameraDownloadRoute) -> URL {
        tripDirectory(tripID).appendingPathComponent(String(format: "%06u.%@.partial", segmentID, route.rawValue))
    }

    func playbackURLs(for trip: CameraVideoTrip) throws -> [URL] {
        try trip.segments.sorted { $0.id < $1.id }.map { segment in
            let url = completedURL(tripID: trip.id, segmentID: segment.id)
            guard try verify(url, segment: segment), url.path.hasPrefix(rootURL.standardizedFileURL.path + "/") else {
                throw CameraVideoError.invalidSelection
            }
            return url
        }
    }

    func shareURLs(for trip: CameraVideoTrip) throws -> [URL] { try playbackURLs(for: trip) }

    func deleteRecordings(_ tripIDs: [String], confirmed: Bool, bridgeURL: URL, bridgeToken: String) async throws {
        guard confirmed else { throw CameraVideoError.deletionNotConfirmed }
        try await transport.deleteRecordings(bridgeURL, bridgeToken, tripIDs, "DELETE_COMPLETED")
    }

    func loadSettings(bridgeURL: URL, bridgeToken: String) async {
        settingsState = .loading
        do {
            let snapshot = try await transport.fetchSettings(bridgeURL, bridgeToken)
            settings = snapshot.settings; settingsRevision = snapshot.revision
            settingsState = .loaded(stale: snapshot.stale)
        } catch { settingsState = .failed }
    }

    func updateSettings(_ patch: CameraSettingsPatch, bridgeURL: URL, bridgeToken: String) async {
        guard let current = settings, let revision = settingsRevision else { settingsState = .failed; return }
        let previous = current
        settings = patch.applying(to: current); settingsState = .saving
        do {
            let snapshot = try await transport.updateSettings(bridgeURL, bridgeToken, revision, patch)
            settings = snapshot.settings; settingsRevision = snapshot.revision
            settingsState = snapshot.conflict ? .conflict : .loaded(stale: snapshot.stale)
        } catch {
            settings = previous; settingsState = .failed
        }
    }

    func replaceTransportForTesting(_ value: CameraVideoTransport) { transport = value }

    private func tripDirectory(_ tripID: String) -> URL {
        rootURL.appendingPathComponent(tripID, isDirectory: true)
    }

    private func appendHandle(_ url: URL) throws -> FileHandle {
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: url); try handle.seekToEnd(); return handle
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
        let value = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        return UInt64(value)
    }

    private static func applicationSupportRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("HavalCamera", isDirectory: true)
    }

    static func systemCapacity(_ url: URL) -> Int64? {
        try? url.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }
}

private final class CameraVideoNetwork {
    private let session = CameraLanNoRedirectSession.shared
    private var transferSessions: [String: String] = [:]

    func fetchLANCatalog(endpoint: CameraLanEndpoint, bridgeToken: String) async throws -> CameraVideoCatalog {
        try await requireDownloadCapability(endpoint)
        let credential = try await lanCredential(endpoint: endpoint, bridgeToken: bridgeToken)
        var request = URLRequest(url: try lanURL(endpoint, "/api/video/lan/catalog?session=\(credential.id)"))
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CameraVideoError.offline }
        return try decodeCatalog(data, route: .lan)
    }

    func fetchRemoteCatalog(base: URL, token: String) async throws -> CameraVideoCatalog {
        let (data, response) = try await session.data(for: try ownerRequest(base, "/api/video/catalog", token, "GET"))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CameraVideoError.offline }
        return try decodeCatalog(data, route: .internet)
    }

    func downloadLANSegment(tripID: String, segment: CameraVideoSegment, ordinal: UInt32, offset: UInt64,
                            endpoint: CameraLanEndpoint, bridgeToken: String) async throws -> CameraLANDownload {
        try await requireDownloadCapability(endpoint)
        let credential = try await lanCredential(endpoint: endpoint, bridgeToken: bridgeToken)
        let path = "/api/video/lan/trips/\(tripID)/segments/\(ordinal)?session=\(credential.id)"
        var request = URLRequest(url: try lanURL(endpoint, path))
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CameraVideoError.invalidResponse }
        return CameraLANDownload(statusCode: http.statusCode,
                                 contentRange: http.value(forHTTPHeaderField: "Content-Range"), chunks: [data])
    }

    func openRemoteTransfer(tripID: String, segment: CameraVideoSegment, offset: UInt64,
                            base: URL, token: String) async throws -> CameraTransferSocket {
        let key = "\(tripID)/\(segment.id)"
        var body: [String: Any] = ["tripId": tripID, "segmentIds": [String(segment.id)]]
        if let existing = transferSessions[key] { body["sessionId"] = existing }
        var request = try ownerRequest(base, "/api/video/transfer/session", token, "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 201 else { throw CameraVideoError.offline }
        let value = try JSONDecoder().decode(TransferResponse.self, from: data)
        guard let url = URL(string: value.viewerUrl), url.scheme == "wss", url.user == nil, url.fragment == nil,
              value.offsets[String(segment.id)].flatMap(UInt64.init) == offset else { throw CameraVideoError.invalidOffset }
        transferSessions[key] = value.sessionId
        var socketRequest = URLRequest(url: url)
        socketRequest.setValue("Bearer \(value.viewerToken)", forHTTPHeaderField: "Authorization")
        return URLSessionCameraTransferSocket(request: socketRequest, session: session, authoritativeOffset: offset)
    }

    func fetchSettings(base: URL, token: String) async throws -> CameraSettingsSnapshot {
        let (data, response) = try await session.data(for: try ownerRequest(base, "/api/video/settings", token, "GET"))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CameraVideoError.offline }
        return try decodeSettings(data, conflict: false)
    }

    func updateSettings(base: URL, token: String, revision: UInt64,
                        patch: CameraSettingsPatch) async throws -> CameraSettingsSnapshot {
        var request = try ownerRequest(base, "/api/video/settings", token, "PATCH")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(SettingsPatchRequest(expectedRevision: revision, patch: patch))
        let (data, response) = try await session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 || status == 409 else {
            throw CameraVideoError.offline
        }
        return try decodeSettings(data, conflict: status == 409)
    }

    func deleteRecordings(base: URL, token: String, ids: [String], confirmation: String) async throws {
        var request = try ownerRequest(base, "/api/video/recordings", token, "DELETE")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["tripIds": ids, "confirmation": confirmation])
        let (_, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 204 else { throw CameraVideoError.offline }
    }

    private func lanCredential(endpoint: CameraLanEndpoint, bridgeToken: String) async throws -> (id: String, token: String) {
        guard !bridgeToken.isEmpty else { throw CameraVideoError.offline }
        var challengeRequest = URLRequest(url: try lanURL(endpoint, "/api/video/lan/challenge")); challengeRequest.httpMethod = "POST"
        let (challengeData, challengeResponse) = try await session.data(for: challengeRequest)
        guard (challengeResponse as? HTTPURLResponse)?.statusCode == 200 else { throw CameraVideoError.offline }
        let challenge = try JSONDecoder().decode(LANChallenge.self, from: challengeData)
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        guard challenge.nonce.count == 32, challenge.nonce.allSatisfy({ $0.isNumber || ("a"..."f").contains(String($0)) }),
              challenge.serverProof.count == 64, challenge.expiresAt > now,
              challenge.expiresAt <= now + 30_000 else { throw CameraVideoError.invalidResponse }
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
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 201 else { throw CameraVideoError.offline }
        let value = try JSONDecoder().decode(LANSessionResponse.self, from: data)
        guard value.scope == "download", !value.sessionId.isEmpty, !value.downloadToken.isEmpty else {
            throw CameraVideoError.invalidResponse
        }
        return (value.sessionId, value.downloadToken)
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
        let (data, response) = try await session.data(from: try lanURL(endpoint, "/api/capabilities"))
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["cameraDownloadLan"] as? Int == 1, object["hvtVersion"] as? Int == 1 else {
            throw CameraVideoError.offline
        }
    }

    private func decodeCatalog(_ data: Data, route: CameraDownloadRoute) throws -> CameraVideoCatalog {
        let value = try JSONDecoder().decode(CatalogResponse.self, from: data)
        let trips = try value.trips.map { trip -> CameraVideoTrip in
            let segments = try (trip.segments.array ?? []).map { segment -> CameraVideoSegment in
                guard let digest = Data(cameraHex: segment.sha256), digest.count == 32 else { throw CameraVideoError.invalidResponse }
                return CameraVideoSegment(id: segment.segmentId, byteSize: segment.byteSize, sha256: digest)
            }
            return CameraVideoTrip(id: trip.tripId, source: trip.source, start: Date(timeIntervalSince1970: Double(trip.startMs) / 1_000),
                                   end: trip.endMs.map { Date(timeIntervalSince1970: Double($0) / 1_000) },
                                   byteSize: trip.byteSize, completed: trip.completed ?? trip.endMs != nil, segments: segments)
        }
        return CameraVideoCatalog(revision: value.catalogRevision ?? 0,
                                  updatedAt: Date(timeIntervalSince1970: Double(value.updatedAt ?? 0) / 1_000),
                                  stale: value.stale ?? false, route: route, trips: trips)
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
    private struct CatalogResponse: Decodable {
        let catalogRevision: UInt64?; let updatedAt: Int64?; let stale: Bool?; let trips: [Trip]
        struct Trip: Decodable {
            let tripId: String; let source: CameraVideoTrip.Source; let startMs: Int64; let endMs: Int64?
            let byteSize: UInt64; let completed: Bool?; let segments: SegmentValue
        }
        struct Segment: Decodable { let segmentId: UInt32; let byteSize: UInt64; let sha256: String }
        enum SegmentValue: Decodable {
            case count(UInt32), values([Segment])
            var array: [Segment]? { if case .values(let value) = self { return value }; return nil }
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let count = try? container.decode(UInt32.self) { self = .count(count) }
                else { self = .values(try container.decode([Segment].self)) }
            }
        }
    }
}

private final class URLSessionCameraTransferSocket: CameraTransferSocket {
    let authoritativeOffset: UInt64
    private let task: URLSessionWebSocketTask
    init(request: URLRequest, session: URLSession, authoritativeOffset: UInt64) {
        self.authoritativeOffset = authoritativeOffset
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
