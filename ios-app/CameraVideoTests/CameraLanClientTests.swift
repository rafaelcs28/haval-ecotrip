import Foundation
import XCTest

#if TASK7_IMPLEMENTED
@MainActor
final class CameraLanClientTests: XCTestCase {
    private let endpoint = CameraLanEndpoint(host: "192.168.8.20", port: 8080)
    private let token = "synthetic-paired-secret"
    private let nonce = "000102030405060708090a0b0c0d0e0f"
    private let serverProof = "74827a55d7d59155958cbf202ea29b7a9ea99213953e6831f1ee9a8ff46dd8de"
    private let clientProof = "2dab4d474d1e23961a2246ba4611bdfe10418e40a2c9c5a5cc24d1413766a312"

    func testExactAndroidServerAndClientHMACVectors() async throws {
        let capture = RequestCapture()
        let client = makeClient(capture: capture)

        _ = try await client.createLiveSession(endpoint: endpoint, bridgeToken: token)

        XCTAssertEqual(capture.requests.count, 3)
        let body = try XCTUnwrap(capture.requests[2].httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["hmac"] as? String, clientProof)
        XCTAssertEqual(json["deviceId"] as? String, "car-1")
        XCTAssertEqual(json["nonce"] as? String, nonce)
        XCTAssertEqual(json["expiresAt"] as? Int, 31_000)
    }

    func testInvalidServerProofSendsNoSessionRequest() async {
        let capture = RequestCapture()
        let client = CameraLanClient(http: { request in
            capture.append(request)
            if request.url?.path == "/api/capabilities" {
                return Self.response(request, status: 200, body: Self.capabilities)
            }
            return Self.response(request, status: 200, body: Self.challenge(serverProof: String(repeating: "0", count: 64)))
        }, nowMilliseconds: { 1_000 })

        await XCTAssertThrowsErrorAsync {
            _ = try await client.createLiveSession(endpoint: endpoint, bridgeToken: token)
        }
        XCTAssertEqual(capture.requests.map(\.url?.path), ["/api/capabilities", "/api/video/lan/challenge"])
    }

    func testEmptyBridgeTokenFailsBeforeAnyLANRequest() async {
        let capture = RequestCapture()
        let client = makeClient(capture: capture)

        await XCTAssertThrowsErrorAsync {
            _ = try await client.createLiveSession(endpoint: endpoint, bridgeToken: "")
        }

        XCTAssertTrue(capture.requests.isEmpty)
    }

    func testMissingMalformedAndExpiredServerProofSendNoSessionRequest() async {
        let invalidChallenges: [Data] = [
            Data("{\"deviceId\":\"car-1\",\"nonce\":\"\(nonce)\",\"expiresAt\":31000}".utf8),
            Self.challenge(serverProof: "ABC"),
            Data("{\"deviceId\":\"car-1\",\"nonce\":\"\(nonce)\",\"expiresAt\":999,\"serverProof\":\"\(serverProof)\"}".utf8),
        ]
        for challenge in invalidChallenges {
            var paths: [String] = []
            let client = CameraLanClient(http: { request in
                paths.append(request.url!.path)
                return request.url?.path == "/api/capabilities"
                    ? Self.response(request, status: 200, body: Self.capabilities)
                    : Self.response(request, status: 200, body: challenge)
            }, nowMilliseconds: { 1_000 })

            await XCTAssertThrowsErrorAsync {
                _ = try await client.createLiveSession(endpoint: endpoint, bridgeToken: token)
            }
            XCTAssertEqual(paths, ["/api/capabilities", "/api/video/lan/challenge"])
        }
    }

    func testMissingCapabilityIsUnsupported() async {
        let capture = RequestCapture()
        let client = CameraLanClient(http: { request in
            capture.append(request)
            return Self.response(request, status: 200, body: Data("{\"cameraLiveLan\":0,\"hvcVersion\":1}".utf8))
        }, nowMilliseconds: { 1_000 })

        await XCTAssertThrowsErrorAsync {
            _ = try await client.createLiveSession(endpoint: endpoint, bridgeToken: token)
        }
        XCTAssertEqual(capture.requests.count, 1)
    }

    func testLongTokenAppearsOnlyAsHMACKey() async throws {
        let capture = RequestCapture()
        let client = makeClient(capture: capture)

        let session = try await client.createLiveSession(endpoint: endpoint, bridgeToken: token)

        let visible = capture.requests.map { request in
            request.url!.absoluteString
                + (request.allHTTPHeaderFields ?? [:]).description
                + String(data: request.httpBody ?? Data(), encoding: .utf8)!
        }.joined() + session.viewerRequest.description
        XCTAssertFalse(visible.contains(token))
        XCTAssertFalse(String(describing: client).contains(token))
    }

