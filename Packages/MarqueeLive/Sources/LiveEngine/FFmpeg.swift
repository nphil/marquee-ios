import Foundation
import Libavcodec
import Libavfilter
import Libavutil

/// FFmpeg values defined by expression macros, which the Swift importer does not surface.
enum FF {
    /// AVERROR_EOF, -MKTAG('E','O','F',' ').
    static let eof: Int32 = -541_478_725
    /// AVERROR_EXIT, -MKTAG('E','X','I','T'): the interrupt callback or a read asked FFmpeg to stop.
    static let exit: Int32 = -1_414_092_869
    static let eagain: Int32 = -EAGAIN
    static let einval: Int32 = -EINVAL
    static let enomem: Int32 = -ENOMEM
    static let eio: Int32 = -EIO
    static let noPTS: Int64 = .min

    static let frameCorrupt: Int32 = 1 << 0
    static let frameKey: Int32 = 1 << 1
    static let frameInterlaced: Int32 = 1 << 3
    static let frameTopFieldFirst: Int32 = 1 << 4
    static let packetKey: Int32 = 0x0001
    static let packetCorrupt: Int32 = 0x0002
    static let threadSlice: Int32 = 2
    static let customIO: Int32 = 0x0080
    /// AV_CODEC_FLAG2_FAST: allow speed-ups that are not spec-exact (MPEG-2 skips IDCT rounding care).
    static let codecFlag2Fast: Int32 = 1 << 0
    static let swsBilinear: Int32 = 2
    static let swsPoint: Int32 = 0x10
    /// AV_PIX_FMT_FLAG_HWACCEL: the format's data are references to hardware surfaces.
    static let pixFmtFlagHWAccel: Int32 = 1 << 3
    /// AV_BUFFERSRC_FLAG_KEEP_REF: the filter source takes its own reference to the frame.
    static let bufferSrcKeepRef: Int32 = 1 << 3

    /// The `av_strerror` text for an FFmpeg error code.
    static func errorString(_ code: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        av_strerror(code, &buffer, 128)
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// Why the engine could not go on.
public enum LiveEngineError: Error, Sendable, Equatable, CustomStringConvertible {
    case ffmpeg(step: String, code: Int32, message: String)
    case outOfMemory
    case unsupportedCodec(String)

    static func failure(_ step: String, _ code: Int32) -> LiveEngineError {
        .ffmpeg(step: step, code: code, message: FF.errorString(code))
    }

    public var description: String {
        switch self {
        case .ffmpeg(let step, _, let message): "\(step): \(message)"
        case .outOfMemory: "out of memory"
        case .unsupportedCodec(let name): "no decoder for \(name)"
        }
    }
}

// Owners of single FFmpeg allocations, freed on deinit. Each is confined to the thread that uses it.

final class Packet {
    let pointer: UnsafeMutablePointer<AVPacket>

    init() throws {
        guard let pointer = av_packet_alloc() else { throw LiveEngineError.outOfMemory }
        self.pointer = pointer
    }

    deinit {
        var freed: UnsafeMutablePointer<AVPacket>? = pointer
        av_packet_free(&freed)
    }
}

final class Frame {
    let pointer: UnsafeMutablePointer<AVFrame>

    init() throws {
        guard let pointer = av_frame_alloc() else { throw LiveEngineError.outOfMemory }
        self.pointer = pointer
    }

    deinit {
        var freed: UnsafeMutablePointer<AVFrame>? = pointer
        av_frame_free(&freed)
    }
}

final class CodecContext {
    let pointer: UnsafeMutablePointer<AVCodecContext>

    init(codec: UnsafePointer<AVCodec>) throws {
        guard let pointer = avcodec_alloc_context3(codec) else { throw LiveEngineError.outOfMemory }
        self.pointer = pointer
    }

    deinit {
        var freed: UnsafeMutablePointer<AVCodecContext>? = pointer
        avcodec_free_context(&freed)
    }
}

final class FilterGraph {
    let pointer: UnsafeMutablePointer<AVFilterGraph>

    init() throws {
        guard let pointer = avfilter_graph_alloc() else { throw LiveEngineError.outOfMemory }
        self.pointer = pointer
    }

    deinit {
        var freed: UnsafeMutablePointer<AVFilterGraph>? = pointer
        avfilter_graph_free(&freed)
    }
}

extension AVRational {
    var seconds: Double { den == 0 ? 0 : Double(num) / Double(den) }
}

/// Seconds for a timestamp in a time base; nil for AV_NOPTS_VALUE.
func seconds(_ timestamp: Int64, _ base: AVRational) -> Double? {
    timestamp == FF.noPTS ? nil : Double(timestamp) * base.seconds
}
