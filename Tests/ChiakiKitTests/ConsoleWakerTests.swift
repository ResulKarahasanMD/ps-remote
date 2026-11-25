import Foundation
import Testing
@testable import ChiakiKit

final class FakeWakeBackend: WakeBackend, @unchecked Sendable {
    struct Call: Equatable { let host: String; let credential: UInt64 }
    private let lock = NSLock()
    private var recorded: [Call] = []
    var calls: [Call] { lock.withLock { recorded } }
    func wake(host: String, credential: UInt64) throws {
        lock.withLock { recorded.append(Call(host: host, credential: credential)) }
    }
}

@Suite struct ConsoleWakerTests {
    let discoveredPro = Console(id: "50aabbccddee", name: "RED PS5-Pro", address: "192.0.2.16",
                                state: .standby, systemVersion: "14000039")

    @Test func wakesTheFreshlyDiscoveredAddressWithTheHexCredential() throws {
        let backend = FakeWakeBackend()
        let used = try ConsoleWaker(backend: backend)
            .wake(.fixture(address: "192.0.2.5"), discovered: [discoveredPro])
        #expect(used == "192.0.2.16")
        #expect(backend.calls == [.init(host: "192.0.2.16", credential: 0x1234_ABCD)])
    }

    @Test func fallsBackToTheStoredAddressWhenNotDiscovered() throws {
        let backend = FakeWakeBackend()
        #expect(try ConsoleWaker(backend: backend).wake(.fixture(address: "192.0.2.5"), discovered: []) == "192.0.2.5")
    }

    @Test func corruptRegistKeyThrowsAndSendsNothing() {
        let backend = FakeWakeBackend()
        var console = RegisteredConsole.fixture()
        console.registKey = Data("not-hex!".utf8)
        #expect(throws: CredentialError.invalidRegistKey) {
            try ConsoleWaker(backend: backend).wake(console, discovered: [discoveredPro])
        }
        #expect(backend.calls.isEmpty)
    }
}
