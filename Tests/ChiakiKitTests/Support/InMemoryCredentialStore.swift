import Foundation
@testable import ChiakiKit

final class InMemoryCredentialStore: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var consoles: [String: RegisteredConsole] = [:]
    private var accountID: PSNAccountID?

    func save(_ console: RegisteredConsole) throws { lock.withLock { consoles[console.hostID] = console } }
    func load(hostID: String) throws -> RegisteredConsole? { lock.withLock { consoles[hostID.uppercased()] } }
    func all() throws -> [RegisteredConsole] { lock.withLock { consoles.values.sorted { $0.hostID < $1.hostID } } }
    func delete(hostID: String) throws { _ = lock.withLock { consoles.removeValue(forKey: hostID.uppercased()) } }
    func saveAccountID(_ id: PSNAccountID) throws { lock.withLock { accountID = id } }
    func loadAccountID() throws -> PSNAccountID? { lock.withLock { accountID } }
}

extension RegisteredConsole {
    static func fixture(hostID: String = "50AABBCCDDEE", address: String = "192.0.2.16") -> RegisteredConsole {
        var key = Data("1234abcd".utf8)
        key.append(contentsOf: [UInt8](repeating: 0, count: 8))
        return RegisteredConsole(hostID: hostID, nickname: "RED PS5-Pro", lastKnownAddress: address,
                                 target: 1_000_100, registKey: key, rpKeyType: 0,
                                 rpKey: Data(repeating: 7, count: 16), consolePin: 0)
    }
}
