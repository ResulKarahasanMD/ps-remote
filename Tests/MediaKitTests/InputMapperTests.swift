import ChiakiKit
import Foundation
import Testing
@testable import MediaKit

final class SentStates: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [ControllerState] = []
    func add(_ state: ControllerState) { lock.withLock { states.append(state) } }
    var all: [ControllerState] { lock.withLock { states } }
}

@MainActor @Suite struct InputMapperTests {
    typealias Key = InputMapping.Key
    let sent = SentStates()

    func makeMapper() -> InputMapper {
        InputMapper(send: sent.add)
    }

    @Test func keysAreSentOnChangeOnly() {
        let mapper = makeMapper()
        #expect(mapper.keyChanged(keyCode: Key.w, isDown: true))
        #expect(mapper.keyChanged(keyCode: Key.w, isDown: true), "key repeat is still handled")
        #expect(mapper.keyChanged(keyCode: Key.returnKey, isDown: true))
        #expect(mapper.keyChanged(keyCode: Key.w, isDown: false))
        #expect(mapper.keyChanged(keyCode: Key.returnKey, isDown: false))
        #expect(sent.all == [
            ControllerState(leftY: -32767),
            ControllerState(buttons: .cross, leftY: -32767),
            ControllerState(buttons: .cross),
            .idle,
        ])
    }

    @Test func unmappedKeysAreLeftToTheApp() {
        let mapper = makeMapper()
        #expect(!mapper.keyChanged(keyCode: 12, isDown: true))   // Q
        #expect(sent.all.isEmpty)
    }

    @Test func aKeyReleasedWhileCommandIsHeldIsStillReleased() {
        let mapper = makeMapper()
        mapper.keyChanged(keyCode: Key.w, isDown: true)
        #expect(!mapper.keyChanged(keyCode: Key.w, isDown: false, commandHeld: true), "the app sees the event too")
        #expect(sent.all == [ControllerState(leftY: -32767), .idle])
    }

    /// AppKit does not deliver key-up events while Cmd is down, so Cmd itself has to release the keys.
    @Test func pressingCommandReleasesHeldKeysButNotTheGamepad() {
        let mapper = makeMapper()
        mapper.gamepadChanged(GamepadSnapshot(pressed: .square))
        mapper.keyChanged(keyCode: Key.w, isDown: true)
        mapper.keyChanged(keyCode: Key.returnKey, isDown: true)
        mapper.commandChanged(isHeld: true)
        #expect(sent.all.last == ControllerState(buttons: .square))
        let count = sent.all.count
        mapper.commandChanged(isHeld: false)
        #expect(sent.all.count == count, "releasing Cmd does not press anything again")
    }

    @Test func keysPressedWithCommandBelongToTheApp() {
        let mapper = makeMapper()
        #expect(!mapper.keyChanged(keyCode: Key.w, isDown: true, commandHeld: true))
        #expect(sent.all.isEmpty)
    }

    @Test func gamepadAndKeyboardAreMerged() {
        let mapper = makeMapper()
        mapper.gamepadChanged(GamepadSnapshot(pressed: .square, leftX: 0.5))
        mapper.keyChanged(keyCode: Key.up, isDown: true)
        #expect(sent.all.last == ControllerState(buttons: [.square, .dpadUp], leftX: 16384))
    }

    @Test func aDisconnectedControllerReleasesWhatItHeld() {
        let mapper = makeMapper()
        mapper.gamepadChanged(GamepadSnapshot(pressed: .cross, leftY: 1, r2: 1))
        mapper.gamepadChanged(nil)
        #expect(sent.all == [ControllerState(buttons: .cross, r2: 255, leftY: -32767), .idle])
    }

    @Test func losingFocusReleasesEverythingUntilResume() {
        let mapper = makeMapper()
        mapper.keyChanged(keyCode: Key.d, isDown: true)
        mapper.gamepadChanged(GamepadSnapshot(pressed: .r1))
        mapper.suspend()
        #expect(sent.all.last == .idle)

        let count = sent.all.count
        mapper.gamepadChanged(GamepadSnapshot(pressed: [.r1, .l1]))
        #expect(sent.all.count == count, "nothing is sent while suspended")

        mapper.resume()
        #expect(sent.all.count == count, "no controller is attached, and the held key was dropped")
        mapper.keyChanged(keyCode: Key.d, isDown: false)
        #expect(sent.all.count == count, "the late key-up of a dropped key changes nothing")
    }

    @Test func startAndStopWithoutAControllerAreSafe() {
        let mapper = makeMapper()
        mapper.start()
        mapper.start()
        mapper.stop()
        mapper.stop()
        #expect(mapper.controllerName == nil, "stop() lets go of the controller")
    }
}
