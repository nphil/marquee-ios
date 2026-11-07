import AVFoundation
import CoreMedia
import CoreVideo
import Libavutil
import LiveEngine

/// The engine's output on the phone: pictures on a sample-buffer display layer and sound on an audio renderer, both
/// on one synchronizer whose clock runs on the stream's own timestamps. Software pictures are copied into
/// IOSurface-backed pixel buffers; VideoToolbox pictures go on as they are.
///
/// The renderers are attached with the API that predates iOS 27's sample-buffer receivers: the engine enqueues from
/// its own threads, which the receivers' async enqueue does not fit.
public final class SampleBufferOutput: LiveOutput, @unchecked Sendable {
    let synchronizer = AVSampleBufferRenderSynchronizer()
    let video: AVSampleBufferVideoRenderer
    let audio = AVSampleBufferAudioRenderer()
    private let lock = NSLock()
    // Guarded by `lock`.
    private var pictures = PictureBuffers()
    private var sound = SoundBuffers()

    @MainActor
    public init(layer: AVSampleBufferDisplayLayer) {
        video = layer.sampleBufferRenderer
        // The engine decides when enough is buffered; the clock starts when it says so.
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        synchronizer.addRenderer(video)
        synchronizer.addRenderer(audio)
        // The servo moves the rate by up to 2 %; voices keep their pitch.
        audio.audioTimePitchAlgorithm = .timeDomain
    }

    public var time: Double {
        let now = synchronizer.currentTime()
        return now.isNumeric ? now.seconds : 0
    }

    public func setRate(_ rate: Double, time: Double?) {
        if let time {
            synchronizer.setRate(Float(rate), time: Self.streamTime(time))
        } else {
            synchronizer.rate = Float(rate)
        }
    }

    public func enqueueVideo(_ frame: UnsafeMutablePointer<AVFrame>, time: Double, immediately: Bool) {
        guard let sample = lock.withLock({ pictures.sampleBuffer(frame, time: time, immediately: immediately) }) else { return }
        // Set after the app returns from the background, or after a media-services reset.
        if video.requiresFlushToResumeDecoding || video.status == .failed { video.flush() }
        video.enqueue(sample)
    }

    public func enqueueAudio(_ samples: UnsafeBufferPointer<Float>, time: Double) {
        guard let sample = lock.withLock({ sound.sampleBuffer(samples, time: time) }) else { return }
        if audio.status == .failed { audio.flush() }
        audio.enqueue(sample)
    }

    public func flush(keepingImage: Bool) {
        video.flush(removingDisplayedImage: !keepingImage, completionHandler: nil)
        audio.flush()
        lock.withLock { sound.restart() }
    }

    /// Seconds on the stream's clock, in its own 90 kHz units.
    static func streamTime(_ seconds: Double) -> CMTime {
        CMTime(value: CMTimeValue((seconds * 90_000).rounded()), timescale: 90_000)
    }
}

/// Turns the engine's pictures into sample buffers: VideoToolbox pictures as they are, NV12 copied into a pool sized
/// for the current shape.
struct PictureBuffers {
    private struct Shape: Equatable {
        var width: Int32
        var height: Int32
        var fullRange: Bool
    }

    private var shape: Shape?
    private var pool: CVPixelBufferPool?
    private var format: CMVideoFormatDescription?

    mutating func sampleBuffer(_ frame: UnsafeMutablePointer<AVFrame>, time: Double, immediately: Bool) -> CMSampleBuffer? {
        guard let image = pixelBuffer(frame) else { return nil }
        Colorimetry.attach(frame, to: image)
        if format.map({ !CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: image) }) ?? true {
            format = try? CMVideoFormatDescription(imageBuffer: image)
        }
        guard let format else { return nil }
        let timing = CMSampleTimingInfo(
            duration: .invalid, presentationTimeStamp: SampleBufferOutput.streamTime(time), decodeTimeStamp: .invalid
        )
        guard let sample = try? CMSampleBuffer(imageBuffer: image, formatDescription: format, sampleTiming: timing) else {
            return nil
        }
        if immediately { sample.displayImmediately() }
        return sample
    }

    mutating func pixelBuffer(_ frame: UnsafeMutablePointer<AVFrame>) -> CVPixelBuffer? {
        if frame.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue {
            guard let opaque = frame.pointee.data.3 else { return nil }
            return Unmanaged<CVPixelBuffer>.fromOpaque(opaque).takeUnretainedValue()
        }
        guard frame.pointee.format == AV_PIX_FMT_NV12.rawValue else { return nil }
        let next = Shape(
            width: frame.pointee.width, height: frame.pointee.height, fullRange: frame.pointee.color_range == AVCOL_RANGE_JPEG
        )
        if next != shape {
            shape = next
            pool = Self.pool(next)
            format = nil
        }
        var made: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess, let buffer = made else {
            return nil
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = Int(next.width)
        let height = Int(next.height)
        let planes = [
            (source: frame.pointee.data.0, stride: Int(frame.pointee.linesize.0), rows: height, bytes: width),
            (source: frame.pointee.data.1, stride: Int(frame.pointee.linesize.1), rows: (height + 1) / 2, bytes: (width + 1) / 2 * 2),
        ]
        for (index, plane) in planes.enumerated() {
            guard let source = plane.source, let destination = CVPixelBufferGetBaseAddressOfPlane(buffer, index) else {
                return nil
            }
            let destinationStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, index)
            if destinationStride == plane.stride {
                destination.copyMemory(from: source, byteCount: plane.stride * plane.rows)
            } else {
                for row in 0..<plane.rows {
                    (destination + row * destinationStride).copyMemory(from: source + row * plane.stride, byteCount: plane.bytes)
                }
            }
        }
        return buffer
    }

    private static func pool(_ shape: Shape) -> CVPixelBufferPool? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: shape.fullRange
                ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: Int(shape.width),
            kCVPixelBufferHeightKey: Int(shape.height),
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        return pool
    }
}

