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
            do { try await start(arguments: arguments, app: app) } catch { fail("Hata: \(error)") }
        }
        app.run()
        exit(0)
    }

    @MainActor
    private static func start(arguments: [String], app: NSApplication) async throws {
        let store = KeychainCredentialStore()
        let registered = try store.all()
        guard !registered.isEmpty else { fail("Kayıtlı konsol yok. Önce: psremote-cli import-chiaki", code: 2) }
        guard let accountID = try store.loadAccountID() else { fail("PSN Account-ID yok. Önce: psremote-cli import-chiaki", code: 2) }
        let chosen = try ConsoleSelector.select(arguments.first, from: registered.map {
            Console(id: $0.hostID, name: $0.nickname, address: $0.lastKnownAddress, state: .unknown, systemVersion: "")
        })
        let console = registered.first { $0.hostID == ConsoleSelector.normalizedID(chosen.id) }!
        let seconds = arguments.dropFirst().first.flatMap(Double.init)

        let backend = try LiveChiakiBackend(logSink: stderrLogSink())
        var discovered = try await discoverSnapshot(backend: backend, seconds: 3)
        if discovered.first(where: { ConsoleSelector.normalizedID($0.id) == console.hostID })?.state != .ready {
            _ = try ConsoleWaker(backend: backend).wake(console, discovered: discovered)
            print("PS5 uyandırılıyor…")
            guard try await waitUntilReady(backend: backend, hostID: console.hostID, timeout: .seconds(30)) else {
                fail("PS5 30 sn içinde hazır olmadı.", code: 3)
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
            print(String(format: "Özet: %.1f sn, %d kare, %d çözülemeyen, %d kayıp, çözme p95 %.2f ms",
                         summary.durationSeconds, summary.frames, summary.decodeFailures,
                         summary.framesLostTotal, summary.decodeMillisecondsP95))
            print("Ses: \(summary.audioPackets) paket, \(summary.audioConcealed) gizlenen kayıp, "
                + "\(summary.audioUnderruns) düşme, \(summary.audioOverflows) taşma, "
                + String(format: "en çok %.0f ms tampon", summary.audioBufferedMillisecondsMax))
            print("Günlük: \(log.url.path)")
            app.terminate(nil)
        }

        mapper.onControllerChange = { name in
            log.record(event: name == nil ? "controller_disconnected" : "controller_connected")
            print(name.map { "Kumanda: \($0)" } ?? "Kumanda ayrıldı; klavye kullanılabilir.")
        }
        mapper.start()
        if mapper.controllerName == nil {
            print("Kumanda yok. Klavye: WASD sol çubuk, oklar yön tuşları, Enter çarpı, Esc daire, Tab Options.")
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
                await finish(.other("Donanım HEVC çözücüsü açılamadı (\(error))"))
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
                    print("Bağlandı.")
                case .loginPINRequested:
                    log.record(event: "login_pin_requested")
                    print("PS5 giriş PIN'i istiyor (M3'te desteklenmiyor).")
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
