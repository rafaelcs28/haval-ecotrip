import CryptoKit
import XCTest

final class CameraVideoProtocolTests: XCTestCase {
    private let sps = Data([0x67, 0x42, 0x00, 0x1f])
    private let pps = Data([0x68, 0xce, 0x06, 0xe2])

    func testParsesBigEndianConfigAndAccessUnit() throws {
        let config = try CameraVideoProtocol.parse(Self.config(sequence: 0x01020304, pts: 0x0102030405060708))
        XCTAssertEqual(config.sequence, 0x01020304)
        XCTAssertEqual(config.presentationTimeUs, 0x0102030405060708)
        XCTAssertEqual(config.payload, .configuration(sps: sps, pps: pps))

        let access = try CameraVideoProtocol.parse(Self.access(sequence: 5, pts: 66_667, keyframe: true))
        XCTAssertEqual(access.payload, .accessUnit(avcc: Data([0, 0, 0, 3, 0x65, 0x88, 0x84]), keyframe: true))
    }

    func testRejectsWrongMagicVersionAndMalformedLengths() {
        var wrongMagic = Self.config(); wrongMagic[0] = 0
        var wrongVersion = Self.config(); wrongVersion[4] = 2
        var trailing = Self.config(); trailing.append(0)
        var truncatedSPS = Self.config(); truncatedSPS[25] = 20
        var zeroNAL = Self.access(); zeroNAL.replaceSubrange(24..<28, with: [0, 0, 0, 0])

        for value in [wrongMagic, wrongVersion, trailing, truncatedSPS, zeroNAL] {
            XCTAssertThrowsError(try CameraVideoProtocol.parse(value))
        }
    }

    func testRejectsPayloadAboveFourMiB() {
        var data = Data(repeating: 0, count: 24 + 4 * 1_024 * 1_024 + 1)
        data.replaceSubrange(0..<6, with: [0x48, 0x56, 0x43, 0x31, 1, 2])
        XCTAssertThrowsError(try CameraVideoProtocol.parse(data))
    }

    func testDiscontinuityWaitsForNextKeyframe() throws {
        var stream = CameraVideoStreamState()
        XCTAssertEqual(try stream.accept(CameraVideoProtocol.parse(Self.config(sequence: 1))), .configuration(resetDecoder: true))
        XCTAssertEqual(try stream.accept(CameraVideoProtocol.parse(Self.access(sequence: 2, keyframe: true))), .accessUnit(resetDecoder: false))
        XCTAssertEqual(try stream.accept(CameraVideoProtocol.parse(Self.access(sequence: 4, keyframe: false))), .waitingForKeyframe)
        XCTAssertEqual(try stream.accept(CameraVideoProtocol.parse(Self.access(sequence: 5, keyframe: true))), .accessUnit(resetDecoder: true))
    }

    func testConfigurationChangeResetsDecoder() throws {
        var stream = CameraVideoStreamState()
        _ = try stream.accept(CameraVideoProtocol.parse(Self.config(sequence: 1)))
        _ = try stream.accept(CameraVideoProtocol.parse(Self.access(sequence: 2, keyframe: true)))
        XCTAssertEqual(try stream.accept(CameraVideoProtocol.parse(Self.config(sequence: 3, sps: Data([0x67, 0x64])))), .configuration(resetDecoder: true))
    }

    func testMissingKeyframeIsNotDisplayed() throws {
        var stream = CameraVideoStreamState()
        _ = try stream.accept(CameraVideoProtocol.parse(Self.config(sequence: 1)))
        XCTAssertEqual(try stream.accept(CameraVideoProtocol.parse(Self.access(sequence: 2, keyframe: false))), .waitingForKeyframe)
    }

#if TASK8_IMPLEMENTED
    func testHVT1CanonicalFixturesPreserveUnsignedFieldsAndTypes() throws {
        let fixtures = [
            "485654310101000000000001000000000000000000000003ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad616263",
            "485654310102000000000001000000000000000300000000ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            "4856543101030000000000010000000000000003000000000000000000000000000000000000000000000000000000000000000000000000",
            "485654310104000000000001000000000000000000000003ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad616263",
            "4856543101030000000000018000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
            "485654310103000000000001ffffffffffffffff000000000000000000000000000000000000000000000000000000000000000000000000"
        ].map { Data(testHex: $0)! }

        let decoded = try fixtures.map(CameraTransferProtocol.parse)
        XCTAssertEqual(decoded.map(\.type), [.data, .eof, .ack, .error, .ack, .ack])
        XCTAssertEqual(decoded.map(\.ordinal), [1, 1, 1, 1, 1, 1])
        XCTAssertEqual(decoded.map(\.offset), [0, 3, 3, 0, 1 << 63, .max])
        XCTAssertEqual(decoded[0].payload, Data("abc".utf8))
        XCTAssertEqual(decoded[3].errorText, "abc")
        XCTAssertEqual(CameraTransferProtocol.ack(ordinal: 1, nextOffset: 3), fixtures[2])
    }

