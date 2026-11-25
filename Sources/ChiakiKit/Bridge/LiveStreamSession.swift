import CChiaki
import Foundation

/// One libchiaki `ChiakiSession`. Callbacks arrive on libchiaki threads; `stop()` joins those
/// threads from a detached task, never from inside a callback. While libchiaki's threads run, the
/// session holds a strong reference to itself (`keepAlive`), so callers that drop it without
/// awaiting `stop()` leak a running session instead of freeing memory those threads still use.
final class LiveStreamSession: StreamSession, @unchecked Sendable {
    private let session = UnsafeMutablePointer<ChiakiSession>.allocate(capacity: 1)
    private let logger: ChiakiLogger
    private let video: any VideoSink
    private let audio: any AudioSink
    let events: AsyncStream<SessionEvent>
    private let continuation: AsyncStream<SessionEvent>.Continuation
    private let lock = NSLock()
    private var initialized = false
    private var stopTask: Task<Void, Never>?
    private var keepAlive: LiveStreamSession?

    init(console: RegisteredConsole, address: String, accountID: PSNAccountID, config: StreamConfig,
         video: any VideoSink, audio: any AudioSink,
         logSink: @escaping @Sendable (LogLevel, String) -> Void) throws {
        self.logger = ChiakiLogger(sink: logSink)
        self.video = video
        self.audio = audio
        let stream = AsyncStream.makeStream(of: SessionEvent.self)
        events = stream.stream
        continuation = stream.continuation
        session.initialize(to: ChiakiSession())

        var info = ChiakiConnectInfo()
        info.ps5 = true
        info.video_profile = makeVideoProfile(config)
        info.video_profile_auto_downgrade = true
        info.enable_keyboard = false
        info.enable_dualsense = false
        info.audio_video_disabled = CHIAKI_NONE_DISABLED
        info.auto_regist = false
        info.packet_loss_max = 0.05
        info.enable_idr_on_fec_failure = true
        withUnsafeMutableBytes(of: &info.regist_key) { $0.copyBytes(from: console.registKey.prefix($0.count)) }
        withUnsafeMutableBytes(of: &info.morning) { $0.copyBytes(from: console.rpKey.prefix($0.count)) }
        withUnsafeMutableBytes(of: &info.psn_account_id) { $0.copyBytes(from: accountID.bytes) }

        // chiaki_session_init resolves the host immediately (session.c) and calls fini itself on some failures.
        let initError = address.withCString { host -> ChiakiErrorCode in
            info.host = host
            return chiaki_session_init(session, &info, logger.pointer)
        }
        guard initError == CHIAKI_ERR_SUCCESS else { throw ChiakiError(code: initError) }
        lock.withLock { initialized = true }

        let user = Unmanaged.passUnretained(self).toOpaque()
        chiaki_session_set_event_cb(session, streamEventCallback, user)
        chiaki_session_set_video_sample_cb(session, videoSampleCallback, user)
        var audioSink = ChiakiAudioSink()
        audioSink.user = user
        audioSink.header_cb = audioHeaderCallback
        audioSink.frame_cb = audioFrameCallback
        chiaki_session_set_audio_sink(session, &audioSink)

        let startError = chiaki_session_start(session)
        guard startError == CHIAKI_ERR_SUCCESS else {
            chiaki_session_fini(session)
            lock.withLock { initialized = false }
            throw ChiakiError(code: startError)
        }
        lock.withLock { keepAlive = self }
    }

    deinit {
        session.deinitialize(count: 1)
        session.deallocate()
    }

    func stop() async {
        let task = lock.withLock { () -> Task<Void, Never>? in
            if let stopTask { return stopTask }
            guard initialized else { return nil }
            // Captures self: an abandoned stop() (e.g. a cancelled caller) still keeps the session
            // alive until libchiaki's threads are joined.
            let task = Task.detached {
                chiaki_session_stop(self.session)
                chiaki_session_join(self.session)
                chiaki_session_fini(self.session)
            }
            stopTask = task
            return task
        }
        await task?.value
        lock.withLock {
            initialized = false
            keepAlive = nil
        }
        continuation.finish()
    }

