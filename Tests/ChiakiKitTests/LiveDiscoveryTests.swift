import Foundation
import Testing
@testable import ChiakiKit

@Suite(.enabled(if: ProcessInfo.processInfo.environment["PSREMOTE_LIVE"] == "1"))
struct LiveDiscoveryTests {
    @Test func findsAtLeastOnePS5OnTheLAN() async throws {
        let discovery = ConsoleDiscovery(backend: try LiveChiakiBackend())
        let consoles = try await withTimeout(seconds: 6) {
            for try await list in discovery.consoles() where !list.isEmpty { return list }
            return []
        }
        #expect(!consoles.isEmpty)
        #expect(consoles.allSatisfy { !$0.address.isEmpty && !$0.id.isEmpty })
    }
}
