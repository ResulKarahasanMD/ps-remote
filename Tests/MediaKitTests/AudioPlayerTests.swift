import AVFoundation
import ChiakiKit
import Foundation
import Testing
@testable import MediaKit

final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    func add(_ name: String) { lock.withLock { names.append(name) } }
    var all: [String] { lock.withLock { names } }
}

@Suite struct AudioPlayerTests {
    static let stereo = AudioFormat(channels: 2, sampleRate: 48000, frameSize: 480)

    func offlinePlayer(events: EventRecorder = EventRecorder()) -> AudioPlayer {
        AudioPlayer(volume: 0, targetMilliseconds: 40, playsToDevice: false, onEvent: events.add)
    }

    func feed(_ player: AudioPlayer, _ packet: [UInt8]) {
        packet.withUnsafeBytes { player.consume($0) }
    }

    @Test func decodesOpusPacketsIntoTheRing() throws {
        let player = offlinePlayer()
        player.configure(Self.stereo)
        let opus = SyntheticOpus()
        for _ in 0 ..< 10 { feed(player, opus.nextPacket()) }

        #expect(player.stats.packets == 10)
        #expect(player.stats.decodeFailures == 0)
        let ring = try #require(player.ringForTesting)
        #expect(ring.fill == 4800)
        var left = [Float](repeating: 0, count: 4800)
        var right = [Float](repeating: 0, count: 4800)
        let copied = left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in ring.read(frames: 4800) { $0 == 0 ? l.baseAddress : r.baseAddress } }
        }
        #expect(copied == 4800)
        for channel in [left, right] {
            let rms = (channel.map { $0 * $0 }.reduce(0, +) / Float(channel.count)).squareRoot()
            #expect((0.25 ... 0.45).contains(rms), "a 0.5 amplitude sine has RMS 0.354; got \(rms)")
        }
    }

    @Test func aLostFrameIsConcealedInsteadOfLeavingAGap() throws {
        let player = offlinePlayer()
        player.configure(Self.stereo)
        let opus = SyntheticOpus()
        for _ in 0 ..< 5 { feed(player, opus.nextPacket()) }
        player.consume(nil)
        feed(player, opus.nextPacket())

        #expect(player.stats.packets == 6)
        #expect(player.stats.concealed == 1)
        #expect(try #require(player.ringForTesting).fill == 7 * 480)
    }

    @Test func statsReportHowMuchAudioIsBuffered() {
        let player = offlinePlayer()
        #expect(player.stats.bufferedMilliseconds == 0)
        player.configure(Self.stereo)
        let opus = SyntheticOpus()
        for _ in 0 ..< 7 { feed(player, opus.nextPacket()) }
        #expect(player.stats.bufferedMilliseconds == 70)
        player.stop()
        #expect(player.stats.bufferedMilliseconds == 0)
    }

    @Test func aMalformedPacketIsCountedAndSkipped() throws {
        let player = offlinePlayer()
        player.configure(Self.stereo)
        // TOC 0x03 = code 3 (frame count byte follows); a frame count of 0 is invalid (RFC 6716 R5).
        feed(player, [0x03, 0x00])
        #expect(player.stats.decodeFailures == 1)
        #expect(player.stats.packets == 0)
        #expect(try #require(player.ringForTesting).fill == 0)
        feed(player, SyntheticOpus().nextPacket())
        #expect(player.stats.packets == 1, "the decoder keeps working after a bad packet")
    }

    @Test(arguments: [
        AudioFormat(channels: 0, sampleRate: 48000, frameSize: 480),
        AudioFormat(channels: 6, sampleRate: 48000, frameSize: 480),
        AudioFormat(channels: 2, sampleRate: 44100, frameSize: 441),
        AudioFormat(channels: 2, sampleRate: 48000, frameSize: 0),
        AudioFormat(channels: 2, sampleRate: 48000, frameSize: 1_000_000),
    ])
    func anUnsupportedHeaderDisablesAudioWithoutCrashing(format: AudioFormat) {
        let events = EventRecorder()
        let player = offlinePlayer(events: events)
        player.configure(format)
        feed(player, SyntheticOpus().nextPacket())
        player.consume(nil)
        #expect(events.all == ["audio_format_unsupported"])
        #expect(player.stats == AudioStats())
        #expect(player.ringForTesting == nil)
    }

    @Test func packetsBeforeTheHeaderAreIgnored() {
        let player = offlinePlayer()
        feed(player, SyntheticOpus().nextPacket())
        player.consume(nil)
        #expect(player.stats == AudioStats())
    }

    @Test func aNewHeaderKeepsTheCountersOfTheOldStream() throws {
        let player = offlinePlayer()
        player.configure(Self.stereo)
        let opus = SyntheticOpus()
        for _ in 0 ..< 4 { feed(player, opus.nextPacket()) }
        let ring = try #require(player.ringForTesting)
        #expect(ring.read(frames: 1000) { _ in nil } == 1000)
        #expect(ring.read(frames: 1000) { _ in nil } == 920)     // 1920 were buffered: one underrun
        #expect(player.stats.underruns == 1)

        player.configure(Self.stereo)
        #expect(try #require(player.ringForTesting).fill == 0, "a new stream starts with an empty buffer")
        #expect(player.stats.underruns == 1)
        feed(player, SyntheticOpus().nextPacket())
        #expect(player.stats.packets == 5)
    }

    @Test func stopIsIdempotentAndLaterAudioIsIgnored() {
        let player = offlinePlayer()
        player.configure(Self.stereo)
        feed(player, SyntheticOpus().nextPacket())
        player.stop()
        player.stop()
        feed(player, SyntheticOpus().nextPacket())
        player.configure(Self.stereo)
        #expect(player.stats.packets == 1)
        #expect(player.ringForTesting == nil)
    }

    /// Plays digital silence at volume 0 through the real output device.
    @Test func theEngineDrainsTheRingAndCountsTheUnderrunWhenAudioStops() async throws {
        let events = EventRecorder()
        let player = AudioPlayer(volume: 0, onEvent: events.add)
        defer { player.stop() }
        player.configure(Self.stereo)
        #expect(await eventually(timeout: .seconds(5)) { events.all.contains("audio_started") })
        #expect(player.isEngineRunning)

        let opus = SyntheticOpus()
        for _ in 0 ..< 8 { feed(player, opus.nextPacket(amplitude: 0)) }     // 80 ms
        let ring = try #require(player.ringForTesting)
        #expect(await eventually(timeout: .seconds(5)) { ring.fill == 0 }, "the render thread plays the buffered audio")
        #expect(await eventually(timeout: .seconds(5)) { player.stats.underruns == 1 })
    }

    @Test func theEngineIsRebuiltAfterAnOutputDeviceChange() async throws {
        let events = EventRecorder()
        let player = AudioPlayer(volume: 0, onEvent: events.add)
        defer { player.stop() }
        player.configure(Self.stereo)
        #expect(await eventually(timeout: .seconds(5)) { events.all == ["audio_started"] })

        // What AVAudioEngine does when the output device changes: it stops and posts this notification.
        let engine = try #require(player.engineForTesting)
        engine.stop()
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)

        #expect(await eventually(timeout: .seconds(5)) { events.all == ["audio_started", "audio_started"] })
        #expect(player.isEngineRunning)
    }
}
