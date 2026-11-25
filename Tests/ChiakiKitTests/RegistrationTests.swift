import Testing
@testable import ChiakiKit

@Suite struct RegistrationTests {
    @Test(arguments: ["12345678", "1234 5678", "1234-5678", "01234567"])
    func pinAcceptsEightDigitsIgnoringSpacesAndDashes(text: String) throws {
        let digits = text.filter(\.isNumber)
        #expect(try RemotePlayPIN(text).value == UInt32(digits)!)
    }

    @Test(arguments: ["1234567", "123456789", "1234abcd", "", "１２３４５６７８"])
    func pinRejectsWrongLengthOrNonASCIIDigits(text: String) {
        #expect(throws: RegistrationError.invalidPIN) { try RemotePlayPIN(text) }
    }

    @Test func httpRejectionIsClassifiedWithTheReportedReason() {
        let error = RegistrationFailureClassifier.classify([
            "Regist received HTTP code 403",
            "Reported Application Reason: 0x80108b10 (Some Reason)",
        ])
        #expect(error == .rejected(reason: "Some Reason"))
    }

    @Test func httpRejectionWithoutReasonHeader() {
        #expect(RegistrationFailureClassifier.classify(["Regist received HTTP code 500"]) == .rejected(reason: nil))
    }

    @Test func otherFailuresAreNetworkErrorsCarryingTheLastLine() {
        let error = RegistrationFailureClassifier.classify([
            "Regist connect failed, error: Connection refused. Trying next address...",
            "Regist connect failed: tried all addresses",
        ])
        #expect(error == .network("Regist connect failed: tried all addresses"))
        #expect(RegistrationFailureClassifier.classify([]) == .network("Unknown registration error"))
    }

    @Test func registrationValidatesPINBeforeContactingTheConsole() async {
        let backend = FakeRegistrationBackend()
        let store = InMemoryCredentialStore()
        try? store.saveAccountID(try! PSNAccountID(base64: "AQIDBAUGBwg="))
        let registration = ConsoleRegistration(backend: backend, store: store)
        await #expect(throws: RegistrationError.invalidPIN) {
            try await registration.register(address: "192.0.2.16", pin: "123")
        }
        #expect(backend.calls.isEmpty)
    }

    @Test func registrationRequiresAStoredAccountID() async {
        let registration = ConsoleRegistration(backend: FakeRegistrationBackend(), store: InMemoryCredentialStore())
        await #expect(throws: RegistrationError.missingAccountID) {
            try await registration.register(address: "192.0.2.16", pin: "12345678")
        }
    }

    @Test func successfulRegistrationIsPersisted() async throws {
        let backend = FakeRegistrationBackend()
        let store = InMemoryCredentialStore()
        try store.saveAccountID(try PSNAccountID(base64: "AQIDBAUGBwg="))
        let console = try await ConsoleRegistration(backend: backend, store: store)
            .register(address: "192.0.2.16", pin: "1234 5678")
        #expect(backend.calls == [.init(host: "192.0.2.16", pin: 12_345_678, accountID: [1, 2, 3, 4, 5, 6, 7, 8])])
        #expect(try store.load(hostID: console.hostID) == console)
    }

    @Test func failedRegistrationStoresNothing() async throws {
        let backend = FakeRegistrationBackend()
        backend.result = .failure(.rejected(reason: nil))
        let store = InMemoryCredentialStore()
        try store.saveAccountID(try PSNAccountID(base64: "AQIDBAUGBwg="))
        await #expect(throws: RegistrationError.rejected(reason: nil)) {
            try await ConsoleRegistration(backend: backend, store: store).register(address: "192.0.2.16", pin: "12345678")
        }
        #expect(try store.all().isEmpty)
    }
}
