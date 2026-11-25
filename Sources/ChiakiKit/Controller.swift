/// Digital buttons; raw values are libchiaki's ChiakiControllerButton bits.
public struct ControllerButtons: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let cross = ControllerButtons(rawValue: 1 << 0)
    public static let circle = ControllerButtons(rawValue: 1 << 1)
    public static let square = ControllerButtons(rawValue: 1 << 2)
    public static let triangle = ControllerButtons(rawValue: 1 << 3)
    public static let dpadLeft = ControllerButtons(rawValue: 1 << 4)
    public static let dpadRight = ControllerButtons(rawValue: 1 << 5)
    public static let dpadUp = ControllerButtons(rawValue: 1 << 6)
    public static let dpadDown = ControllerButtons(rawValue: 1 << 7)
    public static let l1 = ControllerButtons(rawValue: 1 << 8)
    public static let r1 = ControllerButtons(rawValue: 1 << 9)
    public static let l3 = ControllerButtons(rawValue: 1 << 10)
    public static let r3 = ControllerButtons(rawValue: 1 << 11)
    public static let options = ControllerButtons(rawValue: 1 << 12)
    public static let share = ControllerButtons(rawValue: 1 << 13)
    public static let touchpad = ControllerButtons(rawValue: 1 << 14)
    public static let ps = ControllerButtons(rawValue: 1 << 15)
}

/// What is sent to the console. Sticks are -32767...32767 with +x right and +y down (libchiaki's
/// convention); triggers are 0...255.
public struct ControllerState: Sendable, Equatable {
    public var buttons: ControllerButtons
    public var l2: UInt8
    public var r2: UInt8
    public var leftX: Int16
    public var leftY: Int16
    public var rightX: Int16
    public var rightY: Int16

    public init(buttons: ControllerButtons = [], l2: UInt8 = 0, r2: UInt8 = 0,
                leftX: Int16 = 0, leftY: Int16 = 0, rightX: Int16 = 0, rightY: Int16 = 0) {
        self.buttons = buttons
        self.l2 = l2
        self.r2 = r2
        self.leftX = leftX
        self.leftY = leftY
        self.rightX = rightX
        self.rightY = rightY
    }

    public static let idle = ControllerState()

    /// Union of two input sources (gamepad and keyboard): buttons are or-ed, triggers take the larger
    /// value, each stick axis takes the value further from centre.
    public func merged(with other: ControllerState) -> ControllerState {
        func further(_ a: Int16, _ b: Int16) -> Int16 { abs(Int(a)) >= abs(Int(b)) ? a : b }
        return ControllerState(buttons: buttons.union(other.buttons), l2: max(l2, other.l2), r2: max(r2, other.r2),
                               leftX: further(leftX, other.leftX), leftY: further(leftY, other.leftY),
                               rightX: further(rightX, other.rightX), rightY: further(rightY, other.rightY))
    }
}
