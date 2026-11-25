import CChiaki

/// libchiaki must be initialised once per process before any other call.
public enum ChiakiLibrary {
    private static let initResult: ChiakiErrorCode = chiaki_lib_init()

    public static func initialize() throws {
        guard initResult == CHIAKI_ERR_SUCCESS else { throw ChiakiError(code: initResult) }
    }
}

/// A libchiaki `ChiakiErrorCode`, rendered with libchiaki's own message.
public struct ChiakiError: Error, Equatable, CustomStringConvertible {
    public let code: UInt32

    init(code: ChiakiErrorCode) {
        self.code = code.rawValue
    }

    public var description: String {
        String(cString: chiaki_error_string(ChiakiErrorCode(rawValue: code)))
    }
}
