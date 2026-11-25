import CChiaki
import Testing
@testable import ChiakiKit

@Suite struct ChiakiLibraryTests {
    @Test func headersAndArchiveAreReachable() {
        #expect(String(cString: chiaki_error_string(CHIAKI_ERR_TIMEOUT)) == "Timeout")
    }

    @Test func initializeIsIdempotent() throws {
        try ChiakiLibrary.initialize()
        try ChiakiLibrary.initialize()
    }

    @Test func errorDescriptionUsesLibchiakiText() {
        #expect(ChiakiError(code: CHIAKI_ERR_HOST_DOWN).description == "Host is down")
    }
}
