import Synchronization

/// Single-producer single-consumer ring of float audio frames. The producer (libchiaki's audio
/// thread) only advances `written`; the consumer (the audio render thread) only advances `consumed`,
/// so neither side takes a lock or allocates.
final class AudioRingBuffer: @unchecked Sendable {
    let channels: Int
    /// All sizes are in frames (one sample per channel).
    let capacity: Int
    /// Playback (re)starts once this much is buffered.
    let target: Int
    /// Above this the reader drops the oldest frames back down to the playback start level.
    let highWater: Int

    /// Planar: channel `c` occupies `storage[c * capacity ..< (c + 1) * capacity]`.
    private let storage: UnsafeMutablePointer<Float>
    private let written = Atomic<Int>(0)
    private let consumed = Atomic<Int>(0)
    private let underrunCount = Atomic<Int>(0)
    private let overflowCount = Atomic<Int>(0)
    /// Reader-only: false while (re)buffering up to the playback start level.
    private var primed = false
    /// Reader-only: false until playback has started for the first time.
    private var hasPlayed = false

    init(channels: Int, capacity: Int, target: Int) {
        precondition(channels > 0 && target > 0 && capacity >= target * 4)
        self.channels = channels
        self.capacity = capacity
        self.target = target
        highWater = target * 3
        storage = .allocate(capacity: capacity * channels)
        storage.initialize(repeating: 0, count: capacity * channels)
    }

    deinit {
        storage.deallocate()
    }

    var underruns: Int { underrunCount.load(ordering: .relaxed) }
    var overflows: Int { overflowCount.load(ordering: .relaxed) }
    var fill: Int { written.load(ordering: .acquiring) - consumed.load(ordering: .acquiring) }

    /// Producer side. Appends whole frames of interleaved samples; when the reader has stalled and
    /// the ring is full the samples are dropped and counted as an overflow.
    @discardableResult
    func write(interleaved samples: UnsafeBufferPointer<Float>) -> Bool {
        let frames = samples.count / channels
        guard frames > 0 else { return true }
        let start = written.load(ordering: .relaxed)
        guard frames <= capacity - (start - consumed.load(ordering: .acquiring)) else {
            overflowCount.add(1, ordering: .relaxed)
            return false
        }
        let offset = start % capacity
        for channel in 0 ..< channels {
            let plane = storage + channel * capacity
            for frame in 0 ..< frames {
                plane[(offset + frame) % capacity] = samples[frame * channels + channel]
            }
        }
        written.store(start + frames, ordering: .releasing)
        return true
    }

    /// Consumer side. Fills `frames` samples of every channel's output plane (`plane(channel)`; nil
    /// skips that channel) and returns the number of frames that came from the ring; the rest is
    /// silence.
    @discardableResult
    func read(frames: Int, into plane: (Int) -> UnsafeMutablePointer<Float>?) -> Int {
        var start = consumed.load(ordering: .relaxed)
        var available = written.load(ordering: .acquiring) - start
        // A render quantum larger than `target` (some Bluetooth devices) raises both thresholds.
        let wanted = max(target, frames)
        // Whatever queued up before playback first starts (the audio engine was still starting) is
        // stale: start exactly `wanted` behind the newest frame, and do not count that as a glitch.
        if available > (hasPlayed ? max(highWater, wanted * 2) : wanted) {
            start += available - wanted
            available = wanted
            if hasPlayed { overflowCount.add(1, ordering: .relaxed) }
        }
        var count = 0
        if primed || available >= wanted {
            primed = true
            hasPlayed = true
            count = min(frames, available)
        }
        let offset = start % capacity
        let first = min(count, capacity - offset)
        for channel in 0 ..< channels {
            guard let output = plane(channel) else { continue }
            let source = storage + channel * capacity
            output.update(from: source + offset, count: first)
            (output + first).update(from: source, count: count - first)
            (output + count).update(repeating: 0, count: frames - count)
        }
        if primed, count < frames {
            underrunCount.add(1, ordering: .relaxed)
            primed = false
        }
        consumed.store(start + count, ordering: .releasing)
        return count
    }
}
