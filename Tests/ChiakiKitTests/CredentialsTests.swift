import Foundation
import Testing
@testable import ChiakiKit

@Suite struct CredentialsTests {
    @Test func accountIDAcceptsStandardBase64() throws {
        #expect(try PSNAccountID(base64: "AQIDBAUGBwg=").bytes == [1, 2, 3, 4, 5, 6, 7, 8])
    }

    @Test func accountIDTrimsWhitespaceAndAcceptsURLSafeUnpadded() throws {
        // bytes [251, 255, 190, 0, 1, 2, 3, 4] → standard "+/++AAECAwQ=" → URL-safe unpadded "-_--AAECAwQ"
        let id = try PSNAccountID(base64: "  -_--AAECAwQ\n")
        #expect(id.bytes == [251, 255, 190, 0, 1, 2, 3, 4])
        #expect(id.base64 == "+/++AAECAwQ=")
    }

    @Test func accountIDRejectsWrongLengthWithTheLength() {
        #expect(throws: CredentialError.accountIDWrongLength(4)) { try PSNAccountID(base64: "AQIDBA==") }
    }

    @Test func accountIDRejectsGarbage() {
        #expect(throws: CredentialError.invalidAccountID) { try PSNAccountID(base64: "not base64 !!") }
    }

    @Test func wakeCredentialIsRegistKeyReadAsHexUntilFirstNUL() throws {
        var key = Data("1234abcd".utf8)
        key.append(contentsOf: [UInt8](repeating: 0, count: 8))
        #expect(try WakeCredential.from(registKey: key) == 0x1234_ABCD)
    }

    @Test(arguments: [Data(), Data([0, 0, 0]), Data("zz12".utf8), Data("12345678901234567".utf8)])
    func wakeCredentialRejectsEmptyNonHexOrOverlong(key: Data) {
        #expect(throws: CredentialError.invalidRegistKey) { try WakeCredential.from(registKey: key) }
    }

    @Test func registeredConsoleRoundTripsThroughJSON() throws {
        let console = RegisteredConsole.fixture()
        let decoded = try JSONDecoder().decode(RegisteredConsole.self, from: JSONEncoder().encode(console))
        #expect(decoded == console)
    }
}
