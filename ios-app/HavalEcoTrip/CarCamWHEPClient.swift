import Foundation
import Security

struct CarCamWHEPSession: Equatable, Sendable {
    let answerSDP: String
    let location: URL
}

actor CarCamWHEPClient {
    static let shouldFollowRedirect = false
    static let maximumSDPBytes = 65_536

    private let configuration: CarCamBridgeConfiguration
    private let session: URLSession

    init(configuration: CarCamBridgeConfiguration) {
        self.configuration = configuration
        let delegate = CarCamPinnedSessionDelegate(configuration: configuration)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.urlCache = nil
        self.session = URLSession(configuration: sessionConfiguration, delegate: delegate, delegateQueue: nil)
    }

    func createSession(offerSDP: String) async throws -> CarCamWHEPSession {
        let body = Data(offerSDP.utf8)
        guard !body.isEmpty, body.count <= Self.maximumSDPBytes else {
            throw body.isEmpty ? CarCamViewerError.invalidSDP : .bodyTooLarge
        }
        var request = URLRequest(
            url: configuration.baseURL.appendingPathComponent("api/v1/live/whep"),
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 30
        )
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + configuration.bearerToken, forHTTPHeaderField: "Authorization")
        let (responseBody, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw CarCamViewerError.invalidResponse
        }
        return try Self.validateCreatedSession(
            response: response, body: responseBody, configuration: configuration)
    }

    func stopSession(at location: URL) async throws {
        guard Self.validatedLocation(location, configuration: configuration) != nil else {
            throw CarCamViewerError.invalidLocation
        }
        var request = URLRequest(
            url: location,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 15
        )
        request.httpMethod = "DELETE"
        request.setValue("Bearer " + configuration.bearerToken, forHTTPHeaderField: "Authorization")
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw CarCamViewerError.invalidResponse
        }
        guard response.statusCode == 204 || response.statusCode == 404 else {
            throw Self.error(forHTTPStatus: response.statusCode)
        }
    }

    static func validateCreatedSession(
        response: HTTPURLResponse,
        body: Data,
        configuration: CarCamBridgeConfiguration
    ) throws -> CarCamWHEPSession {
        guard response.statusCode == 201 else {
            throw error(forHTTPStatus: response.statusCode)
        }
        guard response.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("application/sdp") == .orderedSame,
              !body.isEmpty, body.count <= maximumSDPBytes,
              let answerSDP = String(data: body, encoding: .utf8), !answerSDP.isEmpty,
              let rawLocation = response.value(forHTTPHeaderField: "Location"),
              let location = URL(string: rawLocation),
              let safeLocation = validatedLocation(location, configuration: configuration) else {
            throw CarCamViewerError.invalidResponse
        }
        return CarCamWHEPSession(answerSDP: answerSDP, location: safeLocation)
    }

    static func error(forHTTPStatus status: Int) -> CarCamViewerError {
        switch status {
        case 401: .unauthorized
        case 409: .viewerExists
        case 413: .bodyTooLarge
        case 415: .unsupportedMediaType
        case 422: .invalidSDP
        case 500: .teardownFailed
        case 502: .mediaSetupFailed
        case 503: .tailscaleUnavailable
        case 504: .setupTimeout
        default: .invalidResponse
        }
    }

    private static func validatedLocation(
        _ location: URL,
        configuration: CarCamBridgeConfiguration
    ) -> URL? {
        guard let base = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false),
              let candidate = URLComponents(url: location, resolvingAgainstBaseURL: false),
              candidate.scheme?.lowercased() == "https",
              candidate.host?.caseInsensitiveCompare(base.host ?? "") == .orderedSame,
              candidate.port == base.port,
              candidate.user == nil, candidate.password == nil,
              candidate.query == nil, candidate.fragment == nil,
              candidate.path.hasPrefix("/api/v1/live/sessions/"),
              candidate.path.count > "/api/v1/live/sessions/".count else { return nil }
        return location
    }
}

final class CarCamPinnedSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    private let configuration: CarCamBridgeConfiguration

    init(configuration: CarCamBridgeConfiguration) {
        self.configuration = configuration
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

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == configuration.baseURL.host,
              let trust = challenge.protectionSpace.serverTrust,
              validatesPinnedTrust(trust) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    private func validatesPinnedTrust(_ trust: SecTrust) -> Bool {
        guard SecTrustGetCertificateCount(trust) == 1,
              let certificate = SecTrustGetCertificateAtIndex(trust, 0),
              let key = SecCertificateCopyKey(certificate),
              let attributes = SecKeyCopyAttributes(key) as? [CFString: Any],
              attributes[kSecAttrKeyType] as? CFString == kSecAttrKeyTypeECSECPrimeRandom,
              attributes[kSecAttrKeySizeInBits] as? Int == 256,
              let rawKey = SecKeyCopyExternalRepresentation(key, nil) as Data?,
              let pin = try? CarCamSPKI.p256Pin(rawPublicKey: rawKey),
              CarCamSPKI.matches(pin, configuration.spkiSHA256),
              SecTrustSetPolicies(trust, SecPolicyCreateBasicX509()) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else { return false }
        return SecTrustEvaluateWithError(trust, nil)
    }
}
