import Foundation

public struct RemotePlayPIN: Sendable, Equatable {
    public let value: UInt32

    /// Exactly 8 ASCII digits; spaces and dashes are ignored ("1234 5678").
    public init(_ text: String) throws {
        let digits = text.filter { $0 != " " && $0 != "-" }
        guard digits.count == 8, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = UInt32(digits)
        else { throw RegistrationError.invalidPIN }
        self.value = value
    }
}

public enum RegistrationError: Error, Equatable, Sendable {
    case invalidPIN
    case missingAccountID
    /// The console answered with a non-200 HTTP code (wrong/expired PIN, device limit, ...).
    case rejected(reason: String?)
    case network(String)
    case canceled
}

extension RegistrationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidPIN:
            "The PIN must be 8 digits (PS5: Settings → System → Remote Play → Link Device)."
        case .missingAccountID:
            "No PSN Account-ID is saved. Run first: psremote-cli set-account <base64>"
        case .rejected(let reason):
            "The PS5 rejected the registration\(reason.map { " (\($0))" } ?? ""). The PIN may have expired or be wrong; get a new PIN on the PS5."
        case .network(let line):
            "Could not reach the PS5: \(line). Is the PS5 on and showing the 'Link Device' screen?"
        case .canceled:
            "Registration canceled."
        }
    }
}

/// libchiaki reports only FINISHED_FAILED; the error log lines tell rejection from network failure.
enum RegistrationFailureClassifier {
    static func classify(_ errorLines: [String]) -> RegistrationError {
        if errorLines.contains(where: { $0.contains("Regist received HTTP code") }) {
            return .rejected(reason: errorLines.lazy.compactMap(reason(from:)).first)
        }
        return .network(errorLines.last ?? "Unknown registration error")
    }

    /// "Reported Application Reason: 0x80108b10 (Some Reason)" → "Some Reason"
    private static func reason(from line: String) -> String? {
        guard line.contains("Reported Application Reason"),
              let open = line.lastIndex(of: "("), let close = line.lastIndex(of: ")"), open < close
        else { return nil }
        return String(line[line.index(after: open)..<close])
    }
}

public protocol RegistrationBackend: Sendable {
    func register(host: String, pin: UInt32, accountID: PSNAccountID) async throws -> RegisteredConsole
}

public struct ConsoleRegistration: Sendable {
    private let backend: any RegistrationBackend
    private let store: any CredentialStoring

    public init(backend: any RegistrationBackend, store: any CredentialStoring) {
        self.backend = backend
        self.store = store
    }

    public func register(address: String, pin: String) async throws -> RegisteredConsole {
        let pin = try RemotePlayPIN(pin)
        guard let accountID = try store.loadAccountID() else { throw RegistrationError.missingAccountID }
        let console = try await backend.register(host: address, pin: pin.value, accountID: accountID)
        try store.save(console)
        return console
    }
}
