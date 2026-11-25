import AppKit
import ChiakiKit
import Foundation
import MediaKit

@MainActor
final class StreamState {
    var finished = false
}

/// Bridges VideoDecoder's error callback (libchiaki video thread) to the main-actor finish path.
final class DecoderFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (VideoDecoderError) -> Void)?
    private var pending: VideoDecoderError?

    var onFailure: (@Sendable (VideoDecoderError) -> Void)? {
        get { lock.withLock { handler } }
        set {
            let early = lock.withLock { () -> VideoDecoderError? in
                handler = newValue
                defer { pending = nil }
                return pending
            }
            if let early, let newValue { newValue(early) }
        }
    }

    func report(_ error: VideoDecoderError) {
        let target = lock.withLock { () -> (@Sendable (VideoDecoderError) -> Void)? in
            if handler == nil { pending = error }
            return handler
        }
        target?(error)
    }
}

/// psremote-cli stream "<console>" [seconds]: opens a window, streams video and audio, forwards the
/// controller and keyboard, writes the session log.
enum StreamCommand {
    /// Starts AppKit on the plain main thread and performs the async setup as a main-actor task.
    @MainActor
    static func launch(arguments: [String]) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { @MainActor in
            do { try await start(arguments: arguments, app: app) } catch { fail("Error: \(error)") }
        }
        app.run()
        exit(0)
    }

    @MainActor
    private static func start(arguments: [String], app: NSApplication) async throws {
        let store = KeychainCredentialStore()
        let registered = try store.all()
        guard !registered.isEmpty else { fail("No registered consoles. Run first: psremote-cli import-chiaki", code: 2) }
        guard let accountID = try store.loadAccountID() else { fail("No PSN Account-ID. Run first: psremote-cli import-chiaki", code: 2) }
        let chosen = try ConsoleSelector.select(arguments.first, from: registered.map {
            Console(id: $0.hostID, name: $0.nickname, address: $0.lastKnownAddress, state: .unknown, systemVersion: "")
        })
        let console = registered.first { $0.hostID == ConsoleSelector.normalizedID(chosen.id) }!
        let seconds = arguments.dropFirst().first.flatMap(Double.init)

        let backend = try LiveChiakiBackend(logSink: stderrLogSink())
        var discovered = try await discoverSnapshot(backend: backend, seconds: 3)
        if discovered.first(where: { ConsoleSelector.normalizedID($0.id) == console.hostID })?.state != .ready {
            _ = try ConsoleWaker(backend: backend).wake(console, discovered: discovered)
            print("Waking the PS5…")
            guard try await waitUntilReady(backend: backend, hostID: console.hostID, timeout: .seconds(30)) else {
                fail("The PS5 was not ready within 30 s.", code: 3)
            }
            discovered = try await discoverSnapshot(backend: backend, seconds: 2)
        }
        let address = ConsoleSelector.address(for: console, discovered: discovered)

        let log = try SessionLog()
        let renderer = VideoRenderer()
        let decoderFailed = DecoderFailure()
        let decoder = VideoDecoder(onFrame: { log.record($0) }, onImage: { renderer.display($0) },
                                   onError: { decoderFailed.report($0) })
        let player = AudioPlayer(onEvent: { log.record(event: $0) })
        let session = try backend.startStream(to: console, address: address, accountID: accountID,
                                              config: StreamConfig(), video: decoder, audio: player)
        let mapper = InputMapper(send: { session.send($0) })

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "PS Remote — \(console.nickname)"
        let view = NSView()
        view.layer = renderer.layer
        view.wantsLayer = true
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate()

        let state = StreamState()
        let finish: @MainActor (QuitReason) async -> Void = { reason in
            guard !state.finished else { return }   // window close and the quit event can both arrive
            state.finished = true
            // Taken before stopping: the buffer running dry while the session shuts down is not a glitch.
            log.record(audio: player.stats)
            mapper.stop()
            await session.stop()
            player.stop()
            let summary = log.finish(quitReason: "\(reason)")
            print(reason.userMessage)
            print(String(format: "Summary: %.1f s, %d frames, %d undecodable, %d lost, decode p95 %.2f ms",
                         summary.durationSeconds, summary.frames, summary.decodeFailures,
                         summary.framesLostTotal, summary.decodeMillisecondsP95))
            print("Audio: \(summary.audioPackets) packets, \(summary.audioConcealed) concealed losses, "
                + "\(summary.audioUnderruns) underruns, \(summary.audioOverflows) overflows, "
                + String(format: "max %.0f ms buffered", summary.audioBufferedMillisecondsMax))
            print("Log: \(log.url.path)")
            app.terminate(nil)
        }

        mapper.onControllerChange = { name in
            log.record(event: name == nil ? "controller_disconnected" : "controller_connected")
            print(name.map { "Controller: \($0)" } ?? "Controller disconnected; the keyboard can be used.")
        }
        mapper.start()
        if mapper.controllerName == nil {
            print("No controller. Keyboard: WASD left stick, arrow keys D-pad, Enter cross, Esc circle, Tab Options.")
        }
        // Mapped keys go to the console instead of the window (no system beep); Cmd shortcuts stay with the app.
        let keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
            let commandHeld = event.modifierFlags.contains(.command)
            if event.type == .flagsChanged {
                mapper.commandChanged(isHeld: commandHeld)
                return event
            }
            return mapper.keyChanged(keyCode: event.keyCode, isDown: event.type == .keyDown, commandHeld: commandHeld) ? nil : event
        }
        // Without focus neither key-up events nor gamepad updates arrive, so nothing may stay pressed.
        let focusObservers = [
            NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { mapper.suspend() }
            },
            NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { mapper.resume() }
            },
        ]
        _ = (keyMonitor, focusObservers)
        Task { @MainActor in
            while true {
                try? await Task.sleep(for: .seconds(1))
                if state.finished { break }
                log.record(audio: player.stats)
            }
        }

        // Spec §5: a decoder that cannot be set up ends the session with a message, not a black window.
        decoderFailed.onFailure = { error in
            Task { @MainActor in
                log.record(event: "decoder_setup_failed")
                await finish(.other("Could not open the hardware HEVC decoder (\(error))"))
            }
        }
        let closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { _ = Task { await finish(.stopped) } }
        }
        _ = closeObserver
        Task { @MainActor in
            for await event in session.events {
                switch event {
                case .connected:
                    log.record(event: "connected")
                    print("Connected.")
                case .loginPINRequested:
                    log.record(event: "login_pin_requested")
                    print("The PS5 is asking for a login PIN (not supported in M3).")
                case .quit(let reason):
                    log.record(event: "quit")
                    await finish(reason)
                }
            }
        }
        if let seconds {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                await finish(.stopped)
            }
        }
    }
}
