import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

struct SyntheticHEVCError: Error { let step: String; let status: OSStatus }

/// Collects encoder output delivered on VideoToolbox's thread.
final class SampleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [CMSampleBuffer] = []
    func append(_ sample: CMSampleBuffer) { lock.withLock { samples.append(sample) } }
    var all: [CMSampleBuffer] { lock.withLock { samples } }
}

/// Encodes a few synthetic frames with the hardware HEVC encoder and returns them the way libchiaki
/// delivers video: one profile header (VPS/SPS/PPS, Annex B, zero padded) followed by Annex B frames.
enum SyntheticHEVC {
    static func make(width: Int32, height: Int32, frames: Int) throws -> (header: Data, frames: [Data]) {
        var session: VTCompressionSession?
        var status = VTCompressionSessionCreate(allocator: nil, width: width, height: height,
                                                codecType: kCMVideoCodecType_HEVC, encoderSpecification: nil,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else { throw SyntheticHEVCError(step: "create", status: status) }
        defer { VTCompressionSessionInvalidate(session) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)

        let collected = SampleBox()
        for index in 0..<frames {
            let pixelBuffer = try makePixelBuffer(width: Int(width), height: Int(height), luma: UInt8(40 + index * 20 % 180))
            let properties = index == 0 ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
            status = VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer,
                                                     presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: 60),
                                                     duration: .invalid, frameProperties: properties,
                                                     infoFlagsOut: nil) { encodeStatus, _, sample in
                if encodeStatus == noErr, let sample { collected.append(sample) }
            }
            guard status == noErr else { throw SyntheticHEVCError(step: "encode", status: status) }
        }
        status = VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        guard status == noErr else { throw SyntheticHEVCError(step: "complete", status: status) }

        let encoded = collected.all
        guard let format = encoded.first.flatMap(CMSampleBufferGetFormatDescription) else {
            throw SyntheticHEVCError(step: "format", status: -1)
        }
        var header = Data()
        for index in 0..<3 {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index,
                                                                        parameterSetPointerOut: &pointer,
                                                                        parameterSetSizeOut: &size,
                                                                        parameterSetCountOut: nil,
                                                                        nalUnitHeaderLengthOut: nil)
            guard status == noErr, let pointer else { throw SyntheticHEVCError(step: "parameter set \(index)", status: status) }
            header += Data([0, 0, 0, 1]) + Data(bytes: pointer, count: size)
        }
        header += Data(count: 64)   // libchiaki pads the header buffer
        return (header, try encoded.map(annexB(from:)))
    }

    private static func annexB(from sample: CMSampleBuffer) throws -> Data {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { throw SyntheticHEVCError(step: "block", status: -1) }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        let status = CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                                 totalLengthOut: &length, dataPointerOut: &pointer)
        guard status == noErr, let pointer else { throw SyntheticHEVCError(step: "pointer", status: status) }
        let bytes = Data(bytes: pointer, count: length)
        var out = Data()
        var offset = 0
        while offset + 4 <= bytes.count {
            let size = bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            out += Data([0, 0, 0, 1]) + bytes[offset + 4..<offset + 4 + size]
            offset += 4 + size
        }
        return out
    }

    private static func makePixelBuffer(width: Int, height: Int, luma: UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw SyntheticHEVCError(step: "pixel buffer", status: status) }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!
            let bytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane)
            memset(base, Int32(plane == 0 ? luma : 128), bytes)
        }
        return buffer
    }
}
