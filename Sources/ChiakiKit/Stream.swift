public struct StreamConfig: Sendable, Equatable {
    public enum Resolution: Sendable, Equatable { case p720, p1080 }

    public var resolution: Resolution
    public var fps: Int
    /// nil = libchiaki's preset bitrate for the resolution.
    public var bitrateKbps: Int?

    public init(resolution: Resolution = .p1080, fps: Int = 60, bitrateKbps: Int? = nil) {
        self.resolution = resolution
        self.fps = fps
        self.bitrateKbps = bitrateKbps
    }
}

public enum QuitReason: Sendable, Equatable {
    case stopped
    case remoteShutdown
    case remoteInUse
    case unreachable
    case other(String)

    public var userMessage: String {
        switch self {
        case .stopped: "Session closed."
        case .remoteShutdown: "The PS5 entered rest mode."
        case .remoteInUse: "Another Remote Play session is open (e.g. the official app or chiaki-ng)."
        case .unreachable: "Could not reach the console. Try waking it: psremote-cli wake"
        case .other(let text): "Session ended: \(text)"
        }
    }
}

public enum SessionEvent: Sendable, Equatable {
    case connected
    case loginPINRequested
    case quit(QuitReason)
}

/// Receives libchiaki's video buffers (profile headers and frames, Annex B) on libchiaki's video thread.
/// `buffer` is valid only during the call. Return false when the frame could not be decoded, so
/// libchiaki does not use it as a reference and can request a key frame.
public protocol VideoSink: AnyObject, Sendable {
    func consume(_ buffer: UnsafeRawBufferPointer, framesLost: Int32, recovered: Bool) -> Bool
}

/// A running session keeps itself alive until `stop()` completes; `events` ends only after
/// `stop()` (a `.quit` event does not end it), so always await `stop()` when done.
public protocol StreamSession: Sendable {
    var events: AsyncStream<SessionEvent> { get }
    /// Replaces the controller state sent to the console. Callable from any thread, also before the
    /// session has connected; ignored once `stop()` has been called.
    func send(_ state: ControllerState)
    /// Stops the session and waits for libchiaki's threads to finish. Safe to call more than once.
    func stop() async
}

public protocol StreamBackend: Sendable {
    func startStream(to console: RegisteredConsole, address: String, accountID: PSNAccountID,
                     config: StreamConfig, video: any VideoSink, audio: any AudioSink) throws -> any StreamSession
}
