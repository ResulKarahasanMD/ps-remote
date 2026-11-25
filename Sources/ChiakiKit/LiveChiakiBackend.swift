/// Production backend: talks to libchiaki. One instance per app/CLI run is enough.
public struct LiveChiakiBackend: DiscoveryBackend {
    let logSink: @Sendable (LogLevel, String) -> Void

    public init(logSink: @escaping @Sendable (LogLevel, String) -> Void = { _, _ in }) throws {
        try ChiakiLibrary.initialize()
        self.logSink = logSink
    }

    public func startDiscovery(onHosts: @escaping @Sendable ([DiscoveredHost]) -> Void) throws -> any DiscoveryHandle {
        try LiveDiscoveryHandle(logger: ChiakiLogger(sink: logSink), onHosts: onHosts)
    }
}
