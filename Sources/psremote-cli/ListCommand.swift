import ChiakiKit
import Foundation

enum ListCommand {
    static func run() throws {
        let store = KeychainCredentialStore()
        let consoles = try store.all()
        for hostID in try store.corruptHostIDs() {
            FileHandle.standardError.write(Data("Warning: cannot read the entry for \(hostID). To delete it: psremote-cli forget \(hostID)\n".utf8))
        }
        guard !consoles.isEmpty else { fail("No registered consoles.", code: 2) }
        for console in consoles {
            print([console.nickname, console.hostID, console.lastKnownAddress].joined(separator: "\t"))
        }
    }
}

enum ForgetCommand {
    static func run(arguments: [String]) throws {
        guard let hostID = arguments.first else {
            fail("Usage: psremote-cli forget <host id>", code: 64)
        }
        try KeychainCredentialStore().delete(hostID: hostID)
        print("Deleted (if present): \(ConsoleSelector.normalizedID(hostID))")
    }
}
