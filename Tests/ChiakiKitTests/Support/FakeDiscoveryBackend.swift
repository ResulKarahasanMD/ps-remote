import Foundation
@testable import ChiakiKit

final class FakeDiscoveryBackend: DiscoveryBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var onHosts: (@Sendable ([DiscoveredHost]) -> Void)?
    private var stops = 0
    var startError: (any Error)?

    var stopCount: Int { lock.withLock { stops } }

    func startDiscovery(onHosts: @escaping @Sendable ([DiscoveredHost]) -> Void) throws -> any DiscoveryHandle {
        if let startError { throw startError }
        lock.withLock { self.onHosts = onHosts }
        return FakeDiscoveryHandle { [self] in lock.withLock { stops += 1 } }
    }

    func emit(_ hosts: [DiscoveredHost]) {
        let callback = lock.withLock { onHosts }
        callback?(hosts)
    }
}

struct FakeDiscoveryHandle: DiscoveryHandle {
    let onStop: @Sendable () -> Void
    func stop() { onStop() }
}

extension DiscoveredHost {
    static func fixture(
        name: String = "RED PS5-Pro",
        address: String = "192.0.2.16",
        state: HostState = .standby,
        hostType: String = "PS5",
        hostID: String = "50AABBCCDDEE",
        systemVersion: String = "14000039"
    ) -> DiscoveredHost {
        DiscoveredHost(state: state, address: address, name: name, hostType: hostType,
                       hostID: hostID, systemVersion: systemVersion, runningAppName: nil)
    }
}
