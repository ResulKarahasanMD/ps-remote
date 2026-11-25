import Testing
@testable import ChiakiKit

@Suite struct ConsoleSelectorTests {
    let pro = Console(id: "50AABBCCDDEE", name: "RED PS5-Pro", address: "192.0.2.16", state: .standby, systemVersion: "14000039")
    let other = Console(id: "AAAAAAAAAAAA", name: "PS5-123", address: "192.0.2.30", state: .ready, systemVersion: "14000039")

    @Test func singleConsoleIsChosenWithoutQuery() throws {
        #expect(try ConsoleSelector.select(nil, from: [pro]) == pro)
    }

    @Test func multipleConsolesWithoutQueryIsAmbiguousAndListsNames() {
        #expect(throws: ConsoleSelector.SelectionError.ambiguous(["PS5-123", "RED PS5-Pro"])) {
            try ConsoleSelector.select(nil, from: [pro, other])
        }
    }

    @Test(arguments: ["red ps5-pro", "50aabbccddee", "192.0.2.16"])
    func matchesByNameIDOrAddressCaseInsensitively(query: String) throws {
        #expect(try ConsoleSelector.select(query, from: [pro, other]) == pro)
    }

    @Test func unknownQueryIsNotFound() {
        #expect(throws: ConsoleSelector.SelectionError.notFound("salon")) {
            try ConsoleSelector.select("salon", from: [pro, other])
        }
    }

    @Test func addressPrefersFreshDiscoveryOverStoredIP() {
        let registered = RegisteredConsole.fixture(address: "192.0.2.5")   // stale DHCP lease
        #expect(ConsoleSelector.address(for: registered, discovered: [other, pro]) == "192.0.2.16")
        #expect(ConsoleSelector.address(for: registered, discovered: [other]) == "192.0.2.5")
    }
}
