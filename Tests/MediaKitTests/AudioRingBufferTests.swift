import Foundation
import Synchronization
import Testing
@testable import MediaKit

@Suite struct AudioRingBufferTests {
    /// Mono frames numbered from `first`, so every sample identifies its position in the stream.
    func write(_ ring: AudioRingBuffer, first: Int, count: Int) -> Bool {
        let samples = (first ..< first + count).map(Float.init)
        return samples.withUnsafeBufferPointer { ring.write(interleaved: $0) }
    }

    /// Reads `frames` frames and returns them interleaved, like the written samples.
    func read(_ ring: AudioRingBuffer, frames: Int) -> (copied: Int, samples: [Float]) {
        var planes = [[Float]](repeating: [Float](repeating: -1, count: frames), count: ring.channels)
        let pointers = planes.indices.map { index in planes[index].withUnsafeMutableBufferPointer { $0.baseAddress! } }
        let copied = ring.read(frames: frames) { pointers[$0] }
        return (copied, (0 ..< frames).flatMap { frame in planes.map { $0[frame] } })
    }

    @Test func staysSilentUntilTheTargetIsBuffered() {
        let ring = AudioRingBuffer(channels: 1, capacity: 4800, target: 480)
        #expect(write(ring, first: 1, count: 479))
        let early = read(ring, frames: 100)
        #expect(early.copied == 0)
        #expect(early.samples == [Float](repeating: 0, count: 100))
        #expect(ring.underruns == 0, "initial buffering is not an underrun")

        #expect(write(ring, first: 480, count: 1))
        let primed = read(ring, frames: 100)
        #expect(primed.copied == 100)
        #expect(primed.samples == (1 ... 100).map(Float.init))
        #expect(ring.fill == 380)
    }

    @Test func anUnderrunPlaysSilenceIsCountedOnceAndRebuffers() {
        let ring = AudioRingBuffer(channels: 1, capacity: 4800, target: 480)
        _ = write(ring, first: 1, count: 480)
        #expect(read(ring, frames: 100).copied == 100)
        let short = read(ring, frames: 400)
        #expect(short.copied == 380)
        #expect(short.samples.prefix(380) == (101 ... 480).map(Float.init)[...])
        #expect(short.samples.suffix(20) == [Float](repeating: 0, count: 20)[...])
        #expect(ring.underruns == 1)

        _ = write(ring, first: 481, count: 100)
        #expect(read(ring, frames: 50).copied == 0, "rebuffers to the target before playing again")
        #expect(ring.underruns == 1, "silence while rebuffering is not another underrun")
        _ = write(ring, first: 581, count: 380)
        #expect(read(ring, frames: 50).samples == (481 ... 530).map(Float.init))
    }

    @Test func dropsTheOldestAudioAboveTheHighWaterMarkWhilePlaying() {
        let ring = AudioRingBuffer(channels: 1, capacity: 4800, target: 480)
        #expect(ring.highWater == 1440)
        _ = write(ring, first: 1, count: 480)
        #expect(read(ring, frames: 100).copied == 100)
        _ = write(ring, first: 481, count: 1100)        // 1480 buffered: above the high-water mark
        let result = read(ring, frames: 100)
        #expect(ring.overflows == 1)
        #expect(result.samples == (1101 ... 1200).map(Float.init), "keeps the newest `target` frames")
        #expect(ring.fill == 380)
    }

    /// Packets queue up while the audio engine is still starting; that backlog is stale, not a glitch.
    @Test func aBacklogFromBeforePlaybackStartsIsTrimmedToTheTargetWithoutCountingAnOverflow() {
        let ring = AudioRingBuffer(channels: 1, capacity: 4800, target: 480)
        _ = write(ring, first: 1, count: 1000)          // more than the target, less than the high-water mark
        let result = read(ring, frames: 100)
        #expect(result.samples == (521 ... 620).map(Float.init), "playback starts `target` frames behind the newest")
        #expect(ring.fill == 380)
        #expect(ring.overflows == 0)
        #expect(ring.underruns == 0)
    }

    @Test func aFullRingRejectsTheWriteAndCountsAnOverflow() {
        let ring = AudioRingBuffer(channels: 1, capacity: 1920, target: 480)
        #expect(write(ring, first: 1, count: 1920))
        #expect(!write(ring, first: 1921, count: 1))
        #expect(ring.overflows == 1)
        #expect(ring.fill == 1920)
    }

    @Test func keepsStereoFramesIntactAcrossTheWrapAround() {
        let ring = AudioRingBuffer(channels: 2, capacity: 2000, target: 480)
        var next = 1
        var expected = 1
        for _ in 0 ..< 40 {     // 40 x 480 frames through a 2000-frame ring
            let samples = (next ..< next + 480).flatMap { [Float($0), -Float($0)] }
            #expect(samples.withUnsafeBufferPointer { ring.write(interleaved: $0) })
            next += 480
            let result = read(ring, frames: 480)
            #expect(result.copied == 480)
            #expect(result.samples == (expected ..< expected + 480).flatMap { [Float($0), -Float($0)] })
            expected += 480
        }
        #expect(ring.underruns == 0)
        #expect(ring.overflows == 0)
    }

    @Test func aRenderQuantumLargerThanTheTargetStillStartsPlayback() {
        let ring = AudioRingBuffer(channels: 1, capacity: 9600, target: 480)
        _ = write(ring, first: 1, count: 1024)
        #expect(read(ring, frames: 1024).copied == 1024)
        // Refilling to twice the quantum must not be treated as an overflow.
        _ = write(ring, first: 1025, count: 2048)
        #expect(read(ring, frames: 1024).copied == 1024)
        #expect(ring.overflows == 0)
    }

    /// One writer and one reader on different threads: whatever is played is in stream order.
    @Test func concurrentWriterAndReaderNeverReorderOrTearFrames() async {
        let ring = AudioRingBuffer(channels: 1, capacity: 24000, target: 1920)
        let total = 480 * 2000
        let writerDone = Atomic<Bool>(false)
        async let writing: Void = Task.detached {
            var next = 1
            while next <= total {
                let samples = (next ..< next + 480).map(Float.init)
                if samples.withUnsafeBufferPointer({ ring.write(interleaved: $0) }) { next += 480 } else { await Task.yield() }
            }
            writerDone.store(true, ordering: .releasing)
        }.value
        async let reading = Task.detached { () -> (ordered: Bool, played: Int) in
            var output = [Float](repeating: 0, count: 512)
            var last: Float = 0
            var ordered = true
            var played = 0
            while true {
                let finished = writerDone.load(ordering: .acquiring)
                let copied = output.withUnsafeMutableBufferPointer { buffer in ring.read(frames: 512) { _ in buffer.baseAddress } }
                for sample in output.prefix(copied) {
                    if sample <= last { ordered = false }
                    last = sample
                }
                played += copied
                if finished, copied == 0 { break }
            }
            return (ordered, played)
        }.value
        await writing
        let result = await reading
        #expect(result.ordered)
        #expect(result.played > total / 2)
        #expect(result.played <= total)
    }
}
