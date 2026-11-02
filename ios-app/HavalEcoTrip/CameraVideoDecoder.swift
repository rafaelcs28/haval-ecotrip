import AVFoundation
import Foundation

@MainActor
protocol CameraVideoRendering: AnyObject {
    func consume(_ packet: CameraVideoPacket) throws -> Bool
    func clear()
}

@MainActor
final class CameraVideoDecoder: CameraVideoRendering {
    enum DecoderError: Error { case invalidConfiguration, blockBuffer(OSStatus), sampleBuffer(OSStatus) }

    let displayLayer = AVSampleBufferDisplayLayer()
    private var stream = CameraVideoStreamState()
    private var formatDescription: CMVideoFormatDescription?

    init() {
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    func consume(_ packet: CameraVideoPacket) throws -> Bool {
        let decision = try stream.accept(packet)
        switch packet.payload {
        case .configuration(let sps, let pps):
            if case .configuration(let reset) = decision, reset { displayLayer.flushAndRemoveImage() }
            formatDescription = try Self.makeFormatDescription(sps: sps, pps: pps)
            return false

        case .accessUnit(let avcc, _):
            guard case .accessUnit(let reset) = decision else { return false }
            guard let formatDescription else { throw DecoderError.invalidConfiguration }
            if reset { displayLayer.flushAndRemoveImage() }
            displayLayer.enqueue(try Self.makeSample(avcc: avcc, pts: packet.presentationTimeUs, format: formatDescription))
            return true
        }
    }

    func clear() {
        stream.requireKeyframe()
        displayLayer.flushAndRemoveImage()
    }

    private static func makeFormatDescription(sps: Data, pps: Data) throws -> CMVideoFormatDescription {
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
        guard status == noErr, let typed = description as? CMVideoFormatDescription else {
            throw DecoderError.invalidConfiguration
        }
        return typed
    }

    private static func makeSample(avcc: Data, pts: UInt64, format: CMVideoFormatDescription) throws -> CMSampleBuffer {
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
        return sample
    }
}
