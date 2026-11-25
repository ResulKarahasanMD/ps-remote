import ChiakiKit

enum DiscoverCommand {
    static func run(arguments: [String]) async throws {
        let seconds = arguments.first.flatMap(Double.init) ?? 4
        let backend = try LiveChiakiBackend(logSink: stderrLogSink())
        let consoles = try await discoverSnapshot(backend: backend, seconds: seconds)
        guard !consoles.isEmpty else { fail("PS5 bulunamadı (\(Int(seconds)) sn).", code: 2) }
        consoles.forEach { print($0.summaryLine) }
    }
}
