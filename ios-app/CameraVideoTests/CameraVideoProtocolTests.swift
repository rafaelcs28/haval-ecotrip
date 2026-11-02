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
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }
}
