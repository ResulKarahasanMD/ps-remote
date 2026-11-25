import ChiakiKit
import Foundation

enum RegisterCommand {
    static func run(arguments: [String]) async throws {
        guard arguments.count == 2 else {
            fail("Usage: psremote-cli register \"<console name|host id|ip>\" <8-digit PIN>", code: 64)
        }
        let backend = try LiveChiakiBackend(logSink: stderrLogSink())
        let address: String
        if IPv4Address(arguments[0]) != nil {
            address = arguments[0]
        } else {
            let consoles = try await discoverSnapshot(backend: backend, seconds: 4)
            address = try ConsoleSelector.select(arguments[0], from: consoles).address
        }
        do {
            let console = try await ConsoleRegistration(backend: backend, store: KeychainCredentialStore())
                .register(address: address, pin: arguments[1])
            print("Registered: \(console.nickname) (\(console.hostID)) @ \(console.lastKnownAddress)")
        } catch let error as RegistrationError {
            fail(error.localizedDescription)
        }
    }
}

/// Minimal dotted-quad check; avoids pulling in Network.framework for one comparison.
struct IPv4Address {
    init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) else { return nil }
    }
}
