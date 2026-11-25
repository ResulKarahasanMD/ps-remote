import AVFoundation
import ChiakiKit
import COpus
import Foundation

public struct AudioStats: Sendable, Equatable {
    /// Opus packets decoded.
    public var packets = 0
    /// Lost frames filled in by Opus loss concealment.
    public var concealed = 0
    public var decodeFailures = 0
    /// Render calls that ran out of buffered audio and played silence.
    public var underruns = 0
    /// Times buffered audio was dropped because playback fell behind.
    public var overflows = 0
    /// Audio waiting in the buffer right now: how far the sound trails the stream.
    public var bufferedMilliseconds = 0.0

    public init() {}
}

/// Decodes libchiaki's Opus packets on the calling (libchiaki audio) thread into a lock-free ring
/// that an AVAudioSourceNode drains. `configure` and `consume` never wait for the audio hardware:
/// the engine is started on a private queue.
public final class AudioPlayer: AudioSink, @unchecked Sendable {
    private let volume: Float
    private let targetMilliseconds: Int
    private let playsToDevice: Bool
    private let onEvent: @Sendable (String) -> Void

    // Decoder state: lock held, used on libchiaki's audio thread.
    private let lock = NSLock()
    private var decoder: OpaquePointer?
    private var pcm: UnsafeMutablePointer<Float>?
    private var format: AudioFormat?
    private var ring: AudioRingBuffer?
    private var counters = AudioStats()
    private var stopped = false

    // Engine state: confined to `queue`.
    private let queue = DispatchQueue(label: "psremote.audio-player")
    private var engine: AVAudioEngine?
    private var observer: (any NSObjectProtocol)?

    /// - Parameters:
    ///   - volume: 0...1 output volume.
    ///   - targetMilliseconds: audio buffered before playback starts (spec §3.4: 40 ms).
    ///   - onEvent: session-log event names (`audio_started`, `audio_start_failed`,
    ///     `audio_format_unsupported`); called on a private queue or libchiaki's audio thread.
    public convenience init(volume: Float = 1, targetMilliseconds: Int = 40,
                            onEvent: @escaping @Sendable (String) -> Void = { _ in }) {
        self.init(volume: volume, targetMilliseconds: targetMilliseconds, playsToDevice: true, onEvent: onEvent)
    }

    /// `playsToDevice: false` keeps decoded audio in the ring so tests can read it back.
    init(volume: Float, targetMilliseconds: Int, playsToDevice: Bool, onEvent: @escaping @Sendable (String) -> Void) {
        self.volume = volume
        self.targetMilliseconds = targetMilliseconds
        self.playsToDevice = playsToDevice
        self.onEvent = onEvent
    }

    deinit {
        if let decoder { opus_decoder_destroy(decoder) }
        pcm?.deallocate()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        engine?.stop()
    }

    public var stats: AudioStats {
        lock.withLock {
            var result = counters
            if let ring, let format {
                result.underruns += ring.underruns
                result.overflows += ring.overflows
                result.bufferedMilliseconds = Double(ring.fill) * 1000 / Double(format.sampleRate)
            }
            return result
        }
    }

    var ringForTesting: AudioRingBuffer? { lock.withLock { ring } }
    var isEngineRunning: Bool { queue.sync { engine?.isRunning ?? false } }
    var engineForTesting: AVAudioEngine? { queue.sync { engine } }

    public func configure(_ format: AudioFormat) {
        // libopus accepts exactly these rates and one or two channels (opus_decoder_create).
        guard (1 ... 2).contains(format.channels), [8000, 12000, 16000, 24000, 48000].contains(format.sampleRate),
              format.frameSize > 0, format.frameSize <= format.sampleRate / 8 else {
            lock.withLock { releaseDecoder() }
            onEvent("audio_format_unsupported")
            return
        }
        var status: Int32 = 0
        let newDecoder = opus_decoder_create(Int32(format.sampleRate), Int32(format.channels), &status)
        guard status == OPUS_OK, let newDecoder else {
            lock.withLock { releaseDecoder() }
            onEvent("audio_format_unsupported")
            return
        }
        let newRing = AudioRingBuffer(channels: format.channels, capacity: format.sampleRate / 2,
                                      target: format.sampleRate * targetMilliseconds / 1000)
        let accepted = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            releaseDecoder()
            decoder = newDecoder
            pcm = .allocate(capacity: format.frameSize * format.channels)
            self.format = format
            ring = newRing
            return true
        }
        guard accepted else {
            opus_decoder_destroy(newDecoder)
            return
        }
        guard playsToDevice else { return }
        queue.async { self.startEngine(format: format, ring: newRing) }
    }

    public func consume(_ packet: UnsafeRawBufferPointer?) {
        lock.withLock {
            guard let decoder, let pcm, let format, let ring else { return }
            // A nil packet asks Opus to conceal one lost frame.
            let decoded = opus_decode_float(decoder, packet?.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                            Int32(packet?.count ?? 0), pcm, Int32(format.frameSize), 0)
            guard decoded > 0 else {
                counters.decodeFailures += 1
                return
            }
            if packet == nil { counters.concealed += 1 } else { counters.packets += 1 }
            ring.write(interleaved: UnsafeBufferPointer(start: pcm, count: Int(decoded) * format.channels))
        }
    }

    /// Stops playback and frees the decoder. Safe to call more than once; later packets are ignored.
    public func stop() {
        lock.withLock {
            stopped = true
            releaseDecoder()
        }
        queue.sync { tearDownEngine() }
    }

    // MARK: - Decoder (lock held)

    private func releaseDecoder() {
        if let decoder { opus_decoder_destroy(decoder) }
        decoder = nil
        pcm?.deallocate()
        pcm = nil
        format = nil
        if let ring {
            counters.underruns += ring.underruns
            counters.overflows += ring.overflows
        }
        ring = nil
    }

    // MARK: - Engine (on `queue`)

    private func startEngine(format: AudioFormat, ring: AudioRingBuffer) {
        tearDownEngine()
        // AVAudioSourceNode only takes the standard (deinterleaved float) layout; an interleaved format
        // raises an Objective-C exception when the node is connected.
        guard lock.withLock({ self.ring === ring }),
              let layout = AVAudioFormat(standardFormatWithSampleRate: Double(format.sampleRate),
                                         channels: AVAudioChannelCount(format.channels)) else { return }
        let node = AVAudioSourceNode(format: layout) { _, _, frameCount, bufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            ring.read(frames: Int(frameCount)) { channel in
                channel < buffers.count ? buffers[channel].mData?.assumingMemoryBound(to: Float.self) : nil
            }
            return noErr
        }
        let engine = AVAudioEngine()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: layout)
        engine.mainMixerNode.outputVolume = volume
        // The engine stops itself when the output device changes (e.g. headphones connect); rebuild it.
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                          queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.startEngine(format: format, ring: ring) }
        }
        self.engine = engine
        do {
            try engine.start()
            onEvent("audio_started")
        } catch {
            onEvent("audio_start_failed")
        }
    }

    private func tearDownEngine() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine?.stop()
        engine = nil
    }
}