    func testRequestsUseExactResolvedHTTPHostAndPort() async throws {
        let capture = RequestCapture()
        let client = makeClient(capture: capture)

        _ = try await client.createLiveSession(endpoint: endpoint, bridgeToken: token)

        XCTAssertTrue(capture.requests.allSatisfy { $0.url?.scheme == "http" })
        XCTAssertTrue(capture.requests.allSatisfy { $0.url?.host == "192.168.8.20" })
        XCTAssertTrue(capture.requests.allSatisfy { $0.url?.port == 8080 })
        XCTAssertTrue(capture.requests.allSatisfy { $0.url?.user == nil && $0.url?.password == nil && $0.url?.fragment == nil })
    }

    func testViewerUsesExactResolvedWSHostPortAndShortBearer() async throws {
        let capture = RequestCapture()
        let client = makeClient(capture: capture)

        let session = try await client.createLiveSession(endpoint: endpoint, bridgeToken: token)

        XCTAssertEqual(session.viewerRequest.url?.absoluteString, "ws://192.168.8.20:8080/ws/video/lan/viewer?session=session-1")
        XCTAssertEqual(session.viewerRequest.value(forHTTPHeaderField: "Authorization"), "Bearer viewer-short-token")
        XCTAssertFalse(session.viewerRequest.url!.absoluteString.contains("viewer-short-token"))
    }

    func testRejectsRedirectAndNeverFollowsIt() async {
        let capture = RequestCapture()
        let client = CameraLanClient(http: { request in
            capture.append(request)
            return Self.response(request, status: 302, body: Data(), headers: ["Location": "http://192.168.8.21:8081/api/capabilities"])
        }, nowMilliseconds: { 1_000 })

        await XCTAssertThrowsErrorAsync {
            _ = try await client.createLiveSession(endpoint: endpoint, bridgeToken: token)
        }
        XCTAssertEqual(capture.requests.count, 1)
    }

    func testLANWebSocketRedirectCallbackRejectsRedirect() {
        XCTFail("LAN WebSocket handshake still uses the redirect-following shared session")
    }

    func testDiscoveryPreservesScopedLinkLocalIPv6Host() {
        XCTFail("LAN discovery currently strips the IPv6 scope identifier")
    }

    func testChallengeInt64ExtremesFailWithoutTrapOrSessionRequest() async {
        for expiresAt in [Int64.max, Int64.min] {
            let capture = RequestCapture()
            let client = CameraLanClient(http: { request in
                capture.append(request)
                if request.url?.path == "/api/capabilities" {
                    return Self.response(request, status: 200, body: Self.capabilities)
                }
                return Self.response(request, status: 200, body: Self.challenge(expiresAt: expiresAt, serverProof: self.serverProof))
            }, nowMilliseconds: { 1_000 })

            await XCTAssertThrowsErrorAsync {
                _ = try await client.createLiveSession(endpoint: endpoint, bridgeToken: token)
            }
            XCTAssertEqual(capture.requests.map(\.url?.path), ["/api/capabilities", "/api/video/lan/challenge"])
        }
    }

    func testCancellationBeforeChallengeCompletionSendsNoSessionRequest() async {
        let capture = RequestCapture()
        let gate = AsyncGate()
        let client = CameraLanClient(http: { request in
            capture.append(request)
            switch request.url?.path {
            case "/api/capabilities":
                return Self.response(request, status: 200, body: Self.capabilities)
            case "/api/video/lan/challenge":
                await gate.wait()
                return Self.response(request, status: 200, body: Self.challenge(serverProof: self.serverProof))
            default:
                return Self.response(request, status: 201, body: Self.session(viewerPath: "/ws/video/lan/viewer?session=session-1"))
            }
        }, nowMilliseconds: { 1_000 })

        let task = Task { try await client.createLiveSession(endpoint: endpoint, bridgeToken: token) }
        await capture.waitForRequests(2)
        task.cancel()
        gate.open()
        _ = try? await task.value

        XCTAssertEqual(capture.requests.map(\.url?.path), ["/api/capabilities", "/api/video/lan/challenge"])
    }

