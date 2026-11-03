import CryptoKit
import Foundation

struct CameraVideoPacket: Equatable, Sendable {
    enum Payload: Equatable, Sendable {
        case configuration(sps: Data, pps: Data)
        case accessUnit(avcc: Data, keyframe: Bool)
    }

    let sequence: UInt32
    let presentationTimeUs: UInt64
    let payload: Payload
}

enum CameraVideoProtocol {
    static let headerSize = 24
    static let maximumPayloadSize = 4 * 1_024 * 1_024

    enum ParseError: Error, Equatable {
        case invalidLength
        case invalidHeader
        case invalidType
        case invalidFlags
        case invalidPayload
    }

    static func parse(_ data: Data) throws -> CameraVideoPacket {
        guard data.count >= headerSize, data.count <= headerSize + maximumPayloadSize else {
            throw ParseError.invalidLength
        }
        guard Data(data[0..<4]) == Data("HVC1".utf8), data[4] == 1 else {
            throw ParseError.invalidHeader
        }

        let type = data[5]
        let flags = readUInt16(data, at: 6)
        let sequence = readUInt32(data, at: 8)
        let pts = readUInt64(data, at: 12)
        let payloadLength = Int(readUInt32(data, at: 20))
        guard payloadLength > 0, payloadLength <= maximumPayloadSize,
              data.count == headerSize + payloadLength else {
            throw ParseError.invalidLength
        }

        switch type {
        case 1:
            guard flags == 0 else { throw ParseError.invalidFlags }
            let (sps, pps) = try parseConfiguration(data)
            return CameraVideoPacket(sequence: sequence, presentationTimeUs: pts, payload: .configuration(sps: sps, pps: pps))
        case 2:
            guard flags & ~UInt16(1) == 0 else { throw ParseError.invalidFlags }
            let avcc = try parseAccessUnit(data)
            return CameraVideoPacket(sequence: sequence, presentationTimeUs: pts, payload: .accessUnit(avcc: avcc, keyframe: flags == 1))
        default:
            throw ParseError.invalidType
        }
    }

    private static func parseConfiguration(_ data: Data) throws -> (Data, Data) {
        var offset = headerSize
        guard offset + 2 <= data.count else { throw ParseError.invalidPayload }
        let spsLength = Int(readUInt16(data, at: offset)); offset += 2
        guard spsLength > 0, offset + spsLength + 2 <= data.count else { throw ParseError.invalidPayload }
        let sps = Data(data[offset..<(offset + spsLength)]); offset += spsLength
        let ppsLength = Int(readUInt16(data, at: offset)); offset += 2
        guard ppsLength > 0, offset + ppsLength == data.count else { throw ParseError.invalidPayload }
        return (sps, Data(data[offset..<data.count]))
    }

    private static func parseAccessUnit(_ data: Data) throws -> Data {
        var offset = headerSize
        var count = 0
        while offset < data.count {
            guard offset + 4 <= data.count else { throw ParseError.invalidPayload }
            let length = Int(readUInt32(data, at: offset)); offset += 4
            guard length > 0, offset + length <= data.count else { throw ParseError.invalidPayload }
            offset += length
            count += 1
        }
        guard count > 0, offset == data.count else { throw ParseError.invalidPayload }
        return Data(data[headerSize..<data.count])
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { ($0 << 8) | UInt32(data[offset + $1]) }
    }

    private static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        (0..<8).reduce(0) { ($0 << 8) | UInt64(data[offset + $1]) }
    }
}

struct CameraTransferMessage: Equatable, Sendable {
    enum MessageType: UInt8, Equatable, Sendable { case data = 1, eof = 2, ack = 3, error = 4 }

    let type: MessageType
    let ordinal: UInt32
    let offset: UInt64
    let payload: Data
    let sha256: Data

    var errorText: String? { type == .error ? String(data: payload, encoding: .utf8) : nil }
}

enum CameraTransferProtocol {
    static let headerSize = 56
    static let maximumDataSize = 262_144
    static let maximumErrorSize = 1_024

    enum ParseError: Error, Equatable {
        case invalidLength, invalidHeader, invalidType, invalidFlags, invalidFields, invalidDigest, invalidUTF8
    }

