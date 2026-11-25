import ChiakiKit
import GameController

/// A gamepad's raw values in GameController's conventions: axes -1...1 with +y up, triggers 0...1.
public struct GamepadSnapshot: Sendable, Equatable {
    public var pressed: ControllerButtons
    public var leftX: Float
    public var leftY: Float
    public var rightX: Float
    public var rightY: Float
    public var l2: Float
    public var r2: Float

    public init(pressed: ControllerButtons = [], leftX: Float = 0, leftY: Float = 0, rightX: Float = 0,
                rightY: Float = 0, l2: Float = 0, r2: Float = 0) {
        self.pressed = pressed
        self.leftX = leftX
        self.leftY = leftY
        self.rightX = rightX
        self.rightY = rightY
        self.l2 = l2
        self.r2 = r2
    }

    /// Reads the current values of a GameController profile. PlayStation naming: buttonA is cross,
    /// buttonB circle, buttonX square, buttonY triangle, buttonMenu Options, buttonOptions Create/Share.
    public init(_ pad: GCExtendedGamepad) {
        var pressed: ControllerButtons = []
        func add(_ input: GCControllerButtonInput?, _ button: ControllerButtons) {
            if input?.isPressed == true { pressed.insert(button) }
        }
        add(pad.buttonA, .cross)
        add(pad.buttonB, .circle)
        add(pad.buttonX, .square)
        add(pad.buttonY, .triangle)
        add(pad.dpad.left, .dpadLeft)
        add(pad.dpad.right, .dpadRight)
        add(pad.dpad.up, .dpadUp)
        add(pad.dpad.down, .dpadDown)
        add(pad.leftShoulder, .l1)
        add(pad.rightShoulder, .r1)
        add(pad.leftThumbstickButton, .l3)
        add(pad.rightThumbstickButton, .r3)
        add(pad.buttonMenu, .options)
        add(pad.buttonOptions, .share)
        add(pad.buttonHome, .ps)
        if let dualSense = pad as? GCDualSenseGamepad {
            add(dualSense.touchpadButton, .touchpad)
        } else if let dualShock = pad as? GCDualShockGamepad {
            add(dualShock.touchpadButton, .touchpad)
        }
        self.init(pressed: pressed,
                  leftX: pad.leftThumbstick.xAxis.value, leftY: pad.leftThumbstick.yAxis.value,
                  rightX: pad.rightThumbstick.xAxis.value, rightY: pad.rightThumbstick.yAxis.value,
                  l2: pad.leftTrigger.value, r2: pad.rightTrigger.value)
    }
}

public enum InputMapping {
    /// macOS virtual key codes (kVK_*) of the keyboard fallback (spec §3.4).
    enum Key {
        static let a: UInt16 = 0
        static let s: UInt16 = 1
        static let d: UInt16 = 2
        static let w: UInt16 = 13
        static let returnKey: UInt16 = 36
        static let tab: UInt16 = 48
        static let escape: UInt16 = 53
        static let left: UInt16 = 123
        static let right: UInt16 = 124
        static let down: UInt16 = 125
        static let up: UInt16 = 126
    }

    private static let keyButtons: [UInt16: ControllerButtons] = [
        Key.left: .dpadLeft, Key.right: .dpadRight, Key.up: .dpadUp, Key.down: .dpadDown,
        Key.returnKey: .cross, Key.escape: .circle, Key.tab: .options,
    ]
    private static let stickKeys: Set<UInt16> = [Key.w, Key.a, Key.s, Key.d]

    public static func isMapped(keyCode: UInt16) -> Bool {
        keyButtons[keyCode] != nil || stickKeys.contains(keyCode)
    }

    public static func state(from snapshot: GamepadSnapshot) -> ControllerState {
        ControllerState(buttons: snapshot.pressed, l2: trigger(snapshot.l2), r2: trigger(snapshot.r2),
                        leftX: axis(snapshot.leftX), leftY: axis(-snapshot.leftY),
                        rightX: axis(snapshot.rightX), rightY: axis(-snapshot.rightY))
    }

    /// WASD is the left stick at full deflection (opposite keys cancel), arrows the D-pad, Return
    /// cross, Escape circle, Tab Options.
    public static func state(fromKeys keys: Set<UInt16>) -> ControllerState {
        var state = ControllerState()
        for key in keys {
            if let button = keyButtons[key] { state.buttons.insert(button) }
        }
        func deflection(negative: UInt16, positive: UInt16) -> Int16 {
            (keys.contains(positive) ? 32767 : 0) - (keys.contains(negative) ? 32767 : 0)
        }
        state.leftX = deflection(negative: Key.a, positive: Key.d)
        state.leftY = deflection(negative: Key.w, positive: Key.s)
        return state
    }

    static func axis(_ value: Float) -> Int16 {
        guard value.isFinite else { return 0 }
        return Int16((max(-1, min(1, value)) * 32767).rounded())
    }

    static func trigger(_ value: Float) -> UInt8 {
        guard value.isFinite else { return 0 }
        return UInt8((max(0, min(1, value)) * 255).rounded())
    }
}
