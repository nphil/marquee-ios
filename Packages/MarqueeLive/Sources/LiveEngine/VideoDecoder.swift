import Foundation
import Libavcodec
import Libavfilter
import Libavutil

/// How interlaced pictures become frames.
public enum Deinterlacer: String, Sendable, CaseIterable {
    /// `bwdif` on the CPU.
    case bwdif
    /// `yadif_videotoolbox` on the GPU; software pictures are uploaded first.
    case yadifVideoToolbox = "yadif_videotoolbox"
}

/// Rendering choices that L0 measures.
public struct VideoOptions: Sendable, Equatable {
    public var deinterlacer: Deinterlacer
    /// One frame per field (59.94 from 29.97i) rather than one per picture.
    public var framePerField: Bool
    /// MPEG-2 slice threads; 0 lets FFmpeg pick.
    public var sliceThreads: Int32
    /// H.264 and HEVC through VideoToolbox when the platform has it.
    public var hardwareDecode: Bool

    public init(deinterlacer: Deinterlacer = .bwdif, framePerField: Bool = true, sliceThreads: Int32 = 4, hardwareDecode: Bool = true) {
        self.deinterlacer = deinterlacer
        self.framePerField = framePerField
        self.sliceThreads = sliceThreads
        self.hardwareDecode = hardwareDecode
    }
}

/// Decodes one video stream: MPEG-2 in software on slice threads, H.264 and HEVC through VideoToolbox when the
/// platform offers it, in software otherwise. Confined to one thread.
final class VideoDecoder {
    let codecID: AVCodecID
    let name: String
    private let context: CodecContext
    private var device: UnsafeMutablePointer<AVBufferRef>?
    private let frame: Frame

    init(parameters: UnsafePointer<AVCodecParameters>, options: VideoOptions) throws {
        codecID = parameters.pointee.codec_id
        guard let codec = avcodec_find_decoder(codecID) else {
            throw LiveEngineError.unsupportedCodec(String(cString: avcodec_get_name(codecID)))
        }
        name = String(cString: codec.pointee.name)
        context = try CodecContext(codec: codec)
        frame = try Frame()
        let c = context.pointer
        var result = avcodec_parameters_to_context(c, parameters)
        guard result >= 0 else { throw LiveEngineError.failure("video parameters", result) }
        c.pointee.pkt_timebase = AVRational(num: 1, den: 90_000)
        if codecID == AV_CODEC_ID_MPEG2VIDEO {
            c.pointee.thread_type = FF.threadSlice
            c.pointee.thread_count = options.sliceThreads
            c.pointee.flags2 |= FF.codecFlag2Fast
        } else {
            c.pointee.thread_count = 0
            if options.hardwareDecode, Self.offersVideoToolbox(codec) {
                var device: UnsafeMutablePointer<AVBufferRef>?
                if av_hwdevice_ctx_create(&device, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nil, nil, 0) >= 0, let device {
                    c.pointee.hw_device_ctx = av_buffer_ref(device)
                    c.pointee.get_format = preferVideoToolbox
                    // VideoToolbox does the work; frame threads would only hold a picture each.
                    c.pointee.thread_count = 1
                    self.device = device
                }
            }
        }
        result = avcodec_open2(c, codec, nil)
        guard result >= 0 else { throw LiveEngineError.failure("open \(name)", result) }
    }

    deinit {
        av_buffer_unref(&device)
    }

    /// The VideoToolbox device frames are decoded on, when they are.
    var hardwareDevice: UnsafeMutablePointer<AVBufferRef>? { device }

    /// The stream's frame rate once the decoder has read it; nil before.
    var frameRate: AVRational? {
        let rate = context.pointer.pointee.framerate
        return rate.num > 0 && rate.den > 0 ? rate : nil
    }

    /// Drops B pictures (and other pictures nothing refers to) while decoding runs late.
    var skipsNonReference = false {
        didSet { context.pointer.pointee.skip_frame = skipsNonReference ? AVDISCARD_NONREF : AVDISCARD_DEFAULT }
    }

    /// Sends `packet` (nil drains) and hands every picture that comes out to `body`. A packet the decoder
    /// rejects is skipped: the next intra picture recovers.
    func decode(_ packet: UnsafeMutablePointer<AVPacket>?, _ body: (UnsafeMutablePointer<AVFrame>) throws -> Void) throws {
        let sent = avcodec_send_packet(context.pointer, packet)
        guard sent >= 0 || sent == FF.eof else { return }
        while true {
            let received = avcodec_receive_frame(context.pointer, frame.pointer)
            if received == FF.eagain || received == FF.eof { return }
            guard received >= 0 else { return }
            defer { av_frame_unref(frame.pointer) }
            try body(frame.pointer)
        }
    }

