import CChiaki
import Testing
@testable import ChiakiKit

@Suite struct StreamMappingTests {
    @Test func defaultConfigIs1080p60H265WithPresetBitrate() {
        let profile = makeVideoProfile(StreamConfig())
        #expect(profile.width == 1920)
        #expect(profile.height == 1080)
        #expect(profile.max_fps == 60)
        #expect(profile.codec == CHIAKI_CODEC_H265)
        #expect(profile.bitrate > 0)
    }

    @Test func bitrateOverrideAnd720p30() {
        let profile = makeVideoProfile(StreamConfig(resolution: .p720, fps: 30, bitrateKbps: 25_000))
        #expect(profile.width == 1280)
        #expect(profile.height == 720)
        #expect(profile.max_fps == 30)
        #expect(profile.bitrate == 25_000)
    }

    @Test(arguments: [
        (CHIAKI_QUIT_REASON_STOPPED, QuitReason.stopped),
        (CHIAKI_QUIT_REASON_STREAM_CONNECTION_REMOTE_SHUTDOWN, .remoteShutdown),
        (CHIAKI_QUIT_REASON_SESSION_REQUEST_RP_IN_USE, .remoteInUse),
        (CHIAKI_QUIT_REASON_SESSION_REQUEST_CONNECTION_REFUSED, .unreachable),
        (CHIAKI_QUIT_REASON_CTRL_CONNECT_FAILED, .unreachable),
        (CHIAKI_QUIT_REASON_CTRL_CONNECTION_REFUSED, .unreachable),
    ])
    func mapsKnownQuitReasons(reason: ChiakiQuitReason, expected: QuitReason) {
        #expect(QuitReason(chiaki: reason, text: nil) == expected)
    }

    @Test func otherReasonsKeepTheirText() {
        #expect(QuitReason(chiaki: CHIAKI_QUIT_REASON_SESSION_REQUEST_RP_VERSION_MISMATCH, text: nil)
                == .other(String(cString: chiaki_quit_reason_string(CHIAKI_QUIT_REASON_SESSION_REQUEST_RP_VERSION_MISMATCH))))
        #expect(QuitReason(chiaki: CHIAKI_QUIT_REASON_STREAM_CONNECTION_UNKNOWN, text: "Server shutting down")
                == .other("Server shutting down"))
    }

    @Test func userMessagesAreTurkishAndActionable() {
        #expect(QuitReason.remoteShutdown.userMessage == "The PS5 entered rest mode.")
        #expect(QuitReason.remoteInUse.userMessage == "Another Remote Play session is open (e.g. the official app or chiaki-ng).")
        #expect(QuitReason.unreachable.userMessage == "Could not reach the console. Try waking it: psremote-cli wake")
        #expect(QuitReason.stopped.userMessage == "Session closed.")
        #expect(QuitReason.other("x").userMessage == "Session ended: x")
    }

    @Test func controllerButtonsUseLibchiakiBits() {
        let pairs: [(ControllerButtons, ChiakiControllerButton)] = [
            (.cross, CHIAKI_CONTROLLER_BUTTON_CROSS), (.circle, CHIAKI_CONTROLLER_BUTTON_MOON),
            (.square, CHIAKI_CONTROLLER_BUTTON_BOX), (.triangle, CHIAKI_CONTROLLER_BUTTON_PYRAMID),
            (.dpadLeft, CHIAKI_CONTROLLER_BUTTON_DPAD_LEFT), (.dpadRight, CHIAKI_CONTROLLER_BUTTON_DPAD_RIGHT),
            (.dpadUp, CHIAKI_CONTROLLER_BUTTON_DPAD_UP), (.dpadDown, CHIAKI_CONTROLLER_BUTTON_DPAD_DOWN),
            (.l1, CHIAKI_CONTROLLER_BUTTON_L1), (.r1, CHIAKI_CONTROLLER_BUTTON_R1),
            (.l3, CHIAKI_CONTROLLER_BUTTON_L3), (.r3, CHIAKI_CONTROLLER_BUTTON_R3),
            (.options, CHIAKI_CONTROLLER_BUTTON_OPTIONS), (.share, CHIAKI_CONTROLLER_BUTTON_SHARE),
            (.touchpad, CHIAKI_CONTROLLER_BUTTON_TOUCHPAD), (.ps, CHIAKI_CONTROLLER_BUTTON_PS),
        ]
        #expect(pairs.count == Int(CHIAKI_CONTROLLER_BUTTONS_COUNT))
        for (ours, theirs) in pairs { #expect(ours.rawValue == theirs.rawValue) }
    }

    @Test func controllerStateFillsAnIdleChiakiState() {
        let mapped = ChiakiControllerState(ControllerState(buttons: [.cross, .options], l2: 1, r2: 2,
                                                           leftX: 3, leftY: -4, rightX: 5, rightY: -6))
        #expect(mapped.buttons == 0x1001)
        #expect(mapped.l2_state == 1)
        #expect(mapped.r2_state == 2)
        #expect(mapped.left_x == 3)
        #expect(mapped.left_y == -4)
        #expect(mapped.right_x == 5)
        #expect(mapped.right_y == -6)
        // libchiaki's idle values for what sub-project A does not send: no touches, device at rest.
        #expect(mapped.touches.0.id == -1)
        #expect(mapped.touches.1.id == -1)
        #expect(mapped.accel_y == 1)
        #expect(mapped.orient_w == 1)

        var idle = ChiakiControllerState()
        chiaki_controller_state_set_idle(&idle)
        var mappedIdle = ChiakiControllerState(.idle)
        #expect(chiaki_controller_state_equals(&mappedIdle, &idle))
    }
}
