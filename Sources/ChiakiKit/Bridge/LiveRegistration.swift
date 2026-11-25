import CChiaki
import Foundation

/// Collects libchiaki error lines during one registration and forwards every line.
final class LogCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private let forward: @Sendable (LogLevel, String) -> Void

    init(forward: @escaping @Sendable (LogLevel, String) -> Void) {
        self.forward = forward
    }

    func record(_ level: LogLevel, _ line: String) {
        if level == .error { lock.withLock { lines.append(line) } }
        forward(level, line)
    }

    var errorLines: [String] { lock.withLock { lines } }
}

/// One `ChiakiRegist` run. The callback fires on libchiaki's regist thread;
/// `chiaki_regist_fini` joins that thread, so it runs after the await, never inside the callback.
final class LiveRegistration: @unchecked Sendable {
    private let regist = UnsafeMutablePointer<ChiakiRegist>.allocate(capacity: 1)
    private let logger: ChiakiLogger
    let collector: LogCollector
    let host: String
    private let lock = NSLock()
    private var continuation: CheckedContinuation<RegisteredConsole, Error>?
    private var started = false
    private var cancelRequested = false

    init(host: String, logSink: @escaping @Sendable (LogLevel, String) -> Void) {
        self.host = host
        let collector = LogCollector(forward: logSink)
        self.collector = collector
        self.logger = ChiakiLogger { collector.record($0, $1) }
        regist.initialize(to: ChiakiRegist())
    }

    deinit {
        regist.deinitialize(count: 1)
        regist.deallocate()
    }

    func run(pin: UInt32, accountID: PSNAccountID) async throws -> RegisteredConsole {
        defer {
            if lock.withLock({ started }) { chiaki_regist_fini(regist) }
        }
        return try await withCheckedThrowingContinuation { continuation in
            let canceledEarly = lock.withLock { () -> Bool in
                self.continuation = continuation
                return cancelRequested
            }
            if canceledEarly {
                resume(.failure(RegistrationError.canceled))
                return
            }
            var info = ChiakiRegistInfo()
            info.target = CHIAKI_TARGET_PS5_1
            info.broadcast = false
            info.pin = pin
            info.console_pin = 0
            withUnsafeMutableBytes(of: &info.psn_account_id) { $0.copyBytes(from: accountID.bytes) }
            // chiaki_regist_start strdup()s host (regist.c), so the C string may die after the call.
            let err = host.withCString { cHost -> ChiakiErrorCode in
                info.host = cHost
                return chiaki_regist_start(regist, logger.pointer, &info, registCallback,
                                           Unmanaged.passUnretained(self).toOpaque())
            }
            if err == CHIAKI_ERR_SUCCESS {
                // A cancel that raced chiaki_regist_start is honoured here; cancel() and this
                // block meet under the same lock, so exactly one of them calls chiaki_regist_stop.
                let stopNow = lock.withLock { () -> Bool in
                    started = true
                    return cancelRequested
                }
                if stopNow { chiaki_regist_stop(regist) }
            } else {
                resume(.failure(RegistrationError.network(ChiakiError(code: err).description)))
            }
        }
    }

    func cancel() {
        let stopNow = lock.withLock { () -> Bool in
            cancelRequested = true
            return started
        }
        if stopNow { chiaki_regist_stop(regist) }
    }

    fileprivate func resume(_ result: Result<RegisteredConsole, Error>) {
        let pending = lock.withLock { () -> CheckedContinuation<RegisteredConsole, Error>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(with: result)
    }
}

private func registCallback(event: UnsafeMutablePointer<ChiakiRegistEvent>?, user: UnsafeMutableRawPointer?) {
    guard let event, let user else { return }
    let registration = Unmanaged<LiveRegistration>.fromOpaque(user).takeUnretainedValue()
    switch event.pointee.type {
    case CHIAKI_REGIST_EVENT_TYPE_FINISHED_SUCCESS:
        if let host = event.pointee.registered_host {
            registration.resume(.success(RegisteredConsole(cHost: host.pointee, address: registration.host)))
        } else {
            registration.resume(.failure(RegistrationError.network("Registration succeeded but the console data is empty")))
        }
    case CHIAKI_REGIST_EVENT_TYPE_FINISHED_CANCELED:
        registration.resume(.failure(RegistrationError.canceled))
    default:
        registration.resume(.failure(RegistrationFailureClassifier.classify(registration.collector.errorLines)))
    }
}

extension RegisteredConsole {
    init(cHost host: ChiakiRegisteredHost, address: String) {
        let mac = withUnsafeBytes(of: host.server_mac) { Array($0) }
        let nickname = withUnsafeBytes(of: host.server_nickname) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        self.init(hostID: mac.map { String(format: "%02X", $0) }.joined(),
                  nickname: nickname,
                  lastKnownAddress: address,
                  target: host.target.rawValue,
                  registKey: withUnsafeBytes(of: host.rp_regist_key) { Data($0) },
                  rpKeyType: host.rp_key_type,
                  rpKey: withUnsafeBytes(of: host.rp_key) { Data($0) },
                  consolePin: host.console_pin)
    }
}

extension LiveChiakiBackend: RegistrationBackend {
    public func register(host: String, pin: UInt32, accountID: PSNAccountID) async throws -> RegisteredConsole {
        let registration = LiveRegistration(host: host, logSink: logSink)
        return try await withTaskCancellationHandler {
            try await registration.run(pin: pin, accountID: accountID)
        } onCancel: {
            registration.cancel()
        }
    }
}