    /// Forgets queued pictures and references, for a new start at the next intra picture.
    func flush() {
        avcodec_flush_buffers(context.pointer)
    }

    private static func offersVideoToolbox(_ codec: UnsafePointer<AVCodec>) -> Bool {
        var index: Int32 = 0
        while let config = avcodec_get_hw_config(codec, index) {
            if config.pointee.device_type == AV_HWDEVICE_TYPE_VIDEOTOOLBOX { return true }
            index += 1
        }
        return false
    }
}

/// Takes VideoToolbox when the decoder offers it, else the first software format.
private func preferVideoToolbox(
    _ context: UnsafeMutablePointer<AVCodecContext>?, _ formats: UnsafePointer<AVPixelFormat>?
) -> AVPixelFormat {
    guard var format = formats else { return AV_PIX_FMT_NONE }
    var software = AV_PIX_FMT_NONE
    while format.pointee != AV_PIX_FMT_NONE {
        if format.pointee == AV_PIX_FMT_VIDEOTOOLBOX { return AV_PIX_FMT_VIDEOTOOLBOX }
        if software == AV_PIX_FMT_NONE,
           let descriptor = av_pix_fmt_desc_get(format.pointee),
           descriptor.pointee.flags & UInt64(FF.pixFmtFlagHWAccel) == 0 {
            software = format.pointee
        }
        format += 1
    }
    return software
}

/// What a picture looks like, as far as the filter graph cares: a change means a new graph.
struct PictureShape: Equatable, Sendable, CustomStringConvertible {
    var width: Int32
    var height: Int32
    var format: Int32
    var sampleAspect: AVRational
    var colorSpace: AVColorSpace
    var colorRange: AVColorRange

    init(_ frame: UnsafePointer<AVFrame>) {
        width = frame.pointee.width
        height = frame.pointee.height
        format = frame.pointee.format
        sampleAspect = frame.pointee.sample_aspect_ratio
        colorSpace = frame.pointee.colorspace
        colorRange = frame.pointee.color_range
    }

    var isHardware: Bool { format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue }

    var description: String { "\(width)×\(height)" }

    static func == (a: PictureShape, b: PictureShape) -> Bool {
        a.width == b.width && a.height == b.height && a.format == b.format
            && a.sampleAspect.num == b.sampleAspect.num && a.sampleAspect.den == b.sampleAspect.den
            && a.colorSpace == b.colorSpace && a.colorRange == b.colorRange
    }
}

/// Deinterlaces interlaced pictures and leaves frames NV12 (software) or VideoToolbox-backed. Built for one
/// picture shape; timestamps go in and come out in 1/90 000 s.
final class VideoFilter {
    let shape: PictureShape
    let description: String
    private let graph: FilterGraph
    private let source: UnsafeMutablePointer<AVFilterContext>
    private let sink: UnsafeMutablePointer<AVFilterContext>
    private let output: Frame

    /// How a graph deinterlaces.
    enum Chain: String {
        /// `bwdif` on software pictures.
        case cpu = "bwdif"
        /// Software pictures uploaded to `yadif_videotoolbox`.
        case gpuUpload = "yadif_videotoolbox"
        /// VideoToolbox pictures through `yadif_videotoolbox`.
        case gpu = "yadif_videotoolbox (VT)"
        /// VideoToolbox pictures downloaded to `bwdif`.
        case download = "bwdif (VT)"

        /// The chains to try for a picture, best first.
        static func candidates(for shape: PictureShape, options: VideoOptions, canUpload: Bool) -> [Chain] {
            if shape.isHardware { return [.gpu, .download] }
            return options.deinterlacer == .yadifVideoToolbox && canUpload ? [.gpuUpload, .cpu] : [.cpu]
        }

        func graph(mode: String) -> String {
            let options = "mode=\(mode):parity=auto:deint=interlaced"
            return switch self {
            case .cpu: "bwdif=\(options),format=nv12"
            case .gpuUpload: "format=nv12,hwupload,yadif_videotoolbox=\(options)"
            case .gpu: "yadif_videotoolbox=\(options)"
            case .download: "hwdownload,format=nv12,bwdif=\(options),format=nv12"
            }
        }
    }

