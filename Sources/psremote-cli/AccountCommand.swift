import ChiakiKit

enum AccountCommand {
    static func run(arguments: [String]) throws {
        guard let raw = arguments.first else {
            fail("Kullanım: psremote-cli set-account <PSN Account-ID, base64>", code: 64)
        }
        let id = try PSNAccountID(base64: raw)
        try KeychainCredentialStore().saveAccountID(id)
        print("PSN Account-ID kaydedildi (8 bayt).")
    }
}
