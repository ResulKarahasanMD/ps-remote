public protocol WakeBackend: Sendable {
    func wake(host: String, credential: UInt64) throws
}

public struct ConsoleWaker: Sendable {
    private let backend: any WakeBackend

    public init(backend: any WakeBackend) {
        self.backend = backend
    }

    /// Sends the wake packet to the console's current address and returns that address.
    public func wake(_ console: RegisteredConsole, discovered: [Console]) throws -> String {
        let credential = try WakeCredential.from(registKey: console.registKey)
        let address = ConsoleSelector.address(for: console, discovered: discovered)
        try backend.wake(host: address, credential: credential)
        return address
    }
}
