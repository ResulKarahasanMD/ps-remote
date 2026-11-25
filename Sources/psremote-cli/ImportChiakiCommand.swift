import ChiakiKit
import Foundation

/// Copies chiaki-ng's existing registration(s) and PSN account ID into the Keychain store,
/// so no new PIN registration is needed. Secrets are never printed.
enum ImportChiakiCommand {
    static func run() async throws {
        let prefs = try ChiakiNGImport.loadPreferences()
        let backend = try LiveChiakiBackend(logSink: stderrLogSink())
        let discovered = try await discoverSnapshot(backend: backend, seconds: 3)
        let addresses = Dictionary(discovered.map { (ConsoleSelector.normalizedID($0.id), $0.address) },
                                   uniquingKeysWith: { first, _ in first })
        let consoles = try ChiakiNGImport.consoles(fromPreferences: prefs, addresses: addresses)
        let store = KeychainCredentialStore()
        for console in consoles {
            try store.save(console)
            let address = console.lastKnownAddress.isEmpty ? "address unknown (not seen during discovery)" : console.lastKnownAddress
            print("Imported: \(console.nickname) (\(console.hostID)) @ \(address)")
        }
        if let accountID = try ChiakiNGImport.accountID(fromPreferences: prefs) {
            try store.saveAccountID(accountID)
            print("PSN Account-ID imported too.")
        }
    }
}
