import Foundation
import XCTest

final class CarCamWHEPClientTests: XCTestCase {
    private let token = "synthetic-carcam-token"

    func testFixedConfigurationUsesGalaxyTailnetEndpointAndObservedPin() throws {
        let configuration = try CarCamBridgeConfiguration.fixed(token: token)

        XCTAssertEqual(configuration.baseURL.absoluteString, "https://100.105.51.56:8443")
        XCTAssertEqual(configuration.bearerToken, token)
        XCTAssertEqual(configuration.spkiSHA256,
                       "sha256/xrgHHco8oU6hgRpPvXv2qflSUKzUkmXmi/uQKl+evxA=")
        XCTAssertThrowsError(try CarCamBridgeConfiguration.fixed(token: ""))
    }

    func testP256SPKIEncodingMatchesTheObservedGalaxyCertificate() throws {
        let rawKey = try XCTUnwrap(Data(hex:
            "04871baa03a58361ebbd315f19b55ecaf05e1c724318cc295e891e327a265e4d" +
            "6da1f697466a3f43f7c015fd805d8a2bccf9b0864b460aebfa2623d054a763dab4"))

        XCTAssertEqual(try CarCamSPKI.p256Pin(rawPublicKey: rawKey),
                       "sha256/xrgHHco8oU6hgRpPvXv2qflSUKzUkmXmi/uQKl+evxA=")
        XCTAssertThrowsError(try CarCamSPKI.p256Pin(rawPublicKey: Data(repeating: 0, count: 64)))
    }

    func testValidCreatedSessionRequiresSDPAndSameHostHTTPSLocation() throws {
        let configuration = try CarCamBridgeConfiguration.fixed(token: token)
        let response = HTTPURLResponse(
            url: configuration.baseURL.appendingPathComponent("api/v1/live/whep"),
            statusCode: 201,
            httpVersion: nil,
            headerFields: [
                "Content-Type": "application/sdp",
                "Location": "https://100.105.51.56:8443/api/v1/live/sessions/session-1",
            ]
        )!

        let session = try CarCamWHEPClient.validateCreatedSession(
            response: response, body: Data("v=0\r\n".utf8), configuration: configuration)

        XCTAssertEqual(session.answerSDP, "v=0\r\n")
        XCTAssertEqual(session.location.absoluteString,
                       "https://100.105.51.56:8443/api/v1/live/sessions/session-1")
    }

    func testCreatedSessionRejectsRedirectWrongMimeEmptySDPAndForeignLocation() throws {
        let configuration = try CarCamBridgeConfiguration.fixed(token: token)
        let endpoint = configuration.baseURL.appendingPathComponent("api/v1/live/whep")
        let cases: [(Int, [String: String], Data)] = [
            (302, ["Location": "https://100.105.51.56:8443/other"], Data("v=0".utf8)),
            (201, ["Content-Type": "text/plain", "Location": "https://100.105.51.56:8443/api/v1/live/sessions/a"], Data("v=0".utf8)),
            (201, ["Content-Type": "application/sdp", "Location": "https://100.105.51.56:8443/api/v1/live/sessions/a"], Data()),
            (201, ["Content-Type": "application/sdp", "Location": "https://100.105.51.57:8443/api/v1/live/sessions/a"], Data("v=0".utf8)),
            (201, ["Content-Type": "application/sdp", "Location": "http://100.105.51.56:8443/api/v1/live/sessions/a"], Data("v=0".utf8)),
        ]

        for (status, headers, body) in cases {
            let response = HTTPURLResponse(url: endpoint, statusCode: status,
                                           httpVersion: nil, headerFields: headers)!
            XCTAssertThrowsError(try CarCamWHEPClient.validateCreatedSession(
                response: response, body: body, configuration: configuration))
        }
    }

    func testStableHTTPStatusesMapToDistinctErrors() throws {
        let expected: [(Int, CarCamViewerError)] = [
            (401, .unauthorized), (409, .viewerExists), (413, .bodyTooLarge),
            (415, .unsupportedMediaType), (422, .invalidSDP), (500, .teardownFailed),
            (502, .mediaSetupFailed), (503, .tailscaleUnavailable), (504, .setupTimeout),
        ]

        for (status, error) in expected {
            XCTAssertEqual(CarCamWHEPClient.error(forHTTPStatus: status), error)
        }
        XCTAssertEqual(CarCamWHEPClient.error(forHTTPStatus: 418), .invalidResponse)
    }

    func testRedirectPolicyAlwaysRejects() {
        XCTAssertFalse(CarCamWHEPClient.shouldFollowRedirect)
    }
}

private extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var value = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            value.append(byte)
            index = next
        }
        self = value
    }
}