    /// `device`: the VideoToolbox device `.gpuUpload` uploads to.
    init(
        first: UnsafePointer<AVFrame>, frameRate: AVRational, chain kind: Chain, framePerField: Bool,
        device: UnsafeMutablePointer<AVBufferRef>?
    ) throws {
        shape = PictureShape(first)
        output = try Frame()
        graph = try FilterGraph()
        let chain = kind.graph(mode: framePerField ? "send_field" : "send_frame")
        description = kind.rawValue

        guard let bufferFilter = avfilter_get_by_name("buffer"), let sinkFilter = avfilter_get_by_name("buffersink"),
              let source = avfilter_graph_alloc_filter(graph.pointer, bufferFilter, "in"),
              let sink = avfilter_graph_alloc_filter(graph.pointer, sinkFilter, "out")
        else { throw LiveEngineError.outOfMemory }
        self.source = source
        self.sink = sink

        guard let parameters = av_buffersrc_parameters_alloc() else { throw LiveEngineError.outOfMemory }
        defer { av_free(parameters) }
        parameters.pointee.format = shape.format
        parameters.pointee.time_base = AVRational(num: 1, den: 90_000)
        parameters.pointee.width = shape.width
        parameters.pointee.height = shape.height
        parameters.pointee.sample_aspect_ratio = shape.sampleAspect.num > 0 ? shape.sampleAspect : AVRational(num: 1, den: 1)
        parameters.pointee.frame_rate = frameRate
        parameters.pointee.color_space = shape.colorSpace
        parameters.pointee.color_range = shape.colorRange
        parameters.pointee.hw_frames_ctx = first.pointee.hw_frames_ctx
        var result = av_buffersrc_parameters_set(source, parameters)
        guard result >= 0 else { throw LiveEngineError.failure("filter source", result) }
        result = avfilter_init_str(source, nil)
        guard result >= 0 else { throw LiveEngineError.failure("filter source", result) }
        result = avfilter_init_str(sink, nil)
        guard result >= 0 else { throw LiveEngineError.failure("filter sink", result) }

        // parse_ptr frees the entries it links and hands back the rest in place, which the defer frees.
        var outputs = avfilter_inout_alloc()
        var inputs = avfilter_inout_alloc()
        defer {
            avfilter_inout_free(&outputs)
            avfilter_inout_free(&inputs)
        }
        guard let output = outputs, let input = inputs else { throw LiveEngineError.outOfMemory }
        output.pointee.name = av_strdup("in")
        output.pointee.filter_ctx = source
        output.pointee.pad_idx = 0
        output.pointee.next = nil
        input.pointee.name = av_strdup("out")
        input.pointee.filter_ctx = sink
        input.pointee.pad_idx = 0
        input.pointee.next = nil
        result = avfilter_graph_parse_ptr(graph.pointer, chain, &inputs, &outputs, nil)
        guard result >= 0 else { throw LiveEngineError.failure("filter \(description)", result) }
        if let device {
            for index in 0..<Int(graph.pointer.pointee.nb_filters) {
                guard let filter = graph.pointer.pointee.filters[index] else { continue }
                if String(cString: filter.pointee.filter.pointee.name) == "hwupload" {
                    filter.pointee.hw_device_ctx = av_buffer_ref(device)
                }
            }
        }
        result = avfilter_graph_config(graph.pointer, nil)
        guard result >= 0 else { throw LiveEngineError.failure("filter \(description)", result) }
    }

    /// Adds a picture and hands every frame that comes out to `body`, its timestamp in 1/90 000 s.
    func filter(_ frame: UnsafeMutablePointer<AVFrame>, _ body: (UnsafeMutablePointer<AVFrame>) throws -> Void) throws {
        let result = av_buffersrc_add_frame_flags(source, frame, Int32(FF.bufferSrcKeepRef))
        guard result >= 0 else { throw LiveEngineError.failure("filter \(description)", result) }
        try drain(body)
    }

    private func drain(_ body: (UnsafeMutablePointer<AVFrame>) throws -> Void) throws {
        while av_buffersink_get_frame(sink, output.pointer) >= 0 {
            defer { av_frame_unref(output.pointer) }
            // The deinterlacers double the time base whether or not they double the frames.
            let base = av_buffersink_get_time_base(sink)
            if output.pointer.pointee.pts != FF.noPTS {
                output.pointer.pointee.pts = av_rescale_q(output.pointer.pointee.pts, base, AVRational(num: 1, den: 90_000))
            }
            try body(output.pointer)
        }
    }
}

/// A VideoToolbox device for uploading software pictures to the GPU deinterlacer; nil where the platform has none.
final class VideoToolboxDevice {
    let pointer: UnsafeMutablePointer<AVBufferRef>

    init?() {
        var device: UnsafeMutablePointer<AVBufferRef>?
        guard av_hwdevice_ctx_create(&device, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nil, nil, 0) >= 0, let device else { return nil }
        pointer = device
    }

    deinit {
        var freed: UnsafeMutablePointer<AVBufferRef>? = pointer
        av_buffer_unref(&freed)
    }
}
