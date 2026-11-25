import Foundation

public struct SessionSummary: Codable, Sendable, Equatable {
    public var durationSeconds: Double
    public var frames: Int
    public var decodeFailures: Int
    public var framesLostTotal: Int
    public var decodeMillisecondsP95: Double
    public var audioPackets: Int
    public var audioConcealed: Int
    public var audioUnderruns: Int
    public var audioOverflows: Int
    public var audioBufferedMillisecondsMax: Double
    public var quitReason: String
}

/// Per-session JSONL log (spec §6): one object per line, `summary` last.
public final class SessionLog: @unchecked Sendable {
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/PSRemote")
    }

    public let url: URL
    private let handle: FileHandle
    private let clock = ContinuousClock()
    private let started: ContinuousClock.Instant
    private let lock = NSLock()
    private var frames = 0
    private var failures = 0
    private var lostTotal = 0
    private var decodeTimes: [Double] = []
    private var audio = AudioStats()
    private var audioBufferedMax = 0.0
    private var summary: SessionSummary?

    public init(directory: URL = SessionLog.defaultDirectory, now: Date = Date()) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        url = directory.appending(path: "session-\(stamp).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        started = clock.now
    }

    public func record(_ frame: FrameStats) {
        lock.withLock {
            guard summary == nil else { return }
            frames += 1
            lostTotal += Int(frame.framesLost)
            if frame.decodeOK { decodeTimes.append(frame.decodeMilliseconds) } else { failures += 1 }
            write(["type": "frame", "t": elapsed(), "size": frame.size, "frames_lost": Int(frame.framesLost),
                   "recovered": frame.recovered, "decode_ok": frame.decodeOK, "decode_ms": frame.decodeMilliseconds])
        }
    }

    public func record(event name: String) {
        lock.withLock {
            guard summary == nil else { return }
            write(["type": "event", "t": elapsed(), "name": name])
        }
    }

    /// Records the audio buffer level, and the glitches since the previous call: one line per kind,
    /// with their count.
    public func record(audio stats: AudioStats) {
        lock.withLock {
            guard summary == nil else { return }
            let underruns = stats.underruns - audio.underruns
            let overflows = stats.overflows - audio.overflows
            audio = stats
            audioBufferedMax = max(audioBufferedMax, stats.bufferedMilliseconds)
            write(["type": "audio", "t": elapsed(), "buffered_ms": stats.bufferedMilliseconds])
            if underruns > 0 { write(["type": "audio_underrun", "t": elapsed(), "count": underruns]) }
            if overflows > 0 { write(["type": "audio_overflow", "t": elapsed(), "count": overflows]) }
        }
    }

    @discardableResult
    public func finish(quitReason: String) -> SessionSummary {
        lock.withLock {
            if let summary { return summary }
            let sorted = decodeTimes.sorted()
            let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
            let result = SessionSummary(durationSeconds: elapsed(), frames: frames, decodeFailures: failures,
                                        framesLostTotal: lostTotal, decodeMillisecondsP95: p95,
                                        audioPackets: audio.packets, audioConcealed: audio.concealed,
                                        audioUnderruns: audio.underruns, audioOverflows: audio.overflows,
                                        audioBufferedMillisecondsMax: audioBufferedMax,
                                        quitReason: quitReason)
            write(["type": "summary", "duration_s": result.durationSeconds, "frames": result.frames,
                   "decode_fail": result.decodeFailures, "frames_lost_total": result.framesLostTotal,
                   "decode_ms_p95": result.decodeMillisecondsP95, "audio_packets": result.audioPackets,
                   "audio_concealed": result.audioConcealed, "audio_underruns": result.audioUnderruns,
                   "audio_overflows": result.audioOverflows,
                   "audio_buffered_ms_max": result.audioBufferedMillisecondsMax, "quit_reason": result.quitReason])
            try? handle.close()
            summary = result
            return result
        }
    }

    // MARK: - Private (lock held)

    private func elapsed() -> Double {
        let duration = clock.now - started
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        handle.write(data + Data("\n".utf8))
    }
}
