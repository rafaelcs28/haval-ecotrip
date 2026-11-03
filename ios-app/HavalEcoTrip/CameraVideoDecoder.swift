import AVFoundation
import Foundation

@MainActor
protocol CameraVideoRendering: AnyObject {
    func consume(_ packet: CameraVideoPacket) throws -> Bool
    func clear()
    func setFailureHandler(_ handler: @escaping () -> Void)
}

@MainActor
final class CameraVideoDecoder: CameraVideoRendering {
    enum DecoderError: Error { case invalidConfiguration, blockBuffer(OSStatus), sampleBuffer(OSStatus) }

    let displayLayer = AVSampleBufferDisplayLayer()
    private var stream = CameraVideoStreamState()
    private var formatDescription: CMVideoFormatDescription?
    private let failureHandler = FailureHandlerStore()
    private var statusObservation: NSKeyValueObservation?
    private var failureReported = false

    init() {
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        let failureHandler = failureHandler
        statusObservation = displayLayer.observe(\.status, options: [.new]) { [weak self] layer, _ in
            guard layer.status == .failed else { return }
            let handler = failureHandler.snapshot()
            Task { @MainActor [weak self] in self?.reportDisplayFailure(to: handler) }
        }
    }

    func consume(_ packet: CameraVideoPacket) throws -> Bool {
        let decision = try stream.accept(packet)
        switch packet.payload {
        case .configuration(let sps, let pps):
            if case .configuration(let reset) = decision, reset { displayLayer.flushAndRemoveImage() }
            formatDescription = try Self.makeFormatDescription(sps: sps, pps: pps)
            failureReported = false
            return false

        case .accessUnit(let avcc, _):
            guard case .accessUnit(let reset) = decision else { return false }
            guard let formatDescription else { throw DecoderError.invalidConfiguration }
            if reset { displayLayer.flushAndRemoveImage() }
            failureReported = false
            displayLayer.enqueue(try Self.makeSample(avcc: avcc, pts: packet.presentationTimeUs, format: formatDescription))
            return true
        }
    }

    func clear() {
        stream.requireKeyframe()
        displayLayer.flushAndRemoveImage()
    }

    func setFailureHandler(_ handler: @escaping () -> Void) {
        failureHandler.replace(with: handler)
    }

    var handleDisplayFailure: () -> Void {
        let handler = failureHandler.snapshot()
        return { [weak self] in self?.reportDisplayFailure(to: handler) }
    }

    private func reportDisplayFailure(to handler: (() -> Void)?) {
        guard !failureReported else { return }
        failureReported = true
        clear()
        handler?()
    }

    static func makeFormatDescription(sps: Data, pps: Data) throws -> CMVideoFormatDescription {
        var description: CMFormatDescription?
        let status: OSStatus = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                guard let spsBase = spsBytes.bindMemory(to: UInt8.self).baseAddress,
                      let ppsBase = ppsBytes.bindMemory(to: UInt8.self).baseAddress else {
                    return kCMFormatDescriptionError_InvalidParameter
                }
                var pointers = [spsBase, ppsBase]
                var sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: &pointers,
                    parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description
                )
            }
        }
        guard status == noErr, let description else {
            throw DecoderError.invalidConfiguration
        }
        return description
    }

    static func makeSample(avcc: Data, pts: UInt64, format: CMVideoFormatDescription) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: 0,
            blockBufferOut: &block
        )
        guard status == kCMBlockBufferNoErr, let block else { throw DecoderError.blockBuffer(status) }
        status = avcc.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard status == kCMBlockBufferNoErr else { throw DecoderError.blockBuffer(status) }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: Int64(clamping: pts), timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = avcc.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample
        )
        guard status == noErr, let sample else { throw DecoderError.sampleBuffer(status) }
        CMSetAttachment(
            sample,
            key: kCMSampleAttachmentKey_DisplayImmediately,
            value: kCFBooleanTrue,
            attachmentMode: kCMAttachmentMode_ShouldPropagate
        )
        return sample
    }
}

private final class FailureHandlerStore: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (() -> Void)?

    func replace(with handler: @escaping () -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func snapshot() -> (() -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return handler
    }
}
