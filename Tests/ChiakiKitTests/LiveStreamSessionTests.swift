import CChiaki
import Foundation
import Testing
@testable import ChiakiKit

final class CountingSink: VideoSink, @unchecked Sendable {
    func consume(_ buffer: UnsafeRawBufferPointer, framesLost: Int32, recovered: Bool) -> Bool { true }
}

final class RecordingAudioSink: AudioSink, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedFormats: [AudioFormat] = []
    private var recordedPackets: [[UInt8]?] = []
    func configure(_ format: AudioFormat) { lock.withLock { recordedFormats.append(format) } }
    func consume(_ packet: UnsafeRawBufferPointer?) { lock.withLock { recordedPackets.append(packet.map { Array($0) }) } }
    var formats: [AudioFormat] { lock.withLock { recordedFormats } }
    var packets: [[UInt8]?] { lock.withLock { recordedPackets } }
}

/// A session to TEST-NET-1 (resolves, never answers): it starts and stays in its connect phase.
func startUnconnectedSession(audio: any AudioSink = RecordingAudioSink()) throws -> any StreamSession {
    try LiveChiakiBackend().startStream(to: .fixture(), address: "192.0.2.1",
                                        accountID: try PSNAccountID(base64: "AQIDBAUGBwg="),
                                        config: StreamConfig(), video: CountingSink(), audio: audio)
}

@Suite struct LiveStreamSessionTests {
    @Test func unresolvableHostFailsToStartWithAChiakiError() throws {
        let backend = try LiveChiakiBackend()
        #expect(throws: ChiakiError.self) {
            _ = try backend.startStream(to: .fixture(), address: "not a host name", accountID: try PSNAccountID(base64: "AQIDBAUGBwg="),
                                        config: StreamConfig(), video: CountingSink(), audio: RecordingAudioSink())
        }
    }

    @Test func stopIsIdempotentAndEndsTheEventStream() async throws {
        let session = try startUnconnectedSession()
        try await withTimeout(seconds: 10) {
            await session.stop()
            await session.stop()
        }
        let remaining = try await withTimeout(seconds: 2) {
            var collected: [SessionEvent] = []
            for await event in session.events { collected.append(event) }
            return collected
        }
        #expect(remaining.allSatisfy { if case .quit = $0 { true } else { $0 == .connected } })
    }
}

@Suite struct LiveStreamSessionLifetimeTests {
    /// Dropping the last reference without awaiting stop() must not free the ChiakiSession while
    /// libchiaki's threads still run: the session keeps itself alive until stop() has joined them.
    @Test func sessionStaysAliveUntilStopEvenWhenTheCallerDropsIt() async throws {
        weak var weakSession: AnyObject?
        do {
            let session = try startUnconnectedSession()
            weakSession = session as AnyObject
        }
        let survivor = try #require(weakSession as? any StreamSession, "session was freed while libchiaki threads were running")
        try await withTimeout(seconds: 10) { await survivor.stop() }
    }
}

@Suite struct LiveStreamSessionAudioTests {
    /// Calls libchiaki's audio sink callbacks the way audioreceiver.c does.
    @Test func audioCallbacksReachTheSinkIncludingLostFrames() async throws {
        let sink = RecordingAudioSink()
        let session = try startUnconnectedSession(audio: sink)
        let user = Unmanaged.passUnretained(try #require(session as? LiveStreamSession)).toOpaque()

        var header = ChiakiAudioHeader(channels: 2, bits: 16, rate: 48000, frame_size: 480, unknown: 0)
        audioHeaderCallback(header: &header, user: user)
        var bytes: [UInt8] = [0xfc, 0x01, 0x02]
        audioFrameCallback(buf: &bytes, size: bytes.count, user: user)
        audioFrameCallback(buf: nil, size: 0, user: user)
        audioFrameCallback(buf: &bytes, size: 0, user: user)
        audioHeaderCallback(header: nil, user: user)
        audioFrameCallback(buf: &bytes, size: bytes.count, user: nil)

        #expect(sink.formats == [AudioFormat(channels: 2, sampleRate: 48000, frameSize: 480)])
        #expect(sink.packets == [[0xfc, 0x01, 0x02], nil, nil])
        try await withTimeout(seconds: 10) { await session.stop() }
    }
}

@Suite struct LiveStreamSessionControllerTests {
    @Test func sendReplacesTheControllerStateBeforeConnectAndIsIgnoredAfterStop() async throws {
        let session = try startUnconnectedSession()
        let live = try #require(session as? LiveStreamSession)
        var idle = ChiakiControllerState(.idle)
        var initial = try #require(live.controllerStateForTesting)
        #expect(chiaki_controller_state_equals(&initial, &idle))

        let state = ControllerState(buttons: [.cross, .ps], l2: 7, r2: 255, leftX: -32767, leftY: 100, rightX: 5, rightY: 32767)
        session.send(state)
        var held = try #require(live.controllerStateForTesting)
        var expected = ChiakiControllerState(state)
        #expect(chiaki_controller_state_equals(&held, &expected))

        try await withTimeout(seconds: 10) { await session.stop() }
        session.send(.idle)
        #expect(live.controllerStateForTesting == nil)
    }

    @Test func sendFromManyThreadsWhileStoppingDoesNotCrash() async throws {
        let session = try startUnconnectedSession()
        await withTaskGroup(of: Void.self) { group in
            for index in 0 ..< 8 {
                group.addTask {
                    for step in 0 ..< 2000 { session.send(ControllerState(leftX: Int16(index * 100 + step))) }
                }
            }
            group.addTask { await session.stop() }
        }
    }
}
