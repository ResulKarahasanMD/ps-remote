import CChiaki
import Foundation
import Testing
@testable import ChiakiKit

@Suite struct RegisteredHostMappingTests {
    @Test func mapsLibchiakiRegisteredHostFields() throws {
        var host = ChiakiRegisteredHost()
        host.target = CHIAKI_TARGET_PS5_1
        withUnsafeMutableBytes(of: &host.server_mac) { $0.copyBytes(from: [0x50, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE]) }
        withUnsafeMutableBytes(of: &host.server_nickname) { $0.copyBytes(from: Array("RED PS5-Pro".utf8)) }
        withUnsafeMutableBytes(of: &host.rp_regist_key) { $0.copyBytes(from: Array("1234abcd".utf8)) }
        withUnsafeMutableBytes(of: &host.rp_key) { $0.copyBytes(from: [UInt8](repeating: 7, count: 16)) }
        host.rp_key_type = 2
        host.console_pin = 0

        let console = RegisteredConsole(cHost: host, address: "192.0.2.16")

        #expect(console.hostID == "50AABBCCDDEE")
        #expect(console.nickname == "RED PS5-Pro")
        #expect(console.lastKnownAddress == "192.0.2.16")
        #expect(console.target == CHIAKI_TARGET_PS5_1.rawValue)
        #expect(console.registKey.count == 16)
        #expect(try WakeCredential.from(registKey: console.registKey) == 0x1234_ABCD)
        #expect(console.rpKey == Data(repeating: 7, count: 16))
        #expect(console.rpKeyType == 2)
    }
}
