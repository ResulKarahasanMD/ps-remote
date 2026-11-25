import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import MediaKit

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stats: [FrameStats] = []
    private var images = 0
    func add(_ s: FrameStats) { lock.withLock { stats.append(s) } }
    func image() { lock.withLock { images += 1 } }
    var frames: [FrameStats] { lock.withLock { stats } }
    var imageCount: Int { lock.withLock { images } }
}

@Suite(.serialized) struct VideoDecoderTests {
    func feed(_ decoder: VideoDecoder, _ data: Data, framesLost: Int32 = 0) -> Bool {
        data.withUnsafeBytes { decoder.consume($0, framesLost: framesLost, recovered: false) }
    }

    @Test func decodesASyntheticStreamAfterTheHeader() throws {
        let stream = try SyntheticHEVC.make(width: 640, height: 360, frames: 8)
        let recorder = Recorder()
        let decoder = VideoDecoder(onFrame: recorder.add, onImage: { _ in recorder.image() })

        #expect(feed(decoder, stream.header))            // header: accepted, not a frame
        #expect(recorder.frames.isEmpty)
        for frame in stream.frames { #expect(feed(decoder, frame)) }

        #expect(recorder.imageCount == 8)
        #expect(recorder.frames.count == 8)
        #expect(recorder.frames.allSatisfy { $0.decodeOK && $0.decodeMilliseconds >= 0 })
        #expect(decoder.dimensions?.width == 640)
        #expect(decoder.dimensions?.height == 360)
    }

    @Test func frameBeforeHeaderIsRejectedThenRecoversAfterHeader() throws {
        let stream = try SyntheticHEVC.make(width: 640, height: 360, frames: 2)
        let recorder = Recorder()
        let decoder = VideoDecoder(onFrame: recorder.add)
        #expect(!feed(decoder, stream.frames[0], framesLost: 3))
        #expect(recorder.frames == [FrameStats(size: stream.frames[0].count, framesLost: 3, recovered: false,
                                               decodeOK: false, decodeMilliseconds: 0)])
        #expect(feed(decoder, stream.header))
        #expect(feed(decoder, stream.frames[0]))
    }

    @Test func corruptSliceIsRejectedAndCounted() throws {
        let stream = try SyntheticHEVC.make(width: 640, height: 360, frames: 1)
        let recorder = Recorder()
        let decoder = VideoDecoder(onFrame: recorder.add)
        #expect(feed(decoder, stream.header))
        // Keep the start code and 2-byte NAL header, replace the slice payload with garbage.
        var corrupt = stream.frames[0]
        var generator = SystemRandomNumberGenerator()
        for index in (6..<corrupt.count) { corrupt[index] = UInt8.random(in: 1...255, using: &generator) }
        #expect(!feed(decoder, corrupt))
        #expect(recorder.frames.last?.decodeOK == false)
    }

    @Test func resolutionChangeRebuildsTheSession() throws {
        let first = try SyntheticHEVC.make(width: 640, height: 360, frames: 2)
        let second = try SyntheticHEVC.make(width: 320, height: 180, frames: 2)
        let decoder = VideoDecoder()
        #expect(feed(decoder, first.header))
        for frame in first.frames { #expect(feed(decoder, frame)) }
        #expect(feed(decoder, second.header))
        for frame in second.frames { #expect(feed(decoder, frame)) }
        #expect(decoder.dimensions?.width == 320)
        #expect(decoder.dimensions?.height == 180)
    }
}

final class ErrorRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [VideoDecoderError] = []
    func add(_ e: VideoDecoderError) { lock.withLock { errors.append(e) } }
    var all: [VideoDecoderError] { lock.withLock { errors } }
}

@Suite(.serialized) struct VideoDecoderErrorTests {
    func feed(_ decoder: VideoDecoder, _ data: Data) -> Bool {
        data.withUnsafeBytes { decoder.consume($0, framesLost: 0, recovered: false) }
    }

    /// Spec §5: if the decoder cannot be set up the user must be told, not shown a black window.
    @Test func unusableParameterSetsAreReportedOnce() throws {
        let errors = ErrorRecorder()
        let decoder = VideoDecoder(onError: errors.add)
        let bogusHeader = Data([0, 0, 0, 1, 0x40, 0x01, 0xFF]) + Data([0, 0, 0, 1, 0x42, 0x01, 0xFF])
            + Data([0, 0, 0, 1, 0x44, 0x01, 0xFF])
        #expect(!feed(decoder, bogusHeader))
        #expect(!feed(decoder, bogusHeader))
        #expect(errors.all.count == 1)
        if case .setupFailed = errors.all.first {} else { Issue.record("expected .setupFailed, got \(errors.all)") }
    }

    /// A dead VideoToolbox session (GPU reset, media server restart) must not leave a permanent
    /// black picture: the decoder rebuilds from the retained parameter sets.
    @Test func invalidatedSessionIsRebuiltFromTheRetainedParameterSets() throws {
        let stream = try SyntheticHEVC.make(width: 640, height: 360, frames: 3)
        let decoder = VideoDecoder()
        #expect(feed(decoder, stream.header))
        #expect(feed(decoder, stream.frames[0]))
        decoder.invalidateSessionForTesting()
        _ = feed(decoder, stream.frames[1])            // may fail: this is where the dead session is noticed
        #expect(feed(decoder, stream.frames[0]))       // IDR again after rebuild
    }
}
