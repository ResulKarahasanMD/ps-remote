import CChiaki
import Darwin
import Foundation

/// Runs a libchiaki `ChiakiDiscoveryService` (broadcast to 255.255.255.255; the service
/// itself targets both the PS4 and PS5 discovery ports).
final class LiveDiscoveryHandle: DiscoveryHandle, @unchecked Sendable {
    private let service = UnsafeMutablePointer<ChiakiDiscoveryService>.allocate(capacity: 1)
    private let logger: ChiakiLogger
    private let onHosts: @Sendable ([DiscoveredHost]) -> Void
    private let lock = NSLock()
    private var running = false

    init(logger: ChiakiLogger, onHosts: @escaping @Sendable ([DiscoveredHost]) -> Void) throws {
        self.logger = logger
        self.onHosts = onHosts
        service.initialize(to: ChiakiDiscoveryService())

        var broadcast = sockaddr_in()
        broadcast.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        broadcast.sin_family = sa_family_t(AF_INET)
        broadcast.sin_addr.s_addr = 0xFFFF_FFFF
        var storage = sockaddr_storage()
        withUnsafeBytes(of: &broadcast) { source in
            withUnsafeMutableBytes(of: &storage) { $0.copyMemory(from: source) }
        }

        var options = ChiakiDiscoveryServiceOptions()
        options.hosts_max = 16
        options.host_drop_pings = 3
        options.ping_ms = 500
        options.cb = discoveryServiceCallback
        options.cb_user = Unmanaged.passUnretained(self).toOpaque()
        // chiaki_discovery_service_init copies send_addr (discoveryservice.c), so a stack pointer is fine.
        let err = withUnsafeMutablePointer(to: &storage) { address -> ChiakiErrorCode in
            options.send_addr = address
            options.send_addr_size = MemoryLayout<sockaddr_in>.size
            return chiaki_discovery_service_init(service, &options, logger.pointer)
        }
        guard err == CHIAKI_ERR_SUCCESS else { throw ChiakiError(code: err) }
        lock.withLock { running = true }
    }

    func stop() {
        let wasRunning = lock.withLock { () -> Bool in
            defer { running = false }
            return running
        }
        if wasRunning { chiaki_discovery_service_fini(service) } // joins the service thread
    }

    deinit {
        stop()
        service.deinitialize(count: 1)
        service.deallocate()
    }

    fileprivate func deliver(_ hosts: [DiscoveredHost]) {
        onHosts(hosts)
    }
}

private func discoveryServiceCallback(hosts: UnsafeMutablePointer<ChiakiDiscoveryHost>?, count: Int, user: UnsafeMutableRawPointer?) {
    guard let user else { return }
    let handle = Unmanaged<LiveDiscoveryHandle>.fromOpaque(user).takeUnretainedValue()
    guard let hosts else { handle.deliver([]); return }
    handle.deliver((0..<count).map { DiscoveredHost(cHost: hosts[$0]) })
}

extension DiscoveredHost {
    init(cHost host: ChiakiDiscoveryHost) {
        func text(_ pointer: UnsafePointer<CChar>?) -> String { pointer.map { String(cString: $0) } ?? "" }
        let state: HostState = switch host.state {
        case CHIAKI_DISCOVERY_HOST_STATE_READY: .ready
        case CHIAKI_DISCOVERY_HOST_STATE_STANDBY: .standby
        default: .unknown
        }
        self.init(state: state,
                  address: text(host.host_addr),
                  name: text(host.host_name),
                  hostType: text(host.host_type),
                  hostID: text(host.host_id),
                  systemVersion: text(host.system_version),
                  runningAppName: host.running_app_name.map { String(cString: $0) })
    }
}
