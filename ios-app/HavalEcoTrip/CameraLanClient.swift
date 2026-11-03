import CryptoKit
import Foundation

struct CameraLanEndpoint: Equatable, Sendable {
    let host: String
    let port: Int
}

struct CameraLanSession: Sendable {
    let sessionId: String
    let viewerRequest: URLRequest
    let controlToken: String
    let expiresAt: Date
}

enum CameraLanError: Error, Equatable {
    case invalidEndpoint
    case unsupported
    case invalidResponse
    case invalidServerProof
    case expiredChallenge
    case insecureViewerURL
    case rejected(Int)
}

struct CameraLanClient {
    typealias HTTP = (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let http: HTTP
    private let nowMilliseconds: () -> Int64

    init(http: @escaping HTTP, nowMilliseconds: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }) {
        self.http = http
        self.nowMilliseconds = nowMilliseconds
    }

    static let live = CameraLanClient(http: { request in
        let (data, response) = try await CameraLanNoRedirectSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw CameraLanError.invalidResponse }
        return (data, response)
    })

    func createLiveSession(endpoint: CameraLanEndpoint, bridgeToken: String) async throws -> CameraLanSession {
        guard !bridgeToken.isEmpty else { throw CameraLanError.invalidServerProof }
        try Task.checkCancellation()
        let capabilitiesRequest = try request(endpoint: endpoint, path: "/api/capabilities", method: "GET")
        let (capabilitiesData, capabilitiesResponse) = try await http(capabilitiesRequest)
        try Task.checkCancellation()
        try requireStatus(capabilitiesResponse, 200)
        let capabilities = try JSONDecoder().decode(Capabilities.self, from: capabilitiesData)
        guard capabilities.cameraLiveLan == 1, capabilities.hvcVersion == 1 else { throw CameraLanError.unsupported }

        try Task.checkCancellation()
        let challengeRequest = try request(endpoint: endpoint, path: "/api/video/lan/challenge", method: "POST")
        let (challengeData, challengeResponse) = try await http(challengeRequest)
        try Task.checkCancellation()
        try requireStatus(challengeResponse, 200)
        let challenge = try decodeChallenge(challengeData)
        let input = "haval-camera-lan-server-v1|\(challenge.deviceId)|\(challenge.nonce)|\(challenge.expiresAt)"
        let key = SymmetricKey(data: Data(bridgeToken.utf8))
        guard let serverCode = Data(lowercaseHex: challenge.serverProof),
              HMAC<SHA256>.isValidAuthenticationCode(serverCode, authenticating: Data(input.utf8), using: key) else {
            throw CameraLanError.invalidServerProof
        }

        try Task.checkCancellation()
        let clientInput = "haval-camera-lan-v1|\(challenge.deviceId)|\(challenge.nonce)|\(challenge.expiresAt)"
        let clientProof = Data(HMAC<SHA256>.authenticationCode(for: Data(clientInput.utf8), using: key)).lowercaseHex
        let sessionBody = SessionRequest(
            deviceId: challenge.deviceId,
            nonce: challenge.nonce,
            expiresAt: challenge.expiresAt,
            hmac: clientProof,
            scope: "live"
        )
        var sessionRequest = try request(endpoint: endpoint, path: "/api/video/lan/session", method: "POST")
        sessionRequest.httpBody = try JSONEncoder().encode(sessionBody)
        sessionRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try Task.checkCancellation()
        let (sessionData, sessionResponse) = try await http(sessionRequest)
        try requireStatus(sessionResponse, 201)
        let session = try JSONDecoder().decode(SessionResponse.self, from: sessionData)
        guard session.scope == "live", !session.sessionId.isEmpty, !session.viewerToken.isEmpty,
              !session.controlToken.isEmpty, session.expiresAt > nowMilliseconds() else {
            throw CameraLanError.invalidResponse
        }
        let viewerURL = try validatedViewerURL(path: session.viewerPath, sessionId: session.sessionId, endpoint: endpoint)
        var viewerRequest = URLRequest(url: viewerURL, timeoutInterval: 15)
        viewerRequest.setValue("Bearer " + session.viewerToken, forHTTPHeaderField: "Authorization")
        let result = CameraLanSession(
            sessionId: session.sessionId,
            viewerRequest: viewerRequest,
            controlToken: session.controlToken,
            expiresAt: Date(timeIntervalSince1970: Double(session.expiresAt) / 1_000)
        )
        if Task.isCancelled {
            await revokeAfterCancellation(result, endpoint: endpoint)
            throw CancellationError()
        }
        return result
    }

    func stopLiveSession(_ session: CameraLanSession, endpoint: CameraLanEndpoint) async throws {
        guard session.sessionId.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }) else {
            throw CameraLanError.invalidResponse
        }
        var stop = try request(endpoint: endpoint, path: "/api/video/lan/session/" + session.sessionId, method: "DELETE")
        stop.setValue("Bearer " + session.controlToken, forHTTPHeaderField: "Authorization")
        let (_, response) = try await http(stop)
        guard response.statusCode == 200 || response.statusCode == 404 else { throw CameraLanError.rejected(response.statusCode) }
    }

    private func decodeChallenge(_ data: Data) throws -> Challenge {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["deviceId", "nonce", "expiresAt", "serverProof"]) else {
            throw CameraLanError.invalidResponse
        }
        let challenge = try JSONDecoder().decode(Challenge.self, from: data)
        guard !challenge.deviceId.isEmpty,
              challenge.nonce.count == 32, challenge.nonce.allSatisfy(\.isLowercaseHexDigit),
              challenge.serverProof.count == 64, challenge.serverProof.allSatisfy(\.isLowercaseHexDigit) else {
            throw CameraLanError.invalidResponse
        }
        let now = nowMilliseconds()
        let (latest, overflow) = now.addingReportingOverflow(30_000)
        guard !overflow, challenge.expiresAt > now, challenge.expiresAt <= latest else {
            throw CameraLanError.expiredChallenge
        }
        return challenge
    }

    private func request(endpoint: CameraLanEndpoint, path: String, method: String) throws -> URLRequest {
        let url = try endpointURL(endpoint, scheme: "http", path: path)
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return request
    }

    private func endpointURL(_ endpoint: CameraLanEndpoint, scheme: String, path: String) throws -> URL {
        let host = try normalizedHost(endpoint.host)
        guard (1...65_535).contains(endpoint.port), path.hasPrefix("/") else {
            throw CameraLanError.invalidEndpoint
        }
        let encodedHost = host.address.replacingOccurrences(of: "%", with: "%25")
        let authority = host.isIPv6 ? "[\(encodedHost)]" : encodedHost
        guard let url = URL(string: "\(scheme)://\(authority):\(endpoint.port)\(path)"),
              url.scheme == scheme, url.user == nil, url.password == nil, url.fragment == nil,
              url.port == endpoint.port,
              try normalizedHost(urlHost(url)) == host else { throw CameraLanError.invalidEndpoint }
        return url
    }

    private func normalizedHost(_ value: String) throws -> NormalizedHost {
        var host = value
        if host.hasPrefix("[") || host.hasSuffix("]") {
            guard host.hasPrefix("["), host.hasSuffix("]"), host.count > 2 else { throw CameraLanError.invalidEndpoint }
            host.removeFirst(); host.removeLast()
        }
        guard !host.isEmpty, host == host.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.contains("@"), !host.contains("/"), !host.contains("?"), !host.contains("#") else {
            throw CameraLanError.invalidEndpoint
        }
        let isIPv6 = host.contains(":")
        if let marker = host.firstIndex(of: "%") {
            guard isIPv6, host[host.index(after: marker)...].allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }),
                  !host[host.index(after: marker)...].isEmpty,
                  host[host.index(after: marker)...].firstIndex(of: "%") == nil else {
                throw CameraLanError.invalidEndpoint
            }
        }
        return NormalizedHost(address: host, isIPv6: isIPv6)
    }

    private func urlHost(_ url: URL) throws -> String {
        guard var encoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedHost else {
            throw CameraLanError.invalidEndpoint
        }
        if encoded.hasPrefix("[") && encoded.hasSuffix("]") { encoded.removeFirst(); encoded.removeLast() }
        return encoded.replacingOccurrences(of: "%25", with: "%")
    }

    private func validatedViewerURL(path: String, sessionId: String, endpoint: CameraLanEndpoint) throws -> URL {
        guard let relative = URLComponents(string: path), relative.scheme == nil, relative.host == nil,
              relative.user == nil, relative.password == nil, relative.fragment == nil,
              relative.path == "/ws/video/lan/viewer",
              relative.queryItems == [URLQueryItem(name: "session", value: sessionId)] else {
            throw CameraLanError.insecureViewerURL
        }
        var absolute = URLComponents(url: try endpointURL(endpoint, scheme: "ws", path: relative.path), resolvingAgainstBaseURL: false)!
        absolute.queryItems = relative.queryItems
        guard let url = absolute.url else { throw CameraLanError.insecureViewerURL }
        return url
    }

    private func requireStatus(_ response: HTTPURLResponse, _ expected: Int) throws {
        guard response.statusCode == expected else { throw CameraLanError.rejected(response.statusCode) }
    }

    private func revokeAfterCancellation(_ session: CameraLanSession, endpoint: CameraLanEndpoint) async {
        await Task { try? await stopLiveSession(session, endpoint: endpoint) }.value
    }

    private struct NormalizedHost: Equatable {
        let address: String
        let isIPv6: Bool

        static func == (lhs: Self, rhs: Self) -> Bool {
            let left = lhs.address.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
            let right = rhs.address.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
            return lhs.isIPv6 == rhs.isIPv6
                && String(left[0]).caseInsensitiveCompare(String(right[0])) == .orderedSame
                && left.dropFirst().first == right.dropFirst().first
        }
    }

    private struct Capabilities: Decodable {
        let cameraLiveLan: Int?
        let hvcVersion: Int?
    }

    private struct Challenge: Decodable {
        let deviceId: String
        let nonce: String
        let expiresAt: Int64
        let serverProof: String
    }

    private struct SessionRequest: Encodable {
        let deviceId: String
        let nonce: String
        let expiresAt: Int64
        let hmac: String
        let scope: String
    }

    private struct SessionResponse: Decodable {
        let sessionId: String
        let expiresAt: Int64
        let scope: String
        let viewerToken: String
        let controlToken: String
        let viewerPath: String
    }
}

private extension Character {
    var isLowercaseHexDigit: Bool {
        isNumber || ("a"..."f").contains(String(self))
    }
}

private extension Data {
    init?(lowercaseHex: String) {
        guard lowercaseHex.count.isMultiple(of: 2), lowercaseHex.allSatisfy(\.isLowercaseHexDigit) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(lowercaseHex.count / 2)
        var index = lowercaseHex.startIndex
        while index < lowercaseHex.endIndex {
            let next = lowercaseHex.index(index, offsetBy: 2)
            guard let byte = UInt8(lowercaseHex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }

    var lowercaseHex: String { map { String(format: "%02x", $0) }.joined() }
}

final class CameraLanNoRedirectSession: NSObject, URLSessionTaskDelegate {
    static let delegate = CameraLanNoRedirectSession()
    static let shared = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)

    static func webSocket(request: URLRequest) -> CameraLiveSocket {
        URLSessionCameraLiveSocket(request: request, session: shared)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