    func testCancellationAfterServerCreatesSessionRevokesIt() async {
        let capture = RequestCapture()
        let gate = AsyncGate()
        let client = CameraLanClient(http: { request in
            capture.append(request)
            switch (request.httpMethod, request.url?.path) {
            case (_, "/api/capabilities"):
                return Self.response(request, status: 200, body: Self.capabilities)
            case (_, "/api/video/lan/challenge"):
                return Self.response(request, status: 200, body: Self.challenge(serverProof: self.serverProof))
            case ("POST", "/api/video/lan/session"):
                await gate.wait()
                return Self.response(request, status: 201, body: Self.session(viewerPath: "/ws/video/lan/viewer?session=session-1"))
            default:
                return Self.response(request, status: 200, body: Data("{\"ok\":true}".utf8))
            }
        }, nowMilliseconds: { 1_000 })

        let task = Task { try await client.createLiveSession(endpoint: endpoint, bridgeToken: token) }
        await capture.waitForRequests(3)
        task.cancel()
        gate.open()
        await XCTAssertThrowsErrorAsync { _ = try await task.value }

        XCTAssertEqual(capture.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }, [
            "GET /api/capabilities",
            "POST /api/video/lan/challenge",
            "POST /api/video/lan/session",
            "DELETE /api/video/lan/session/session-1",
        ])
    }

    func testGlobalAndScopedIPv6PreserveExactAuthority() async throws {
        for (host, encodedHost) in [
            ("2001:db8::1", "2001:db8::1"),
            ("fe80::1%en0", "fe80::1%25en0"),
        ] {
            let capture = RequestCapture()
            let ipv6Endpoint = CameraLanEndpoint(host: host, port: 8080)
            let client = makeClient(capture: capture)

            let session = try await client.createLiveSession(endpoint: ipv6Endpoint, bridgeToken: token)

            XCTAssertTrue(capture.requests.allSatisfy { $0.url?.absoluteString.hasPrefix("http://[\(encodedHost)]:8080/") == true })
            XCTAssertEqual(session.viewerRequest.url?.absoluteString, "ws://[\(encodedHost)]:8080/ws/video/lan/viewer?session=session-1")
        }
    }

    func testRejectsAbsoluteUserInfoFragmentAlternateHostAndPortViewerPaths() async {
        let badPaths = [
            "ws://192.168.8.20:8080/ws/video/lan/viewer?session=session-1",
            "//user@192.168.8.20:8080/ws/video/lan/viewer?session=session-1",
            "/ws/video/lan/viewer?session=session-1#fragment",
            "//192.168.8.21:8080/ws/video/lan/viewer?session=session-1",
            "//192.168.8.20:8081/ws/video/lan/viewer?session=session-1",
        ]
        for badPath in badPaths {
            let client = makeClient(capture: RequestCapture(), viewerPath: badPath)
            await XCTAssertThrowsErrorAsync {
                _ = try await client.createLiveSession(endpoint: endpoint, bridgeToken: token)
            }
        }
    }

    private func makeClient(capture: RequestCapture, viewerPath: String = "/ws/video/lan/viewer?session=session-1") -> CameraLanClient {
        return CameraLanClient(http: { request in
            capture.append(request)
            switch request.url?.path {
            case "/api/capabilities": return Self.response(request, status: 200, body: Self.capabilities)
            case "/api/video/lan/challenge": return Self.response(request, status: 200, body: Self.challenge(serverProof: self.serverProof))
            default: return Self.response(request, status: 201, body: Self.session(viewerPath: viewerPath))
            }
        }, nowMilliseconds: { 1_000 })
    }

    @MainActor
    private final class RequestCapture {
        var requests: [URLRequest] = []
        private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

        func waitForRequests(_ count: Int) async {
            if requests.count >= count { return }
            await withCheckedContinuation { waiters.append((count, $0)) }
        }

        func append(_ request: URLRequest) {
            requests.append(request)
            let ready = waiters.filter { requests.count >= $0.0 }
            waiters.removeAll { requests.count >= $0.0 }
            ready.forEach { $0.1.resume() }
        }
    }

    @MainActor
    private final class AsyncGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }

    private static let capabilities = Data("{\"cameraLiveLan\":1,\"cameraDownloadLan\":1,\"hvcVersion\":1,\"hvtVersion\":1}".utf8)
    private static func challenge(expiresAt: Int64 = 31_000, serverProof: String) -> Data {
        Data("{\"deviceId\":\"car-1\",\"nonce\":\"000102030405060708090a0b0c0d0e0f\",\"expiresAt\":\(expiresAt),\"serverProof\":\"\(serverProof)\"}".utf8)
    }
    private static func session(viewerPath: String) -> Data {
        Data("{\"sessionId\":\"session-1\",\"expiresAt\":301000,\"scope\":\"live\",\"viewerToken\":\"viewer-short-token\",\"controlToken\":\"control-short-token\",\"viewerPath\":\"\(viewerPath)\"}".utf8)
    }
    private static func response(_ request: URLRequest, status: Int, body: Data, headers: [String: String]? = nil) -> (Data, HTTPURLResponse) {
        (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch { }
}
#else
final class CameraLanClientTests: XCTestCase {
    func testTask7LANClientIsNotImplementedYet() {
        XCTFail("Task 7 LAN client is not implemented")
    }
}
#endif
