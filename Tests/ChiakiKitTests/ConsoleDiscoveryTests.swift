import Testing
@testable import ChiakiKit

@Suite struct ConsoleDiscoveryTests {
    @Test func keepsOnlyPS5HostsSortedByName() {
        let consoles = ConsoleDiscovery.consoles(from: [
            .fixture(name: "Zeta", hostID: "B"),
            .fixture(name: "Living Room PS4", hostType: "PS4", hostID: "C"),
            .fixture(name: "Alpha", address: "192.0.2.20", state: .ready, hostID: "A"),
        ])
        #expect(consoles.map(\.name) == ["Alpha", "Zeta"])
        #expect(consoles[0] == Console(id: "A", name: "Alpha", address: "192.0.2.20",
                                       state: .ready, systemVersion: "14000039"))
    }

    @Test func summaryLineIsTabSeparatedWithStateLabel() {
        let console = ConsoleDiscovery.consoles(from: [.fixture()])[0]
        #expect(console.summaryLine == "RED PS5-Pro\t192.0.2.16\tstandby\t50AABBCCDDEE")
    }

    @Test func streamYieldsWhenBackendEmits() async throws {
        let fake = FakeDiscoveryBackend()
        let stream = ConsoleDiscovery(backend: fake).consoles()
        fake.emit([.fixture(state: .ready)])
        var iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()
        #expect(first?.map(\.state) == [.ready])
    }

    @Test func cancellingTheConsumerStopsDiscovery() async {
        let fake = FakeDiscoveryBackend()
        let stream = ConsoleDiscovery(backend: fake).consoles()
        let consumer = Task { for try await _ in stream {} }
        consumer.cancel()
        _ = await consumer.result
        #expect(await eventually { fake.stopCount == 1 })
    }

    @Test func startFailureFinishesTheStreamWithTheError() async {
        let fake = FakeDiscoveryBackend()
        fake.startError = TestError()
        await #expect(throws: TestError.self) {
            for try await _ in ConsoleDiscovery(backend: fake).consoles() {}
        }
    }
}
