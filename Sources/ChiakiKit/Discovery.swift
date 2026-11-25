public enum HostState: Sendable, Equatable {
    case ready, standby, unknown
}

/// One host as reported by libchiaki's discovery service (any console type).
public struct DiscoveredHost: Sendable, Equatable {
    public var state: HostState
    public var address: String
    public var name: String
    public var hostType: String
    public var hostID: String
    public var systemVersion: String
    public var runningAppName: String?

    public init(state: HostState, address: String, name: String, hostType: String,
                hostID: String, systemVersion: String, runningAppName: String?) {
        self.state = state
        self.address = address
        self.name = name
        self.hostType = hostType
        self.hostID = hostID
        self.systemVersion = systemVersion
        self.runningAppName = runningAppName
    }
}

/// A PS5 found on the LAN.
public struct Console: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var address: String
    public var state: HostState
    public var systemVersion: String

    public init(id: String, name: String, address: String, state: HostState, systemVersion: String) {
        self.id = id
        self.name = name
        self.address = address
        self.state = state
        self.systemVersion = systemVersion
    }

    public var summaryLine: String {
        let stateText = switch state {
        case .ready: "ready"
        case .standby: "standby"
        case .unknown: "unknown"
        }
        return [name, address, stateText, id].joined(separator: "\t")
    }
}

public protocol DiscoveryHandle: Sendable {
    func stop()
}

public protocol DiscoveryBackend: Sendable {
    /// Starts periodic discovery; `onHosts` receives the full current host list on every change.
    func startDiscovery(onHosts: @escaping @Sendable ([DiscoveredHost]) -> Void) throws -> any DiscoveryHandle
}

public struct ConsoleDiscovery: Sendable {
    private let backend: any DiscoveryBackend

    public init(backend: any DiscoveryBackend) {
        self.backend = backend
    }

    /// Current PS5 list, re-emitted on every change. Cancelling the consumer stops discovery.
    public func consoles() -> AsyncThrowingStream<[Console], Error> {
        AsyncThrowingStream { continuation in
            do {
                let handle = try backend.startDiscovery { hosts in
                    continuation.yield(Self.consoles(from: hosts))
                }
                continuation.onTermination = { _ in handle.stop() }
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    static func consoles(from hosts: [DiscoveredHost]) -> [Console] {
        hosts
            .filter { $0.hostType == "PS5" }
            .map { Console(id: $0.hostID, name: $0.name, address: $0.address,
                           state: $0.state, systemVersion: $0.systemVersion) }
            .sorted { $0.name < $1.name }
    }
}
