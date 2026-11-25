import ChiakiKit
import Foundation

enum ListCommand {
    static func run() throws {
        let store = KeychainCredentialStore()
        let consoles = try store.all()
        for hostID in try store.corruptHostIDs() {
            FileHandle.standardError.write(Data("Uyarı: \(hostID) kaydı okunamıyor. Silmek için: psremote-cli forget \(hostID)\n".utf8))
        }
        guard !consoles.isEmpty else { fail("Kayıtlı konsol yok.", code: 2) }
        for console in consoles {
            print([console.nickname, console.hostID, console.lastKnownAddress].joined(separator: "\t"))
        }
    }
}

enum ForgetCommand {
    static func run(arguments: [String]) throws {
        guard let hostID = arguments.first else {
            fail("Kullanım: psremote-cli forget <host id>", code: 64)
        }
        try KeychainCredentialStore().delete(hostID: hostID)
        print("Silindi (varsa): \(ConsoleSelector.normalizedID(hostID))")
    }
}
