import AVFoundation
import XCTest

@MainActor
final class CameraVideoDecoderTests: XCTestCase {
    func testLiveSampleDisplaysImmediatelyDespiteRemotePTS() throws {
        let format = try CameraVideoDecoder.makeFormatDescription(
            sps: Data([0x67, 0x42, 0x00, 0x1f]),
            pps: Data([0x68, 0xce, 0x06, 0xe2])
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
        _ = try decoder.consume(try CameraVideoProtocol.parse(CameraVideoProtocolTests.config()))
        XCTAssertTrue(try decoder.consume(try CameraVideoProtocol.parse(CameraVideoProtocolTests.access())))

        decoder.handleDisplayFailure()

        XCTAssertEqual(failures, 1)
        XCTAssertFalse(try decoder.consume(try CameraVideoProtocol.parse(CameraVideoProtocolTests.access(sequence: 3, keyframe: false))))
        XCTAssertTrue(try decoder.consume(try CameraVideoProtocol.parse(CameraVideoProtocolTests.access(sequence: 4, keyframe: true))))
    }
}