    func send(_ state: ControllerState) {
        lock.withLock {
            // After stop() the ChiakiSession is being torn down; its mutexes must not be touched.
            guard initialized, stopTask == nil else { return }
            var chiakiState = ChiakiControllerState(state)
            chiaki_session_set_controller_state(session, &chiakiState)
        }
    }

    /// The state libchiaki currently holds; nil once the session is stopping or stopped.
    var controllerStateForTesting: ChiakiControllerState? {
        lock.withLock {
            guard initialized, stopTask == nil else { return nil }
            return session.pointee.controller_state
        }
    }

    fileprivate func deliver(_ event: SessionEvent) {
        continuation.yield(event)
    }

    fileprivate func consume(_ buffer: UnsafeRawBufferPointer, framesLost: Int32, recovered: Bool) -> Bool {
        video.consume(buffer, framesLost: framesLost, recovered: recovered)
    }

    fileprivate func configureAudio(_ format: AudioFormat) {
        audio.configure(format)
    }

    fileprivate func consumeAudio(_ packet: UnsafeRawBufferPointer?) {
        audio.consume(packet)
    }
}

private func streamEventCallback(event: UnsafeMutablePointer<ChiakiEvent>?, user: UnsafeMutableRawPointer?) {
    guard let event, let user else { return }
    let stream = Unmanaged<LiveStreamSession>.fromOpaque(user).takeUnretainedValue()
    switch event.pointee.type {
    case CHIAKI_EVENT_CONNECTED:
        stream.deliver(.connected)
    case CHIAKI_EVENT_LOGIN_PIN_REQUEST:
        stream.deliver(.loginPINRequested)
    case CHIAKI_EVENT_QUIT:
        let quit = event.pointee.quit
        stream.deliver(.quit(QuitReason(chiaki: quit.reason, text: quit.reason_str.map { String(cString: $0) })))
    default:
        break
    }
}

private func videoSampleCallback(buf: UnsafeMutablePointer<UInt8>?, size: Int, framesLost: Int32,
                                 recovered: Bool, user: UnsafeMutableRawPointer?) -> Bool {
    guard let buf, let user else { return false }
    let stream = Unmanaged<LiveStreamSession>.fromOpaque(user).takeUnretainedValue()
    return stream.consume(UnsafeRawBufferPointer(start: buf, count: size), framesLost: framesLost, recovered: recovered)
}

/// Called with libchiaki's audio receiver mutex held (audioreceiver.c), so the sink must not block.
func audioHeaderCallback(header: UnsafeMutablePointer<ChiakiAudioHeader>?, user: UnsafeMutableRawPointer?) {
    guard let header, let user else { return }
    let stream = Unmanaged<LiveStreamSession>.fromOpaque(user).takeUnretainedValue()
    stream.configureAudio(AudioFormat(channels: Int(header.pointee.channels), sampleRate: Int(header.pointee.rate),
                                      frameSize: Int(header.pointee.frame_size)))
}

/// libchiaki passes a NULL buffer for a frame its jitter buffer gave up on (audioreceiver.c).
func audioFrameCallback(buf: UnsafeMutablePointer<UInt8>?, size: Int, user: UnsafeMutableRawPointer?) {
    guard let user else { return }
    let stream = Unmanaged<LiveStreamSession>.fromOpaque(user).takeUnretainedValue()
    stream.consumeAudio(buf.flatMap { size > 0 ? UnsafeRawBufferPointer(start: $0, count: size) : nil })
}

extension LiveChiakiBackend: StreamBackend {
    public func startStream(to console: RegisteredConsole, address: String, accountID: PSNAccountID,
                            config: StreamConfig, video: any VideoSink, audio: any AudioSink) throws -> any StreamSession {
        try LiveStreamSession(console: console, address: address, accountID: accountID, config: config,
                              video: video, audio: audio, logSink: logSink)
    }
}
