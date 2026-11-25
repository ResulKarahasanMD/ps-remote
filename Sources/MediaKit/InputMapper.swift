import ChiakiKit
import Foundation
import GameController

/// Turns gamepad and keyboard input into `ControllerState` values and hands every change to `send`.
/// The keyboard is merged with the gamepad, so it works as the fallback when no controller is
/// connected (spec §3.4) and stays usable next to one.
@MainActor
public final class InputMapper {
    private let send: @Sendable (ControllerState) -> Void
    private var observers: [any NSObjectProtocol] = []
    private var controller: GCController?
    private var gamepad = ControllerState.idle
    private var keys: Set<UInt16> = []
    private var lastSent = ControllerState.idle
    private var suspended = false

    /// Called with the controller's name when one connects, nil when the last one disconnects.
    public var onControllerChange: ((String?) -> Void)?

    public init(send: @escaping @Sendable (ControllerState) -> Void) {
        self.send = send
    }

    public var controllerName: String? { controller?.vendorName }

    /// Starts following GameController connections; picks up an already connected controller.
    public func start() {
        guard observers.isEmpty else { return }
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshController() }
            })
        }
        refreshController()
    }

    public func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        controller?.extendedGamepad?.valueChangedHandler = nil
        controller = nil
    }

    /// Feeds one key event. Returns true when the caller should swallow it: the key belongs to the
    /// keyboard fallback and Cmd is not held. With Cmd held a key-down is a shortcut for the app and
    /// presses nothing, but a key-up still releases the key.
    @discardableResult
    public func keyChanged(keyCode: UInt16, isDown: Bool, commandHeld: Bool = false) -> Bool {
        guard InputMapping.isMapped(keyCode: keyCode) else { return false }
        if isDown {
            guard !commandHeld else { return false }
            keys.insert(keyCode)
        } else {
            keys.remove(keyCode)
        }
        publish()
        return !commandHeld
    }

    /// Cmd went down or up. AppKit does not deliver key-up events while Cmd is held, so pressing it
    /// releases every held key; otherwise a key let go during a shortcut would stay pressed.
    public func commandChanged(isHeld: Bool) {
        guard isHeld else { return }
        keys.removeAll()
        publish()
    }

    /// The window lost focus: key-up events and gamepad updates stop arriving, so release everything.
    public func suspend() {
        suspended = true
        keys.removeAll()
        publish()
    }

    /// The window has focus again: continue from the gamepad's current values.
    public func resume() {
        suspended = false
        gamepadChanged(controller?.extendedGamepad.map(GamepadSnapshot.init))
    }

    /// New gamepad values; nil when no controller is connected.
    func gamepadChanged(_ snapshot: GamepadSnapshot?) {
        gamepad = snapshot.map(InputMapping.state(from:)) ?? .idle
        publish()
    }

    private func refreshController() {
        let controllers = GCController.controllers().filter { $0.extendedGamepad != nil }
        let candidate = controllers.first { $0.extendedGamepad is GCDualSenseGamepad } ?? controllers.first
        guard candidate !== controller else { return }
        controller?.extendedGamepad?.valueChangedHandler = nil
        controller = candidate
        if let pad = candidate?.extendedGamepad {
            // Without this macOS keeps the PS and Create buttons for its own gestures.
            pad.buttonHome?.preferredSystemGestureState = .disabled
            pad.buttonOptions?.preferredSystemGestureState = .disabled
            pad.valueChangedHandler = { [weak self] pad, _ in
                let snapshot = GamepadSnapshot(pad)
                MainActor.assumeIsolated { self?.gamepadChanged(snapshot) }
            }
            gamepadChanged(GamepadSnapshot(pad))
        } else {
            gamepadChanged(nil)
        }
        onControllerChange?(candidate?.vendorName)
    }

    private func publish() {
        let state = suspended ? .idle : gamepad.merged(with: InputMapping.state(fromKeys: keys))
        guard state != lastSent else { return }
        lastSent = state
        send(state)
    }
}
