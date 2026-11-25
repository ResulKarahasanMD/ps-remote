import Foundation
@testable import ChiakiKit

final class FakeRegistrationBackend: RegistrationBackend, @unchecked Sendable {
    struct Call: Equatable { let host: String; let pin: UInt32; let accountID: [UInt8] }
    private let lock = NSLock()
    private var recorded: [Call] = []
    var result: Result<RegisteredConsole, RegistrationError> = .success(.fixture())

    var calls: [Call] { lock.withLock { recorded } }

    func register(host: String, pin: UInt32, accountID: PSNAccountID) async throws -> RegisteredConsole {
        lock.withLock { recorded.append(Call(host: host, pin: pin, accountID: accountID.bytes)) }
        return try result.get()
    }
}