/// Colour and pixel shape for the display: broadcast SD is BT.601 and HD BT.709 when the stream does not say, and
/// SD pictures carry a non-square pixel aspect ratio.
enum Colorimetry {
    static func attach(_ frame: UnsafePointer<AVFrame>, to buffer: CVPixelBuffer) {
        let hd = frame.pointee.height > 576
        let matrix: CFString = switch frame.pointee.colorspace {
        case AVCOL_SPC_BT709: kCVImageBufferYCbCrMatrix_ITU_R_709_2
        case AVCOL_SPC_SMPTE170M, AVCOL_SPC_BT470BG: kCVImageBufferYCbCrMatrix_ITU_R_601_4
        default: hd ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 : kCVImageBufferYCbCrMatrix_ITU_R_601_4
        }
        let primaries: CFString = switch frame.pointee.color_primaries {
        case AVCOL_PRI_BT709: kCVImageBufferColorPrimaries_ITU_R_709_2
        case AVCOL_PRI_SMPTE170M: kCVImageBufferColorPrimaries_SMPTE_C
        case AVCOL_PRI_BT470BG: kCVImageBufferColorPrimaries_EBU_3213
        default: hd ? kCVImageBufferColorPrimaries_ITU_R_709_2 : kCVImageBufferColorPrimaries_SMPTE_C
        }
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate)
        // BT.601 and BT.709 share the transfer curve.
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        let aspect = frame.pointee.sample_aspect_ratio
        if aspect.num > 0, aspect.den > 0, aspect.num != aspect.den {
            let spacing = [
                kCVImageBufferPixelAspectRatioHorizontalSpacingKey: Int(aspect.num),
                kCVImageBufferPixelAspectRatioVerticalSpacingKey: Int(aspect.den),
            ] as CFDictionary
            CVBufferSetAttachment(buffer, kCVImageBufferPixelAspectRatioKey, spacing, .shouldPropagate)
        } else {
            // Pool buffers come back with the attachments of their last use.
            CVBufferRemoveAttachment(buffer, kCVImageBufferPixelAspectRatioKey)
        }
    }
}

/// Turns the engine's sound (interleaved stereo Float32 at 48 kHz) into sample buffers. Each buffer starts where the
/// previous one ended unless the engine's time moved by more than two samples, so rounding never opens a gap.
struct SoundBuffers {
    static let sampleRate = 48_000.0
    private let format: CMAudioFormatDescription?
    private var next: Int64?

    init() {
        var description = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1,
            mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0
        )
        var made: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0,
            magicCookie: nil, extensions: nil, formatDescriptionOut: &made
        )
        format = made
    }

    mutating func sampleBuffer(_ samples: UnsafeBufferPointer<Float>, time: Double) -> CMSampleBuffer? {
        guard let format, let base = samples.baseAddress, samples.count >= 2 else { return nil }
        let frames = samples.count / 2
        var start = Int64((time * Self.sampleRate).rounded())
        if let next, abs(start - next) <= 2 { start = next }
        next = start + Int64(frames)
        let bytes = frames * 8
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block
        ) == noErr, let block,
            CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) == noErr
        else { return nil }
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: frames,
            presentationTimeStamp: CMTime(value: start, timescale: CMTimeScale(Self.sampleRate)), packetDescriptions: nil,
            sampleBufferOut: &sample
        ) == noErr else { return nil }
        return sample
    }

    /// After a flush the next buffer takes the engine's time as it is.
    mutating func restart() {
        next = nil
    }
}

extension CMSampleBuffer {
    /// Shows the picture as soon as it is enqueued, whatever the clock says: the first still of a tune.
    func displayImmediately() {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: true),
              CFArrayGetCount(attachments) > 0
        else { return }
        let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(
            first, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }
}
