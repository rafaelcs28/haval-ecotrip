import CryptoKit
import Foundation
import Security

struct CarCamBridgeConfiguration: Equatable, Sendable {
    let baseURL: URL
    let bearerToken: String
    let spkiSHA256: String

    static func fixed(token: String) throws -> Self {
        guard !token.isEmpty else { throw CarCamViewerError.credentialUnavailable }
        return Self(
            baseURL: URL(string: "https://100.105.51.56:8443")!,
            bearerToken: token,
            spkiSHA256: "sha256/xrgHHco8oU6hgRpPvXv2qflSUKzUkmXmi/uQKl+evxA="
        )
    }
}

enum CarCamViewerError: Error, Equatable {
    case credentialUnavailable
    case invalidResponse
    case invalidLocation
    case tlsPinMismatch
    case peerConnectionFailed
    case unauthorized
    case viewerExists
    case bodyTooLarge
    case unsupportedMediaType
    case invalidSDP
    case mediaRequired
    case teardownFailed
    case mediaSetupFailed
    case tailscaleUnavailable
    case setupTimeout
}

enum CarCamSPKI {
    private static let p256Header = Data([
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d,
        0x02, 0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01,
        0x07, 0x03, 0x42, 0x00,
    ])

    static func p256Pin(rawPublicKey: Data) throws -> String {
        guard rawPublicKey.count == 65, rawPublicKey.first == 0x04 else {
            throw CarCamViewerError.tlsPinMismatch
        }
        let digest = SHA256.hash(data: p256Header + rawPublicKey)
        return "sha256/" + Data(digest).base64EncodedString()
    }

    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        let left = Data(lhs.utf8)
        let right = Data(rhs.utf8)
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

struct CarCamCredentialStore {
    private static let service = "br.com.consorciolimpagyn.havalecotrip.carcam"
    private static let account = "bridge-bearer"

    static func synchronize(currentToken: String) throws -> String {
        guard !currentToken.isEmpty else { throw CarCamViewerError.credentialUnavailable }
        let tokenData = Data(currentToken.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: tokenData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw CarCamViewerError.credentialUnavailable
            }
        } else if status != errSecSuccess {
            throw CarCamViewerError.credentialUnavailable
        }
        return currentToken
    }
}
