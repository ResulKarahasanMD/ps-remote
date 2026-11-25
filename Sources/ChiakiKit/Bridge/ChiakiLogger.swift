import CChiaki
import Foundation

public enum LogLevel: Sendable, Equatable {
    case error, warning, info, verbose, debug

    init(_ level: ChiakiLogLevel) {
        switch level {
        case CHIAKI_LOG_ERROR: self = .error
        case CHIAKI_LOG_WARNING: self = .warning
        case CHIAKI_LOG_INFO: self = .info
        case CHIAKI_LOG_VERBOSE: self = .verbose
        default: self = .debug
        }
    }
}

/// Owns a heap-allocated `ChiakiLog` (libchiaki keeps the pointer) and forwards lines to `sink`.
/// Must outlive every libchiaki object created with `pointer`.
final class ChiakiLogger: @unchecked Sendable {
    static let defaultMask: UInt32 =
        CHIAKI_LOG_ERROR.rawValue | CHIAKI_LOG_WARNING.rawValue | CHIAKI_LOG_INFO.rawValue

    let pointer: UnsafeMutablePointer<ChiakiLog>
    private let sink: @Sendable (LogLevel, String) -> Void

    init(mask: UInt32 = ChiakiLogger.defaultMask, sink: @escaping @Sendable (LogLevel, String) -> Void) {
        pointer = .allocate(capacity: 1)
        pointer.initialize(to: ChiakiLog())
        self.sink = sink
        chiaki_log_init(pointer, mask, chiakiLogCallback, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit {
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }

    fileprivate func deliver(_ level: ChiakiLogLevel, _ message: String) {
        sink(LogLevel(level), message.trimmingCharacters(in: .newlines))
    }

    /// Test seam: runs the same path libchiaki's callback takes.
    func emitForTesting(_ level: ChiakiLogLevel, _ message: String) {
        deliver(level, message)
    }
}

private func chiakiLogCallback(level: ChiakiLogLevel, msg: UnsafePointer<CChar>?, user: UnsafeMutableRawPointer?) {
    guard let user, let msg else { return }
    Unmanaged<ChiakiLogger>.fromOpaque(user).takeUnretainedValue().deliver(level, String(cString: msg))
}
