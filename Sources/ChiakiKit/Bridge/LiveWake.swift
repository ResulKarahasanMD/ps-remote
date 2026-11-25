import CChiaki

extension LiveChiakiBackend: WakeBackend {
    public func wake(host: String, credential: UInt64) throws {
        let logger = ChiakiLogger(sink: logSink)
        // NULL discovery: libchiaki opens a temporary socket for the single packet (discovery.c).
        let err = withExtendedLifetime(logger) {
            host.withCString { chiaki_discovery_wakeup(logger.pointer, nil, $0, credential, true) }
        }
        guard err == CHIAKI_ERR_SUCCESS else { throw ChiakiError(code: err) }
    }
}
