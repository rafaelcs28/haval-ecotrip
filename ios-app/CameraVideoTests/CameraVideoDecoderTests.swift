import AVFoundation
import XCTest

@MainActor
final class CameraVideoDecoderTests: XCTestCase {
    private let sps = Data([0x67, 0x42, 0x00, 0x1f, 0xe5, 0x88, 0x68, 0x54, 0x05, 0x01, 0xed, 0x00, 0xf0, 0x88, 0x45, 0x80])
    private let pps = Data([0x68, 0xce, 0x38, 0x80])

    func testLiveSampleDisplaysImmediatelyDespiteRemotePTS() throws {
        let format = try CameraVideoDecoder.makeFormatDescription(
            sps: sps,
            pps: pps
        )
        let sample = try CameraVideoDecoder.makeSample(
            avcc: Data([0, 0, 0, 3, 0x65, 0x88, 0x84]),
            pts: 9_000_000_000,
            format: format
        )

        let immediate = CMGetAttachment(
            sample,
            key: kCMSampleAttachmentKey_DisplayImmediately,
            attachmentModeOut: nil
        )
        XCTAssertEqual(immediate as? Bool, true)
        XCTAssertTrue(CMSampleBufferGetPresentationTimeStamp(sample).isValid)
    }

    func testAsynchronousDisplayFailureNotifiesAndRequiresKeyframe() throws {
        let decoder = CameraVideoDecoder()
        var failures = 0
        decoder.setFailureHandler { failures += 1 }
        _ = try decoder.consume(try CameraVideoProtocol.parse(CameraVideoProtocolTests.config(sps: sps, pps: pps)))
        XCTAssertTrue(try decoder.consume(try CameraVideoProtocol.parse(CameraVideoProtocolTests.access())))

        decoder.handleDisplayFailure()

        XCTAssertEqual(failures, 1)
        XCTAssertFalse(try decoder.consume(try CameraVideoProtocol.parse(CameraVideoProtocolTests.access(sequence: 3, keyframe: false))))
        XCTAssertTrue(try decoder.consume(try CameraVideoProtocol.parse(CameraVideoProtocolTests.access(sequence: 4, keyframe: true))))
    }
}
