import ChiakiKit
import Foundation

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

/// libchiaki warnings/errors go to stderr; everything with PSREMOTE_VERBOSE=1.
func stderrLogSink() -> @Sendable (LogLevel, String) -> Void {
    let verbose = ProcessInfo.processInfo.environment["PSREMOTE_VERBOSE"] == "1"
    return { level, line in
        guard verbose || level == .error || level == .warning else { return }
        FileHandle.standardError.write(Data("[chiaki \(level)] \(line)\n".utf8))
    }
}

actor LatestConsoles {
    private(set) var value: [Console] = []
    func set(_ consoles: [Console]) { value = consoles }
}

/// Runs discovery for `seconds` and returns the last reported PS5 list.
func discoverSnapshot(backend: any DiscoveryBackend, seconds: Double) async throws -> [Console] {
    let latest = LatestConsoles()
    let stream = ConsoleDiscovery(backend: backend).consoles()
    let consumer = Task {
        for try await consoles in stream { await latest.set(consoles) }
    }
    try await Task.sleep(for: .seconds(seconds))
    consumer.cancel()
    if case .failure(let error) = await consumer.result, !(error is CancellationError) { throw error }
    return await latest.value
}

/// Polls discovery until the console with `hostID` reports ready, or `timeout` elapses.
func waitUntilReady(backend: any DiscoveryBackend, hostID: String, timeout: Duration) async throws -> Bool {
    let clock = ContinuousClock()
    let started = clock.now
    while clock.now - started < timeout {
        let consoles = try await discoverSnapshot(backend: backend, seconds: 2)
        if consoles.contains(where: { ConsoleSelector.normalizedID($0.id) == hostID && $0.state == .ready }) { return true }
    }
    return false
}
