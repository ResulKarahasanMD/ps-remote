import Foundation

public enum CredentialError: Error, Equatable {
    case invalidAccountID
    case accountIDWrongLength(Int)
    case invalidRegistKey
}

/// What libchiaki's registration returns, in a storable form.
public struct RegisteredConsole: Codable, Sendable, Equatable {
    /// Server MAC as 12 upper-case hex digits; equals discovery's host ID.
    public var hostID: String
    public var nickname: String
    public var lastKnownAddress: String
    public var target: UInt32
    /// `rp_regist_key`: ASCII hex, NUL-padded to 16 bytes.
    public var registKey: Data
    public var rpKeyType: UInt32
    public var rpKey: Data
    public var consolePin: UInt32

    public init(hostID: String, nickname: String, lastKnownAddress: String, target: UInt32,
                registKey: Data, rpKeyType: UInt32, rpKey: Data, consolePin: UInt32) {
        self.hostID = ConsoleSelector.normalizedID(hostID)
        self.nickname = nickname
        self.lastKnownAddress = lastKnownAddress
        self.target = target
        self.registKey = registKey
        self.rpKeyType = rpKeyType
        self.rpKey = rpKey
        self.consolePin = consolePin
    }
}

/// The 8-byte PSN account ID, entered as base64 (standard or URL-safe, padding optional).
public struct PSNAccountID: Sendable, Equatable {
    public let bytes: [UInt8]

    public init(base64 raw: String) throws {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        guard let data = Data(base64Encoded: text) else { throw CredentialError.invalidAccountID }
        guard data.count == 8 else { throw CredentialError.accountIDWrongLength(data.count) }
        bytes = Array(data)
    }

    public var base64: String { Data(bytes).base64EncodedString() }
}

public enum WakeCredential {
    /// libchiaki wakes a console with the regist key "interpreted as hex" (discovery.h).
    public static func from(registKey: Data) throws -> UInt64 {
        let ascii = registKey.prefix { $0 != 0 }
        guard !ascii.isEmpty, ascii.count <= 16,
              let text = String(bytes: ascii, encoding: .ascii),
              let value = UInt64(text, radix: 16)
        else { throw CredentialError.invalidRegistKey }
        return value
    }
}
