import ChiakiKit
import Foundation
import Testing
@testable import MediaKit

final class LiveCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var ok = 0
    private var failed = 0
    func add(_ stats: FrameStats) { lock.withLock { if stats.decodeOK { ok += 1 } else { failed += 1 } } }
    var decoded: Int { lock.withLock { ok } }
    var failures: Int { lock.withLock { failed } }
}

/// Opens a real Remote Play session (closes any chiaki-ng / official app session). Uses chiaki-ng's
/// registration via ChiakiNGImport so the test does not need Keychain access.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PSREMOTE_LIVE_STREAM"] == "1"))
struct LiveStreamTests {
    @Test func streamsAndDecodes1080pFromTheRealConsole() async throws {
        let prefs = try ChiakiNGImport.loadPreferences()
        let backend = try LiveChiakiBackend()
        var discovered: [Console] = []
        for try await list in ConsoleDiscovery(backend: backend).consoles() where !list.isEmpty { discovered = list; break }
        let addresses = Dictionary(discovered.map { (ConsoleSelector.normalizedID($0.id), $0.address) }, uniquingKeysWith: { a, _ in a })
        let console = try #require(try ChiakiNGImport.consoles(fromPreferences: prefs, addresses: addresses).first)
        let accountID = try #require(try ChiakiNGImport.accountID(fromPreferences: prefs))
        #expect(discovered.first { ConsoleSelector.normalizedID($0.id) == console.hostID }?.state == .ready,
                "PS5 açık olmalı (psremote-cli wake)")

        let counter = LiveCounter()
        let decoder = VideoDecoder(onFrame: counter.add)
        let player = AudioPlayer(volume: 0)
        let session = try backend.startStream(to: console, address: console.lastKnownAddress, accountID: accountID,
                                              config: StreamConfig(), video: decoder, audio: player)
        try await Task.sleep(for: .seconds(5))
        session.send(ControllerState(buttons: .dpadRight))      // moves the home-screen selection one step
        try await Task.sleep(for: .milliseconds(100))
        session.send(.idle)
        try await Task.sleep(for: .seconds(5))
        await session.stop()
        player.stop()

        let audio = player.stats
        #expect(audio.packets >= 800, "10 sn'de ~1000 ses paketi (10 ms'lik) beklenir; gelen: \(audio.packets)")
        #expect(audio.decodeFailures == 0)

        #expect(counter.decoded >= 300, "10 sn'de en az 300 kare (30 fps) çözülmeli; çözülen: \(counter.decoded)")
        #expect(decoder.dimensions?.width == 1920)
        #expect(decoder.dimensions?.height == 1080)
    }
}