    static func parse(_ encoded: Data) throws -> CameraTransferMessage {
        guard encoded.count >= headerSize else { throw ParseError.invalidLength }
        guard Data(encoded[0..<4]) == Data("HVT1".utf8), encoded[4] == 1 else { throw ParseError.invalidHeader }
        guard let type = CameraTransferMessage.MessageType(rawValue: encoded[5]) else { throw ParseError.invalidType }
        guard readUInt16(encoded, at: 6) == 0 else { throw ParseError.invalidFlags }
        let ordinal = readUInt32(encoded, at: 8)
        let offset = readUInt64(encoded, at: 12)
        let payloadLength = UInt64(readUInt32(encoded, at: 20))
        guard payloadLength <= UInt64(Int.max), encoded.count == headerSize + Int(payloadLength) else {
            throw ParseError.invalidLength
        }
        let digest = Data(encoded[24..<56])
        let payload = Data(encoded[56..<encoded.count])

        switch type {
        case .data:
            guard payloadLength >= 1, payloadLength <= UInt64(maximumDataSize),
                  offset <= UInt64.max - payloadLength else { throw ParseError.invalidFields }
            guard digest == Data(SHA256.hash(data: payload)) else { throw ParseError.invalidDigest }
        case .eof:
            guard payload.isEmpty else { throw ParseError.invalidFields }
        case .ack:
            guard payload.isEmpty, digest == Data(repeating: 0, count: 32) else { throw ParseError.invalidFields }
        case .error:
            guard offset == 0, payloadLength >= 1, payloadLength <= UInt64(maximumErrorSize) else {
                throw ParseError.invalidFields
            }
            guard digest == Data(SHA256.hash(data: payload)) else { throw ParseError.invalidDigest }
            guard String(data: payload, encoding: .utf8) != nil else { throw ParseError.invalidUTF8 }
        }
        return CameraTransferMessage(type: type, ordinal: ordinal, offset: offset, payload: payload, sha256: digest)
    }

    static func data(ordinal: UInt32, offset: UInt64, payload: Data) throws -> Data {
        guard !payload.isEmpty, payload.count <= maximumDataSize,
              offset <= UInt64.max - UInt64(payload.count) else { throw ParseError.invalidFields }
        return encode(type: .data, ordinal: ordinal, offset: offset, payload: payload,
                      digest: Data(SHA256.hash(data: payload)))
    }

    static func eof(ordinal: UInt32, totalBytes: UInt64, digest: Data) throws -> Data {
        guard digest.count == 32 else { throw ParseError.invalidDigest }
        return encode(type: .eof, ordinal: ordinal, offset: totalBytes, payload: Data(), digest: digest)
    }

    static func ack(ordinal: UInt32, nextOffset: UInt64) -> Data {
        encode(type: .ack, ordinal: ordinal, offset: nextOffset, payload: Data(),
               digest: Data(repeating: 0, count: 32))
    }

    static func error(ordinal: UInt32, message: String) throws -> Data {
        guard let payload = message.data(using: .utf8), !payload.isEmpty, payload.count <= maximumErrorSize,
              String(data: payload, encoding: .utf8) == message else { throw ParseError.invalidUTF8 }
        return encode(type: .error, ordinal: ordinal, offset: 0, payload: payload,
                      digest: Data(SHA256.hash(data: payload)))
    }

    private static func encode(type: CameraTransferMessage.MessageType, ordinal: UInt32, offset: UInt64,
                               payload: Data, digest: Data) -> Data {
        var result = Data("HVT1".utf8)
        result.append(1); result.append(type.rawValue); result.appendBE(UInt16(0))
        result.appendBE(ordinal); result.appendBE(offset); result.appendBE(UInt32(payload.count))
        result.append(digest); result.append(payload)
        return result
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { ($0 << 8) | UInt32(data[offset + $1]) }
    }

    private static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        (0..<8).reduce(0) { ($0 << 8) | UInt64(data[offset + $1]) }
    }
}

private extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }
}

struct CameraVideoStreamState {
    enum Decision: Equatable {
        case configuration(resetDecoder: Bool)
        case accessUnit(resetDecoder: Bool)
        case waitingForKeyframe
    }

    enum StreamError: Error { case missingConfiguration }

    private var lastSequence: UInt32?
    private var configuration: (sps: Data, pps: Data)?
    private var waitingForKeyframe = true
    private var resetPending = true

    mutating func accept(_ packet: CameraVideoPacket) throws -> Decision {
        if let lastSequence, packet.sequence != lastSequence &+ 1 {
            waitingForKeyframe = true
            resetPending = true
        }
        lastSequence = packet.sequence

        switch packet.payload {
        case .configuration(let sps, let pps):
            let changed = configuration?.sps != sps || configuration?.pps != pps
            configuration = (sps, pps)
            waitingForKeyframe = true
            resetPending = resetPending || changed
            let reset = resetPending
            resetPending = false
            return .configuration(resetDecoder: reset)

        case .accessUnit(_, let keyframe):
            guard configuration != nil else { throw StreamError.missingConfiguration }
            if waitingForKeyframe && !keyframe { return .waitingForKeyframe }
            let reset = resetPending
            waitingForKeyframe = false
            resetPending = false
            return .accessUnit(resetDecoder: reset)
        }
    }

    mutating func requireKeyframe() {
        waitingForKeyframe = true
        resetPending = true
    }
}
