import Foundation
import Security

public enum CredentialStoreError: Error, Equatable {
    case accessDenied
    case keychain(OSStatus)
    case corrupted
}

public protocol CredentialStoring: Sendable {
    func save(_ console: RegisteredConsole) throws
    func load(hostID: String) throws -> RegisteredConsole?
    func all() throws -> [RegisteredConsole]
    func delete(hostID: String) throws
    func saveAccountID(_ id: PSNAccountID) throws
    func loadAccountID() throws -> PSNAccountID?
}

enum KeychainStatus {
    /// `true` = found/succeeded, `false` = not found; everything else throws.
    static func interpret(_ status: OSStatus) throws -> Bool {
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        case errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled:
            throw CredentialStoreError.accessDenied
        default:
            throw CredentialStoreError.keychain(status)
        }
    }
}

/// Generic-password items in the login keychain: one per console, one for the account ID.
/// Ad-hoc signed rebuilds change the code identity, so macOS may ask once per build
/// ("Always Allow" fixes it until the next rebuild).
public struct KeychainCredentialStore: CredentialStoring {
    public let service: String
    private static let accountIDKey = "psn-account-id"
    private static let consolePrefix = "console."

    public init(service: String = "com.rak.psremote") {
        self.service = service
    }

    public func save(_ console: RegisteredConsole) throws {
        try write(JSONEncoder().encode(console), account: Self.consoleKey(console.hostID))
    }

    public func load(hostID: String) throws -> RegisteredConsole? {
        try read(account: Self.consoleKey(hostID)).map(Self.decode)
    }

    /// Every decodable console; undecodable items are skipped (see `corruptHostIDs()`).
    public func all() throws -> [RegisteredConsole] {
        try loadAll().consoles
    }

    /// Host IDs of console items whose JSON no longer decodes; remove them with `delete(hostID:)`.
    public func corruptHostIDs() throws -> [String] {
        try loadAll().corrupt
    }

    public func delete(hostID: String) throws {
        _ = try KeychainStatus.interpret(SecItemDelete(query(account: Self.consoleKey(hostID)) as CFDictionary))
    }

    public func saveAccountID(_ id: PSNAccountID) throws {
        try write(Data(id.base64.utf8), account: Self.accountIDKey)
    }

    public func loadAccountID() throws -> PSNAccountID? {
        try read(account: Self.accountIDKey).map { try PSNAccountID(base64: String(decoding: $0, as: UTF8.self)) }
    }

    /// Removes every item of this service (used by tests).
    public func deleteAll() throws {
        for account in try accounts() {
            _ = try KeychainStatus.interpret(SecItemDelete(query(account: account) as CFDictionary))
        }
    }

    // MARK: - Keychain primitives

    private static func consoleKey(_ hostID: String) -> String {
        consolePrefix + ConsoleSelector.normalizedID(hostID)
    }

    private func loadAll() throws -> (consoles: [RegisteredConsole], corrupt: [String]) {
        var consoles: [RegisteredConsole] = []
        var corrupt: [String] = []
        for account in try accounts().filter({ $0.hasPrefix(Self.consolePrefix) }).sorted() {
            guard let data = try read(account: account) else { continue }
            if let console = try? JSONDecoder().decode(RegisteredConsole.self, from: data) {
                consoles.append(console)
            } else {
                corrupt.append(String(account.dropFirst(Self.consolePrefix.count)))
            }
        }
        return (consoles, corrupt)
    }

    private static func decode(_ data: Data) throws -> RegisteredConsole {
        do { return try JSONDecoder().decode(RegisteredConsole.self, from: data) }
        catch { throw CredentialStoreError.corrupted }
    }

    private func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private func write(_ data: Data, account: String) throws {
        let base = query(account: account)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            _ = try KeychainStatus.interpret(SecItemAdd(add as CFDictionary, nil))
        } else {
            _ = try KeychainStatus.interpret(status)
        }
    }

    private func read(account: String) throws -> Data? {
        var request = query(account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard try KeychainStatus.interpret(SecItemCopyMatching(request as CFDictionary, &result)) else { return nil }
        guard let data = result as? Data else { throw CredentialStoreError.corrupted }
        return data
    }

    /// Attributes only: the file-based keychain rejects returning data for kSecMatchLimitAll.
    private func accounts() throws -> [String] {
        let request: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                      kSecAttrService as String: service,
                                      kSecReturnAttributes as String: true,
                                      kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        guard try KeychainStatus.interpret(SecItemCopyMatching(request as CFDictionary, &result)) else { return [] }
        return (result as? [[String: Any]] ?? []).compactMap { $0[kSecAttrAccount as String] as? String }
    }
}
