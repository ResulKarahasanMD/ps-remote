import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// CMSampleBuffer is an immutable CF object once created; it is handed to one queue and never mutated.
private final class SampleBox: @unchecked Sendable {
    let sample: CMSampleBuffer
    init(_ sample: CMSampleBuffer) { self.sample = sample }
}

/// Shows decoded frames as soon as they arrive (no timing): CVPixelBuffer → CMSampleBuffer with
/// DisplayImmediately → the layer's sample buffer renderer, on a private serial queue.
public final class VideoRenderer: @unchecked Sendable {
    /// Main-actor UI object; add it to a view on the main actor.
    public let layer: AVSampleBufferDisplayLayer
    /// The layer's renderer, taken once on the main actor; it is enqueued from `queue`.
    private let videoRenderer: AVSampleBufferVideoRenderer
    private let queue = DispatchQueue(label: "psremote.video-renderer")
    private let lock = NSLock()
    private var displayed = 0

    @MainActor
    public init() {
        layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        videoRenderer = layer.sampleBufferRenderer
    }

    public var displayedCount: Int { lock.withLock { displayed } }

    public func display(_ pixelBuffer: CVPixelBuffer) {
        guard let sample = Self.makeSampleBuffer(from: pixelBuffer) else { return }
        let box = SampleBox(sample)
        queue.async {
            if self.videoRenderer.status == .failed { self.videoRenderer.flush() }
            self.videoRenderer.enqueue(box.sample)
            self.lock.withLock { self.displayed += 1 }
        }
    }

    static func makeSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                           formatDescriptionOut: &format) == noErr, let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                       formatDescription: format, sampleTiming: &timing,
                                                       sampleBufferOut: &sample) == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary],
           let first = attachments.first {
            first[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        return sample
    }
}
