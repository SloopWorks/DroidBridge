import Foundation
import VideoToolbox
import CoreImage
import CoreMedia
import DroidBridgeCore

/// Hardware-accelerated decoding of Android MediaCodec Annex-B access units.
/// Called only from one session's video queue; output is converted to a CGImage
/// before leaving that queue, so no pixel buffer escapes its lifetime.
final class H264Decoder {
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var sps: Data?
    private var pps: Data?
    private let context = CIContext(options: [.cacheIntermediates: false])
    var output: ((CGImage) -> Void)?
    var onDecodeError: ((OSStatus) -> Void)?
    deinit { finish() }
    func finish() {
        if let session { VTDecompressionSessionWaitForAsynchronousFrames(session); VTDecompressionSessionInvalidate(session) }
        session = nil
    }
    /// VideoToolbox may report an output error through its callback even when
    /// submitting the sample returned noErr. Preserve that diagnostic while
    /// allowing a later valid frame to recover, as before.
    func handleDecodedOutput(status: OSStatus, buffer: CVImageBuffer?) {
        guard status == noErr else { onDecodeError?(status); return }
        guard let buffer else { return }
        let ci = CIImage(cvPixelBuffer: buffer)
        if let image = context.createCGImage(ci, from: ci.extent) { output?(image) }
    }
    static func nalUnits(_ data: Data) -> [Data] {
        let bytes = [UInt8](data); var starts: [(Int,Int)] = []; var i = 0
        while i+2 < bytes.count {
            if bytes[i] == 0 && bytes[i+1] == 0 {
                if bytes[i+2] == 1 { starts.append((i,3)); i += 3; continue }
                if i+3 < bytes.count && bytes[i+2] == 0 && bytes[i+3] == 1 { starts.append((i,4)); i += 4; continue }
            }; i += 1
        }
        return starts.enumerated().compactMap { index,start in
            let end = index+1 < starts.count ? starts[index+1].0 : bytes.count
            return start.0+start.1 < end ? Data(bytes[(start.0+start.1)..<end]) : nil
        }
    }
    func decode(_ packet: Data, pts: UInt64) throws {
        let units = Self.nalUnits(packet); var avcc = Data(); var changed = false
        for unit in units {
            guard let first = unit.first else { continue }
            switch first & 31 {
            case 7: if sps != unit { sps = unit; changed = true }
            case 8: if pps != unit { pps = unit; changed = true }
            default: avcc.be(UInt32(unit.count)); avcc.append(unit)
            }
        }
        if changed, let sps, let pps {
            finish()
            var status: OSStatus = -1
            sps.withUnsafeBytes { s in pps.withUnsafeBytes { p in
                let pointers = [s.bindMemory(to: UInt8.self).baseAddress!,p.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count,pps.count]
                status = CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers, parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            } }
            guard status == noErr, let format else { throw BridgeError.message("Invalid H.264 configuration (\(status))") }
            var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { ref,_,status,_,buffer,_,_ in
                guard let ref else { return }
                let decoder = Unmanaged<H264Decoder>.fromOpaque(ref).takeUnretainedValue()
                decoder.handleDecodedOutput(status: status, buffer: buffer)
            }, decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
            let attrs: [CFString:Any] = [kCVPixelBufferPixelFormatTypeKey:kCVPixelFormatType_32BGRA,kCVPixelBufferIOSurfacePropertiesKey:[:]]
            status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil, imageBufferAttributes: attrs as CFDictionary, outputCallback: &callback, decompressionSessionOut: &session)
            guard status == noErr else { throw BridgeError.message("VideoToolbox decoder failed (\(status))") }
        }
        guard !avcc.isEmpty, let session, let format else { return }
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &block)
        guard status == noErr, let block else { throw BridgeError.message("Video buffer allocation failed") }
        avcc.withUnsafeBytes { if let base = $0.baseAddress { status = CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count) } }
        guard status == noErr else { throw BridgeError.message("Video buffer copy failed") }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: Int64(pts), timescale: 1_000_000), decodeTimeStamp: .invalid)
        var size = avcc.count; var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw BridgeError.message("Video sample creation failed") }
        status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], frameRefcon: nil, infoFlagsOut: nil)
        guard status == noErr else { throw BridgeError.message("H.264 decode failed (\(status))") }
    }
}
