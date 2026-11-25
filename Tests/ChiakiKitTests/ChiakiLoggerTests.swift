import CChiaki
import Foundation
import Testing
@testable import ChiakiKit

final class LineSink: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(LogLevel, String)] = []
    func add(_ level: LogLevel, _ line: String) { lock.withLock { items.append((level, line)) } }
    var all: [(LogLevel, String)] { lock.withLock { items } }
}

@Suite struct ChiakiLoggerTests {
    @Test func forwardsLinesWithLevelAndWithoutTrailingNewline() {
        let sink = LineSink()
        let logger = ChiakiLogger { sink.add($0, $1) }
        logger.emitForTesting(CHIAKI_LOG_WARNING, "hello 42\n")
        #expect(sink.all.count == 1)
        #expect(sink.all.first?.0 == .warning)
        #expect(sink.all.first?.1 == "hello 42")
    }

    @Test func mapsEveryLibchiakiLevel() {
        #expect(LogLevel(CHIAKI_LOG_ERROR) == .error)
        #expect(LogLevel(CHIAKI_LOG_INFO) == .info)
        #expect(LogLevel(CHIAKI_LOG_VERBOSE) == .verbose)
        #expect(LogLevel(CHIAKI_LOG_DEBUG) == .debug)
    }

    @Test func defaultMaskKeepsErrorsWarningsInfoAndDropsVerboseAndDebug() {
        let mask = ChiakiLogger.defaultMask
        #expect(mask & CHIAKI_LOG_ERROR.rawValue != 0)
        #expect(mask & CHIAKI_LOG_WARNING.rawValue != 0)
        #expect(mask & CHIAKI_LOG_INFO.rawValue != 0)
        #expect(mask & CHIAKI_LOG_VERBOSE.rawValue == 0)
        #expect(mask & CHIAKI_LOG_DEBUG.rawValue == 0)
    }
}
