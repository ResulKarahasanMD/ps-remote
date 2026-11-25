import COpus
import Foundation

/// Encodes a stereo 440 Hz sine with libopus the way the PS5 does: one packet per 10 ms frame.
final class SyntheticOpus {
    static let format = (channels: 2, sampleRate: 48000, frameSize: 480)
    private let encoder: OpaquePointer
    private var phase = 0

    init() {
        var status: Int32 = 0
        encoder = opus_encoder_create(Int32(Self.format.sampleRate), Int32(Self.format.channels), OPUS_APPLICATION_AUDIO, &status)!
        precondition(status == OPUS_OK)
    }

    deinit {
        opus_encoder_destroy(encoder)
    }

    /// The next 10 ms of the sine at `amplitude` (0 = digital silence) as one Opus packet.
    func nextPacket(amplitude: Float = 0.5) -> [UInt8] {
        var pcm = [Float](repeating: 0, count: Self.format.frameSize * Self.format.channels)
        for frame in 0 ..< Self.format.frameSize {
            let sample = amplitude * sin(2 * .pi * 440 * Float(phase + frame) / Float(Self.format.sampleRate))
            pcm[frame * 2] = sample
            pcm[frame * 2 + 1] = sample
        }
        phase += Self.format.frameSize
        var packet = [UInt8](repeating: 0, count: 1500)
        let size = opus_encode_float(encoder, pcm, Int32(Self.format.frameSize), &packet, Int32(packet.count))
        precondition(size > 0)
        return Array(packet.prefix(Int(size)))
    }
}
