import CoreMedia
import CoreVideo
import Foundation
import Libavutil
import Testing
@testable import MarqueeLive

struct SampleBufferOutputTests {
    @Test func soundFollowsOnThroughRoundingAndJumpsWithTheStream() throws {
        var sound = SoundBuffers()
        let frames = 1536
        let samples = [Float](repeating: 0, count: 2 * frames)
        func start(at time: Double) throws -> Int64 {
            let buffer = try #require(samples.withUnsafeBufferPointer { sound.sampleBuffer($0, time: time) })
            #expect(buffer.numSamples == frames)
            return buffer.presentationTimeStamp.value
        }
        #expect(try start(at: 10) == 480_000)
        // One sample late after rounding: the buffer starts where the last ended.
        #expect(try start(at: 10 + Double(frames + 1) / 48_000) == 480_000 + Int64(frames))
        // A gap in the stream is kept.
        #expect(try start(at: 11) == 528_000)
        sound.restart()
        #expect(try start(at: 11 + Double(frames + 1) / 48_000) == 528_000 + Int64(frames) + 1)
    }

    @Test func softwarePicturesCarryTheirColourShapeAndTime() throws {
        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&frame) }
        let picture = try #require(frame)
        picture.pointee.format = AV_PIX_FMT_NV12.rawValue
        picture.pointee.width = 720
        picture.pointee.height = 480
        picture.pointee.sample_aspect_ratio = AVRational(num: 10, den: 11)
        #expect(av_frame_get_buffer(picture, 0) >= 0)

        var pictures = PictureBuffers()
        let sample = try #require(pictures.sampleBuffer(picture, time: 10, immediately: true))
        #expect(sample.presentationTimeStamp == CMTime(value: 900_000, timescale: 90_000))
        let image = try #require(sample.imageBuffer)
        #expect(CVPixelBufferGetWidth(image) == 720 && CVPixelBufferGetHeight(image) == 480)
        #expect(CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        // SD without colour information is BT.601, with its non-square pixels.
        let matrix = CVBufferCopyAttachment(image, kCVImageBufferYCbCrMatrixKey, nil) as? String
        #expect(matrix == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String)
        let aspect = CVBufferCopyAttachment(image, kCVImageBufferPixelAspectRatioKey, nil) as? [String: Int]
        #expect(aspect?[kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String] == 10)
        let attachments = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as NSArray?) as? [[String: Any]]
        #expect(attachments?.first?[kCMSampleAttachmentKey_DisplayImmediately as String] as? Bool == true)
    }
}
