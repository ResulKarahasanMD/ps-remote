import Foundation
import Testing
@testable import MediaKit

@Suite struct SessionLogTests {
    func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "psremote-log-\(UUID().uuidString)")
    }

    @Test func writesOneJSONObjectPerLineAndASummary() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = try SessionLog(directory: directory, now: Date(timeIntervalSince1970: 1_790_800_000))
        #expect(log.url.lastPathComponent.hasPrefix("session-"))
        #expect(log.url.pathExtension == "jsonl")

        log.record(event: "connected")
        log.record(FrameStats(size: 1000, framesLost: 0, recovered: false, decodeOK: true, decodeMilliseconds: 2.0))
        log.record(FrameStats(size: 900, framesLost: 2, recovered: true, decodeOK: false, decodeMilliseconds: 0))
        log.record(FrameStats(size: 800, framesLost: 0, recovered: false, decodeOK: true, decodeMilliseconds: 6.0))
        let summary = log.finish(quitReason: "stopped")

        #expect(summary.frames == 3)
        #expect(summary.decodeFailures == 1)
        #expect(summary.framesLostTotal == 2)
        #expect(summary.decodeMillisecondsP95 == 6.0)
        #expect(summary.quitReason == "stopped")
        #expect(log.finish(quitReason: "ignored") == summary)

        let lines = try String(contentsOf: log.url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 5)
        let objects = try lines.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        #expect(objects.map { $0["type"] as? String } == ["event", "frame", "frame", "frame", "summary"])
        #expect(objects[0]["name"] as? String == "connected")
        #expect(objects[2]["frames_lost"] as? Int == 2)
        #expect(objects[2]["decode_ok"] as? Bool == false)
        #expect(objects[1]["decode_ms"] as? Double == 2.0)
        #expect(objects[4]["decode_fail"] as? Int == 1)
        #expect(objects[4]["quit_reason"] as? String == "stopped")
    }

    @Test func p95IgnoresFailedFramesAndIsZeroWithoutDecodes() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = try SessionLog(directory: directory)
        log.record(FrameStats(size: 1, framesLost: 0, recovered: false, decodeOK: false, decodeMilliseconds: 0))
        #expect(log.finish(quitReason: "x").decodeMillisecondsP95 == 0)
    }

    @Test func audioIsLoggedAsBufferLevelPlusGlitchDeltasAndTotalledInTheSummary() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = try SessionLog(directory: directory)
        var stats = AudioStats()
        stats.packets = 100
        stats.bufferedMilliseconds = 40
        log.record(audio: stats)                 // nothing went wrong: only the buffer level
        stats.packets = 200
        stats.concealed = 3
        stats.underruns = 2
        stats.bufferedMilliseconds = 95.5
        log.record(audio: stats)
        stats.underruns = 3
        stats.overflows = 1
        stats.bufferedMilliseconds = 38
        log.record(audio: stats)
        log.record(audio: stats)                 // unchanged: only the buffer level
        let summary = log.finish(quitReason: "stopped")
        log.record(audio: AudioStats())          // after the summary: ignored

        #expect(summary.audioPackets == 200)
        #expect(summary.audioConcealed == 3)
        #expect(summary.audioUnderruns == 3)
        #expect(summary.audioOverflows == 1)
        #expect(summary.audioBufferedMillisecondsMax == 95.5)
        let lines = try String(contentsOf: log.url, encoding: .utf8).split(separator: "\n")
        let objects = try lines.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        #expect(objects.map { $0["type"] as? String }
            == ["audio", "audio", "audio_underrun", "audio", "audio_underrun", "audio_overflow", "audio", "summary"])
        #expect(objects.map { $0["buffered_ms"] as? Double } == [40, 95.5, nil, 38, nil, nil, 38, nil])
        #expect(objects.map { $0["count"] as? Int } == [nil, nil, 2, nil, 1, 1, nil, nil])
        #expect(objects[7]["audio_underruns"] as? Int == 3)
        #expect(objects[7]["audio_overflows"] as? Int == 1)
        #expect(objects[7]["audio_packets"] as? Int == 200)
        #expect(objects[7]["audio_concealed"] as? Int == 3)
        #expect(objects[7]["audio_buffered_ms_max"] as? Double == 95.5)
    }

    @Test func aSessionWithoutAudioReportsZeroes() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let summary = try SessionLog(directory: directory).finish(quitReason: "x")
        #expect(summary.audioPackets == 0)
        #expect(summary.audioUnderruns == 0)
        #expect(summary.audioOverflows == 0)
        #expect(summary.audioBufferedMillisecondsMax == 0)
    }
}
