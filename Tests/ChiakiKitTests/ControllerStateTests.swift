import Testing
@testable import ChiakiKit

@Suite struct ControllerStateTests {
    @Test func idleHasNothingPressed() {
        #expect(ControllerState.idle == ControllerState(buttons: [], l2: 0, r2: 0, leftX: 0, leftY: 0, rightX: 0, rightY: 0))
    }

    @Test func mergeTakesButtonsOfBothAndTheStrongerAnalogValue() {
        let gamepad = ControllerState(buttons: .cross, l2: 10, r2: 200, leftX: 1000, leftY: -20000, rightX: 5)
        let keyboard = ControllerState(buttons: .dpadUp, l2: 255, leftX: -32767, leftY: 100)
        #expect(gamepad.merged(with: keyboard)
            == ControllerState(buttons: [.cross, .dpadUp], l2: 255, r2: 200, leftX: -32767, leftY: -20000, rightX: 5))
        #expect(gamepad.merged(with: .idle) == gamepad)
        #expect(ControllerState.idle.merged(with: gamepad) == gamepad)
    }

    @Test func mergeHandlesTheMostNegativeStickValue() {
        let low = ControllerState(leftX: .min)
        #expect(low.merged(with: ControllerState(leftX: .max)).leftX == .min)
    }
}
