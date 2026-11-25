import ChiakiKit
import GameController
import Testing
@testable import MediaKit

@Suite struct InputMappingTests {
    @Test func sticksUseLibchiakiRangeWithYPointingDown() {
        let state = InputMapping.state(from: GamepadSnapshot(leftX: 1, leftY: 1, rightX: -0.5, rightY: -1))
        #expect(state.leftX == 32767)
        #expect(state.leftY == -32767, "GameController's up (+1) is libchiaki's negative y")
        #expect(state.rightX == -16384)
        #expect(state.rightY == 32767)
    }

    @Test func triggersScaleTo255AndButtonsPassThrough() {
        let state = InputMapping.state(from: GamepadSnapshot(pressed: [.cross, .l1, .ps], l2: 0.5, r2: 1))
        #expect(state.buttons == [.cross, .l1, .ps])
        #expect(state.l2 == 128)
        #expect(state.r2 == 255)
    }

    @Test(arguments: [Float.nan, .infinity, -.infinity])
    func nonFiniteValuesBecomeNeutral(value: Float) {
        #expect(InputMapping.axis(value) == 0)
        #expect(InputMapping.trigger(value) == 0)
    }

    @Test func outOfRangeValuesAreClamped() {
        #expect(InputMapping.axis(1.5) == 32767)
        #expect(InputMapping.axis(-7) == -32767)
        #expect(InputMapping.trigger(2) == 255)
        #expect(InputMapping.trigger(-1) == 0)
    }

    @Test func keyboardFallbackFollowsTheSpec() {
        typealias Key = InputMapping.Key
        #expect(InputMapping.state(fromKeys: [Key.w]) == ControllerState(leftY: -32767))
        #expect(InputMapping.state(fromKeys: [Key.s, Key.d]) == ControllerState(leftX: 32767, leftY: 32767))
        #expect(InputMapping.state(fromKeys: [Key.a]) == ControllerState(leftX: -32767))
        #expect(InputMapping.state(fromKeys: [Key.a, Key.d]) == .idle, "opposite keys cancel")
        #expect(InputMapping.state(fromKeys: [Key.up, Key.left]).buttons == [.dpadUp, .dpadLeft])
        #expect(InputMapping.state(fromKeys: [Key.down, Key.right]).buttons == [.dpadDown, .dpadRight])
        #expect(InputMapping.state(fromKeys: [Key.returnKey]).buttons == .cross)
        #expect(InputMapping.state(fromKeys: [Key.escape]).buttons == .circle)
        #expect(InputMapping.state(fromKeys: [Key.tab]).buttons == .options)
        #expect(InputMapping.state(fromKeys: [12, 99]) == .idle, "unmapped keys do nothing")
        #expect(InputMapping.isMapped(keyCode: Key.w))
        #expect(!InputMapping.isMapped(keyCode: 12))
    }

    /// GameController's programmatic controller stands in for a DualSense: checks the PlayStation
    /// naming of the profile's elements.
    @Test @MainActor func readsAGameControllerProfile() throws {
        let pad = try #require(GCController.withExtendedGamepad().extendedGamepad)
        pad.buttonA.setValue(1)
        pad.buttonY.setValue(1)
        pad.rightShoulder.setValue(1)
        pad.buttonMenu.setValue(1)
        pad.dpad.setValueForXAxis(-1, yAxis: 1)
        pad.leftThumbstick.setValueForXAxis(0.5, yAxis: 1)
        pad.rightThumbstick.setValueForXAxis(-1, yAxis: 0)
        pad.leftTrigger.setValue(0.25)
        pad.rightTrigger.setValue(1)

        let snapshot = GamepadSnapshot(pad)
        #expect(snapshot.pressed == [.cross, .triangle, .r1, .options, .dpadLeft, .dpadUp])
        #expect(InputMapping.state(from: snapshot)
            == ControllerState(buttons: [.cross, .triangle, .r1, .options, .dpadLeft, .dpadUp], l2: 64, r2: 255,
                               leftX: 16384, leftY: -32767, rightX: -32767, rightY: 0))
    }
}
