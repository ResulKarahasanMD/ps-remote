import Foundation
import Testing
@testable import ChiakiKit

@Suite struct ChiakiNGImportTests {
    /// Same keys and value types chiaki-ng writes to ~/Library/Preferences/com.chiaki.Chiaki.plist (synthetic values).
    func preferences(consolePin: Any = "0", dropping key: String? = nil) -> [String: Any] {
        var prefs: [String: Any] = [
            "registered_hosts.size": 1,
            "registered_hosts.1.server_nickname": "RED PS5-Pro",
            "registered_hosts.1.server_mac": Data([0x50, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE]),
            "registered_hosts.1.target": 1_000_100,
            "registered_hosts.1.rp_regist_key": Data("1234abcd".utf8) + Data(count: 8),
            "registered_hosts.1.rp_key": Data(repeating: 7, count: 16),
            "registered_hosts.1.rp_key_type": 2,
            "registered_hosts.1.console_pin": consolePin,
            "registered_hosts.1.ap_ssid": "",
            "settings.psn_account_id": "AQIDBAUGBwg=",
        ]
        if let key { prefs.removeValue(forKey: key) }
        return prefs
    }

    @Test func importsRegisteredHostWithDiscoveredAddress() throws {
        let consoles = try ChiakiNGImport.consoles(fromPreferences: preferences(),
                                                   addresses: ["50AABBCCDDEE": "192.0.2.16"])
        #expect(consoles == [RegisteredConsole(hostID: "50AABBCCDDEE", nickname: "RED PS5-Pro",
                                               lastKnownAddress: "192.0.2.16", target: 1_000_100,
                                               registKey: Data("1234abcd".utf8) + Data(count: 8), rpKeyType: 2,
                                               rpKey: Data(repeating: 7, count: 16), consolePin: 0)])
        #expect(try WakeCredential.from(registKey: consoles[0].registKey) == 0x1234_ABCD)
    }

    @Test func missingAddressIsEmptyNotAnError() throws {
        #expect(try ChiakiNGImport.consoles(fromPreferences: preferences(), addresses: [:])[0].lastKnownAddress == "")
    }

    @Test func consolePinMayBeStoredAsNumber() throws {
        #expect(try ChiakiNGImport.consoles(fromPreferences: preferences(consolePin: 1234), addresses: [:])[0].consolePin == 1234)
    }

    @Test func noRegisteredHostsIsAnError() {
        #expect(throws: ChiakiNGImport.ImportError.noRegisteredHosts) {
            try ChiakiNGImport.consoles(fromPreferences: ["registered_hosts.size": 0], addresses: [:])
        }
    }

    @Test func missingKeyMaterialNamesTheField() {
        #expect(throws: ChiakiNGImport.ImportError.malformed(index: 1, field: "rp_key")) {
            try ChiakiNGImport.consoles(fromPreferences: preferences(dropping: "registered_hosts.1.rp_key"), addresses: [:])
        }
    }

    @Test func accountIDIsReadFromChiakiSettings() throws {
        #expect(try ChiakiNGImport.accountID(fromPreferences: preferences())?.base64 == "AQIDBAUGBwg=")
        #expect(try ChiakiNGImport.accountID(fromPreferences: [:]) == nil)
    }
}
