import ChiakiKit
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public struct FrameStats: Sendable, Equatable {
    public var size: Int
    public var framesLost: Int32
    public var recovered: Bool
    public var decodeOK: Bool
    public var decodeMilliseconds: Double

    public init(size: Int, framesLost: Int32, recovered: Bool, decodeOK: Bool, decodeMilliseconds: Double) {
        self.size = size
        self.framesLost = framesLost
        self.recovered = recovered
        self.decodeOK = decodeOK
        self.decodeMilliseconds = decodeMilliseconds
    }
}

public enum VideoDecoderError: Error, Sendable, Equatable {
    /// The parameter sets were rejected or no hardware HEVC decoder session could be created.
    case setupFailed(OSStatus)
}

/// Output of one synchronous decode; written by VideoToolbox's output handler before DecodeFrame returns.
private final class DecodeResult: @unchecked Sendable {
    var status: OSStatus = noErr
    var image: CVPixelBuffer?
}

/// Decodes libchiaki's H.265 buffers synchronously on the calling (libchiaki video) thread and
/// returns the real result (spec §4.1). Hardware decoding is required; there is no software fallback.
public final class VideoDecoder: VideoSink, @unchecked Sendable {
    private let onFrame: @Sendable (FrameStats) -> Void
    private let onImage: @Sendable (CVPixelBuffer) -> Void
    private let onError: @Sendable (VideoDecoderError) -> Void
    private let lock = NSLock()
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var parameterSets: [Data] = []
    private var reportedFailureSets: [Data]?
    private var lastCreateStatus: OSStatus = noErr

    public init(onFrame: @escaping @Sendable (FrameStats) -> Void = { _ in },
                onImage: @escaping @Sendable (CVPixelBuffer) -> Void = { _ in },
                onError: @escaping @Sendable (VideoDecoderError) -> Void = { _ in }) {
        self.onFrame = onFrame
        self.onImage = onImage
        self.onError = onError
    }

    /// Test seam: kills the current VideoToolbox session the way a GPU reset would.
    func invalidateSessionForTesting() {
        lock.withLock { if let session { VTDecompressionSessionInvalidate(session) } }
    }

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    public var dimensions: CMVideoDimensions? {
        lock.withLock { format.map(CMVideoFormatDescriptionGetDimensions) }
    }

    public func consume(_ buffer: UnsafeRawBufferPointer, framesLost: Int32, recovered: Bool) -> Bool {
        let units = HEVCAnnexB.units(in: buffer)
        return lock.withLock {
            if let sets = HEVCAnnexB.parameterSets(in: units) {
                guard updateSession(vps: sets.vps, sps: sets.sps, pps: sets.pps) else { return false }
            }
            let sampleUnits = units.filter(HEVCAnnexB.isSampleUnit)
            if sampleUnits.isEmpty { return true }   // header-only buffer (libchiaki ignores this result)
            return decode(sampleUnits, size: buffer.count, framesLost: framesLost, recovered: recovered)
        }
    }

    // MARK: - Private (lock held)

    private func updateSession(vps: Data, sps: Data, pps: Data) -> Bool {
        let sets = [vps, sps, pps]
        if sets == parameterSets, session != nil { return true }
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        var formatStatus: OSStatus = noErr
        guard let newFormat = Self.makeFormat(sets, status: &formatStatus) else {
            format = nil
            parameterSets = []
            reportOnce(.setupFailed(formatStatus), for: sets)
            return false
        }
        format = newFormat
        parameterSets = sets
        if createSession() { return true }
        reportOnce(.setupFailed(lastCreateStatus), for: sets)
        return false
    }

    /// (Re)creates the hardware decompression session for the current format.
    private func createSession() -> Bool {
        guard let format else { return false }
        let specification = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: kCFBooleanTrue] as CFDictionary
        let attributes = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                          kCVPixelBufferIOSurfacePropertiesKey: [:]] as [CFString: Any] as CFDictionary
        var newSession: VTDecompressionSession?
        lastCreateStatus = VTDecompressionSessionCreate(allocator: nil, formatDescription: format,
                                                        decoderSpecification: specification,
                                                        imageBufferAttributes: attributes, outputCallback: nil,
                                                        decompressionSessionOut: &newSession)
        guard lastCreateStatus == noErr, let newSession else { return false }
        session = newSession
        return true
    }

    private func reportOnce(_ error: VideoDecoderError, for sets: [Data]) {
        guard reportedFailureSets != sets else { return }
        reportedFailureSets = sets
        onError(error)
    }

    private func decode(_ units: [Data], size: Int, framesLost: Int32, recovered: Bool) -> Bool {
        if session == nil, format != nil, !createSession() {
            reportOnce(.setupFailed(lastCreateStatus), for: parameterSets)
        }
        guard let session, let format, let sample = Self.makeSample(HEVCAnnexB.lengthPrefixed(units), format: format) else {
            onFrame(FrameStats(size: size, framesLost: framesLost, recovered: recovered, decodeOK: false, decodeMilliseconds: 0))
            return false
        }
        let clock = ContinuousClock()
        let start = clock.now
        let result = DecodeResult()
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [],
                                                       infoFlagsOut: nil) { frameStatus, _, image, _, _ in
            result.status = frameStatus
            result.image = image
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        let elapsed = clock.now - start
        let milliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        if status == kVTInvalidSessionErr || result.status == kVTInvalidSessionErr {
            // GPU reset / media server restart: drop the session; the next frame rebuilds it.
            VTDecompressionSessionInvalidate(session)
            self.session = nil
        }
        let decoded = result.image
        let ok = status == noErr && result.status == noErr && decoded != nil
        onFrame(FrameStats(size: size, framesLost: framesLost, recovered: recovered, decodeOK: ok, decodeMilliseconds: milliseconds))
        if ok, let decoded { onImage(decoded) }
        return ok
    }

    private static func makeFormat(_ sets: [Data], status formatStatus: inout OSStatus) -> CMVideoFormatDescription? {
        let copies = sets.map { set -> UnsafeMutablePointer<UInt8> in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            set.copyBytes(to: pointer, count: set.count)
            return pointer
        }
        defer { copies.forEach { $0.deallocate() } }
        let pointers = copies.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)
        var format: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: sets.count,
                                                                         parameterSetPointers: pointers,
                                                                         parameterSetSizes: sizes,
                                                                         nalUnitHeaderLength: 4, extensions: nil,
                                                                         formatDescriptionOut: &format)
        formatStatus = status
        return status == noErr ? format : nil
    }

    private static func makeSample(_ data: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: data.count, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
        }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        var sampleSize = data.count
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                        sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
                                        sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }
}
