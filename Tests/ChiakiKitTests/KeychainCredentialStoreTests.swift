import Foundation
import Security
import Testing
@testable import ChiakiKit

@Suite(.serialized) struct KeychainCredentialStoreTests {
    @Test func savesLoadsListsAndDeletesConsoles() throws {
        let store = KeychainCredentialStore(service: "com.rak.psremote.tests.\(UUID().uuidString)")
        defer { try? store.deleteAll() }

        #expect(try store.load(hostID: "50AABBCCDDEE") == nil)
        try store.save(.fixture())
        try store.save(.fixture(hostID: "AAAAAAAAAAAA", address: "192.0.2.30"))
        #expect(try store.load(hostID: "50aabbccddee") == .fixture())
        #expect(try store.all().map(\.hostID) == ["50AABBCCDDEE", "AAAAAAAAAAAA"])

        try store.save(.fixture(address: "192.0.2.99"))   // overwrite, not duplicate
        #expect(try store.load(hostID: "50AABBCCDDEE")?.lastKnownAddress == "192.0.2.99")

        try store.delete(hostID: "50AABBCCDDEE")
        #expect(try store.load(hostID: "50AABBCCDDEE") == nil)
    }

    @Test func storesAccountID() throws {
        let store = KeychainCredentialStore(service: "com.rak.psremote.tests.\(UUID().uuidString)")
        defer { try? store.deleteAll() }
        #expect(try store.loadAccountID() == nil)
        try store.saveAccountID(try PSNAccountID(base64: "AQIDBAUGBwg="))
        #expect(try store.loadAccountID()?.base64 == "AQIDBAUGBwg=")
    }

    @Test func oneCorruptItemDoesNotHideTheOthersAndCanBeForgotten() throws {
        let service = "com.rak.psremote.tests.\(UUID().uuidString)"
        let store = KeychainCredentialStore(service: service)
        defer { try? store.deleteAll() }
        try store.save(.fixture())
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: service,
                                  kSecAttrAccount as String: "console.BADBADBADBAD",
                                  kSecValueData as String: Data("{not json".utf8)]
        #expect(SecItemAdd(add as CFDictionary, nil) == errSecSuccess)

        #expect(try store.all() == [.fixture()])
        #expect(try store.corruptHostIDs() == ["BADBADBADBAD"])

        try store.delete(hostID: "badbadbadbad")
        #expect(try store.corruptHostIDs().isEmpty)
        #expect(try store.all() == [.fixture()])
    }

    @Test func statusInterpretation() throws {
        #expect(try KeychainStatus.interpret(errSecSuccess) == true)
        #expect(try KeychainStatus.interpret(errSecItemNotFound) == false)
        #expect(throws: CredentialStoreError.accessDenied) { try KeychainStatus.interpret(errSecInteractionNotAllowed) }
        #expect(throws: CredentialStoreError.keychain(errSecParam)) { try KeychainStatus.interpret(errSecParam) }
    }
}
