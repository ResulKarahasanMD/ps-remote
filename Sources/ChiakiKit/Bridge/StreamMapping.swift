import CChiaki

func makeVideoProfile(_ config: StreamConfig) -> ChiakiConnectVideoProfile {
    var profile = ChiakiConnectVideoProfile()
    let resolution = switch config.resolution {
    case .p720: CHIAKI_VIDEO_RESOLUTION_PRESET_720p
    case .p1080: CHIAKI_VIDEO_RESOLUTION_PRESET_1080p
    }
    let fps = config.fps >= 60 ? CHIAKI_VIDEO_FPS_PRESET_60 : CHIAKI_VIDEO_FPS_PRESET_30
    chiaki_connect_video_profile_preset(&profile, resolution, fps)
    profile.codec = CHIAKI_CODEC_H265
    if let kbps = config.bitrateKbps { profile.bitrate = UInt32(kbps) }
    return profile
}

extension QuitReason {
    init(chiaki reason: ChiakiQuitReason, text: String?) {
        switch reason {
        case CHIAKI_QUIT_REASON_STOPPED: self = .stopped
        case CHIAKI_QUIT_REASON_STREAM_CONNECTION_REMOTE_SHUTDOWN: self = .remoteShutdown
        case CHIAKI_QUIT_REASON_SESSION_REQUEST_RP_IN_USE: self = .remoteInUse
        case CHIAKI_QUIT_REASON_SESSION_REQUEST_CONNECTION_REFUSED,
             CHIAKI_QUIT_REASON_CTRL_CONNECT_FAILED,
             CHIAKI_QUIT_REASON_CTRL_CONNECTION_REFUSED: self = .unreachable
        default:
            self = .other(text ?? String(cString: chiaki_quit_reason_string(reason)))
        }
    }
}

extension ChiakiControllerState {
    /// Touchpad and motion fields keep libchiaki's idle values (not part of sub-project A).
    init(_ state: ControllerState) {
        self.init()
        chiaki_controller_state_set_idle(&self)
        buttons = state.buttons.rawValue
        l2_state = state.l2
        r2_state = state.r2
        left_x = state.leftX
        left_y = state.leftY
        right_x = state.rightX
        right_y = state.rightY
    }
}
