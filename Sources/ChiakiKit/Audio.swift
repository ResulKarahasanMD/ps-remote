public struct AudioFormat: Sendable, Equatable {
    public var channels: Int
    public var sampleRate: Int
    /// Samples per channel in one Opus frame.
    public var frameSize: Int

    public init(channels: Int, sampleRate: Int, frameSize: Int) {
        self.channels = channels
        self.sampleRate = sampleRate
        self.frameSize = frameSize
    }
}

/// Receives libchiaki's audio stream on libchiaki's threads. Neither call may block.
public protocol AudioSink: AnyObject, Sendable {
    /// The stream's format; sent before the first packet and again whenever the stream restarts.
    func configure(_ format: AudioFormat)
    /// One Opus packet, valid only during the call. nil means the frame was lost and should be
    /// concealed.
    func consume(_ packet: UnsafeRawBufferPointer?)
}
