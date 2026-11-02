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
            return .configuration(resetDecoder: resetPending)

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
