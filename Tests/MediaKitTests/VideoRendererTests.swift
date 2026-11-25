import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import MediaKit

@Suite struct VideoRendererTests {
    func pixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                         [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        #expect(status == kCVReturnSuccess)
        return try #require(buffer)
    }

    @Test func sampleBufferIsDisplayImmediatelyWithTheImageSize() throws {
        let sample = try #require(VideoRenderer.makeSampleBuffer(from: try pixelBuffer(width: 64, height: 32)))
        let format = try #require(CMSampleBufferGetFormatDescription(sample))
        let size = CMVideoFormatDescriptionGetDimensions(format)
        #expect(size.width == 64 && size.height == 32)
        let attachments = try #require(CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [NSDictionary])
        #expect(attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] as? Bool == true)
    }

    @MainActor
    @Test func displayEnqueuesWithoutAWindow() async throws {
        let renderer = VideoRenderer()
        renderer.display(try pixelBuffer(width: 64, height: 32))
        #expect(await eventuallyTrue { renderer.displayedCount == 1 })
    }
}

func eventuallyTrue(_ condition: @Sendable () -> Bool) async -> Bool {
    for _ in 0..<100 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