    func testHVT1RejectsMalformedFramingDigestAndUnknownFields() throws {
        let fixture = Data(testHex: "485654310101000000000001000000000000000000000003ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad616263")!
        var cases: [Data] = []
        var wrongLength = fixture; wrongLength[23] = 4; cases.append(wrongLength)
        var wrongDigest = fixture; wrongDigest[24] ^= 1; cases.append(wrongDigest)
        var flags = fixture; flags[7] = 1; cases.append(flags)
        var type = fixture; type[5] = 9; cases.append(type)
        var trailing = fixture; trailing.append(0); cases.append(trailing)
        for malformed in cases { XCTAssertThrowsError(try CameraTransferProtocol.parse(malformed)) }

        var overflow = fixture
        overflow.replaceSubrange(12..<20, with: Data(repeating: 0xff, count: 8))
        XCTAssertThrowsError(try CameraTransferProtocol.parse(overflow))

        let maximum = try CameraTransferProtocol.data(ordinal: .max, offset: UInt64.max - 262_144,
                                                      payload: Data(repeating: 0x5a, count: 262_144))
        XCTAssertEqual(try CameraTransferProtocol.parse(maximum).payload.count, 262_144)
        XCTAssertThrowsError(try CameraTransferProtocol.data(ordinal: 1, offset: 0,
                                                              payload: Data(repeating: 0, count: 262_145)))
    }

    func testHVT1RejectsWrongIdentityTruncationInvalidACKAndMalformedError() throws {
        let ack = Data(testHex: "4856543101030000000000010000000000000003000000000000000000000000000000000000000000000000000000000000000000000000")!
        var wrongMagic = ack; wrongMagic[0] = 0
        var wrongVersion = ack; wrongVersion[4] = 2
        var invalidACKDigest = ack; invalidACKDigest[24] = 1
        let truncated = Data(ack.dropLast())

        let validError = try CameraTransferProtocol.error(ordinal: 1, message: "abc")
        var malformedUTF8 = validError
        malformedUTF8.replaceSubrange(56..<59, with: [0xe0, 0x80, 0x80])
        let malformedDigest = Data(SHA256.hash(data: malformedUTF8[56..<59]))
        malformedUTF8.replaceSubrange(24..<56, with: malformedDigest)
        var oversizedError = Data(validError.prefix(56))
        oversizedError.replaceSubrange(20..<24, with: [0, 0, 4, 1])
        oversizedError.append(Data(repeating: 0x61, count: 1_025))
        oversizedError.replaceSubrange(24..<56, with: Data(SHA256.hash(data: oversizedError[56...])))

        for malformed in [wrongMagic, wrongVersion, invalidACKDigest, truncated, malformedUTF8, oversizedError] {
            XCTAssertThrowsError(try CameraTransferProtocol.parse(malformed))
        }
    }
#else
    func testTask8HVT1ContractIsImplemented() {
        XCTFail("Task 8 RED: HVT1 v1 Swift codec is not implemented")
    }
#endif

    static func config(
        sequence: UInt32 = 1,
        pts: UInt64 = 0,
        sps: Data = Data([0x67, 0x42, 0x00, 0x1f]),
        pps: Data = Data([0x68, 0xce, 0x06, 0xe2])
    ) -> Data {
        var payload = Data(); payload.appendBE(UInt16(sps.count)); payload.append(sps)
        payload.appendBE(UInt16(pps.count)); payload.append(pps)
        return packet(type: 1, flags: 0, sequence: sequence, pts: pts, payload: payload)
    }

    static func access(sequence: UInt32 = 2, pts: UInt64 = 66_667, keyframe: Bool = true) -> Data {
        let nal = Data([keyframe ? 0x65 : 0x41, 0x88, 0x84])
        var payload = Data(); payload.appendBE(UInt32(nal.count)); payload.append(nal)
        return packet(type: 2, flags: keyframe ? 1 : 0, sequence: sequence, pts: pts, payload: payload)
    }

    private static func packet(type: UInt8, flags: UInt16, sequence: UInt32, pts: UInt64, payload: Data) -> Data {
        var data = Data("HVC1".utf8); data.append(1); data.append(type)
        data.appendBE(flags); data.appendBE(sequence); data.appendBE(pts); data.appendBE(UInt32(payload.count)); data.append(payload)
        return data
    }
}

private extension Data {
    init?(testHex: String) {
        guard testHex.count.isMultiple(of: 2) else { return nil }
        var result = Data(); result.reserveCapacity(testHex.count / 2)
        var index = testHex.startIndex
        while index < testHex.endIndex {
            let next = testHex.index(index, offsetBy: 2)
            guard let byte = UInt8(testHex[index..<next], radix: 16) else { return nil }
            result.append(byte); index = next
        }
        self = result
    }
}

private extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }
}
