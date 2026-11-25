import ChiakiKit
import Foundation

enum WakeCommand {
    static func run(arguments: [String]) async throws {
        let store = KeychainCredentialStore()
        let registered = try store.all()
        guard !registered.isEmpty else { fail("No registered consoles. Run first: psremote-cli register", code: 2) }

        let backend = try LiveChiakiBackend(logSink: stderrLogSink())
        let discovered = try await discoverSnapshot(backend: backend, seconds: 3)
        let target = try pick(arguments.first, from: registered)

        if let current = discovered.first(where: { ConsoleSelector.normalizedID($0.id) == target.hostID }),
           current.state == .ready {
            print("\(target.nickname) is already on (\(current.address)).")
            return
        }

        let address = try ConsoleWaker(backend: backend).wake(target, discovered: discovered)
        print("Wake packet sent: \(target.nickname) @ \(address)")

        let clock = ContinuousClock()
        let started = clock.now
        if try await waitUntilReady(backend: backend, hostID: target.hostID, timeout: .seconds(30)) {
            print("\(target.nickname) is ready (\((clock.now - started).components.seconds) s).")
            return
        }
        fail("The PS5 did not report 'ready' within 30 s. On the PS5, are 'Stay Connected to the Internet' and 'Enable Turning On PS5 from Network' turned on?", code: 3)
    }

    /// Matches by nickname or host ID among registered consoles; requires a name when several exist.
    private static func pick(_ query: String?, from registered: [RegisteredConsole]) throws -> RegisteredConsole {
        let asConsoles = registered.map {
            Console(id: $0.hostID, name: $0.nickname, address: $0.lastKnownAddress, state: .unknown, systemVersion: "")
        }
        let chosen = try ConsoleSelector.select(query, from: asConsoles)
        return registered.first { $0.hostID == ConsoleSelector.normalizedID(chosen.id) }!
    }
}
