import Testing
@testable import ChiakiKit

@Suite struct LiveRegistrationCancelTests {
    /// A cancel that arrives before chiaki_regist_start must not be lost: run() ends as .canceled
    /// quickly instead of contacting the console and possibly succeeding.
    @Test func cancelBeforeRunEndsAsCanceledWithoutContactingTheConsole() async throws {
        try ChiakiLibrary.initialize()
        let registration = LiveRegistration(host: "192.0.2.1", logSink: { _, _ in })   // TEST-NET-1, unroutable
        registration.cancel()
        let accountID = try PSNAccountID(base64: "AQIDBAUGBwg=")
        await #expect(throws: RegistrationError.canceled) {
            try await withTimeout(seconds: 3) {
                try await registration.run(pin: 12_345_678, accountID: accountID)
            }
        }
    }
}
