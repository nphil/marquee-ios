import Foundation
import Libavcodec
import Libavformat
import Libavutil

/// MPEG-TS shaped like LumaTuner's output (`splice.rs`), for tests and the bench. Segments of slate and station
/// follow each other on one continuous clock:
/// - slate: progressive MPEG-2 with an intra picture every 0.5 s and the 128-byte AC-3 silence frame, the picture
///   sent 1.0 s and the silence 0.5 s ahead of its time;
/// - station: interlaced MPEG-2 with open GOPs and 5.1 AC-3, the picture sent 0.8 s and the sound 0.25 s ahead.
///
/// At each splice the new segment's first TS packet is its intra picture; what either side would have sent after
/// it is dropped. PMT 0x100, video 0x101, audio 0x102.
public final class SyntheticTS {
    public struct Segment: Sendable {
        public enum Kind: Sendable { case slate, station }

        public var kind: Kind
        public var width: Int32
        public var height: Int32
        public var interlaced: Bool
        public var seconds: Double
        /// MPEG-2 bit rate.
        public var bitRate: Int
        /// How far the stream's clock jumps at the segment's start; the bytes keep coming at the same pace.
        public var jump: Double = 0

        public static func slate(width: Int32 = 320, height: Int32 = 240, seconds: Double) -> Segment {
            Segment(kind: .slate, width: width, height: height, interlaced: false, seconds: seconds, bitRate: 400_000)
        }

        public static func station(
            width: Int32 = 352, height: Int32 = 240, interlaced: Bool = true, seconds: Double, bitRate: Int = 1_500_000,
            jump: Double = 0
        ) -> Segment {
            Segment(
                kind: .station, width: width, height: height, interlaced: interlaced, seconds: seconds, bitRate: bitRate,
                jump: jump
            )
        }

        var videoLead: Double { kind == .slate ? 1.0 : 0.8 }
        var audioLead: Double { kind == .slate ? 0.5 : 0.25 }
    }

    /// Bytes up to `end`, counted from the start of the stream, have left the tuner by `time` seconds.
    public struct Mark: Sendable, Equatable {
        public var end: Int64
        public var time: Double
    }

    public struct Chunk: Sendable {
        public var bytes: Data
        public var marks: [Mark]

        public init(bytes: Data = Data(), marks: [Mark] = []) {
            self.bytes = bytes
            self.marks = marks
        }
    }

    public static let frameRate = AVRational(num: 30_000, den: 1001)
    /// Where the clock starts, in seconds; clear of zero so no timestamp goes negative.
    public static let start = 10.0

    private struct Timed {
        let packet: UnsafeMutablePointer<AVPacket>
        let isVideo: Bool
        let time: Double
    }

    private var segments: [Segment]
    private var index = 0
    private var frames: Int64 = 0
    /// The stream's clock ahead of the sender's, in seconds.
    private var jump = 0.0
    private var pending: [Timed]?
    private let sink = Sink()
    private let muxer: UnsafeMutablePointer<AVFormatContext>
    private let avio: UnsafeMutablePointer<AVIOContext>
    private let opaque: Unmanaged<Sink>
    private var lastAudioPTS = Int64.min
    private var sentEnd: Int64 = 0

    public init(_ segments: [Segment]) throws {
        precondition(!segments.isEmpty)
        self.segments = segments
        var format: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_alloc_output_context2(&format, nil, "mpegts", nil) >= 0, let format else { throw FixtureError.mux }
        muxer = format
        opaque = Unmanaged.passRetained(sink)
        let size: Int32 = 64 * 1024
        guard let buffer = av_malloc(Int(size)),
              let avio = avio_alloc_context(buffer.assumingMemoryBound(to: UInt8.self), size, 1, opaque.toOpaque(), nil, writeSink, nil)
        else { throw FixtureError.mux }
        self.avio = avio
        format.pointee.pb = avio
        // The PCR runs this far behind the video's decode times.
        format.pointee.max_delay = 700_000

        guard let video = avformat_new_stream(format, nil), let audio = avformat_new_stream(format, nil) else { throw FixtureError.mux }
        video.pointee.codecpar.pointee.codec_type = AVMEDIA_TYPE_VIDEO
        video.pointee.codecpar.pointee.codec_id = AV_CODEC_ID_MPEG2VIDEO
        video.pointee.codecpar.pointee.width = segments[0].width
        video.pointee.codecpar.pointee.height = segments[0].height
        video.pointee.time_base = AVRational(num: 1, den: 90_000)
        audio.pointee.codecpar.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        audio.pointee.codecpar.pointee.codec_id = AV_CODEC_ID_AC3
        audio.pointee.codecpar.pointee.sample_rate = 48_000
        av_channel_layout_default(&audio.pointee.codecpar.pointee.ch_layout, 2)
        audio.pointee.time_base = AVRational(num: 1, den: 90_000)

        var options: OpaquePointer?
        defer { av_dict_free(&options) }
        av_dict_set(&options, "mpegts_pmt_start_pid", "256", 0)
        av_dict_set(&options, "mpegts_start_pid", "257", 0)
        av_dict_set(&options, "mpegts_copyts", "1", 0)
        // Each sound frame in its own PES, sent when it is due rather than batched.
        av_dict_set(&options, "pes_payload_size", "0", 0)
        guard avformat_write_header(format, &options) >= 0 else { throw FixtureError.mux }
    }

    deinit {
        for item in pending ?? [] {
            var packet: UnsafeMutablePointer<AVPacket>? = item.packet
            av_packet_free(&packet)
        }
        muxer.pointee.pb = nil
        avformat_free_context(muxer)
        av_free(avio.pointee.buffer)
        var context: UnsafeMutablePointer<AVIOContext>? = avio
        avio_context_free(&context)
        opaque.release()
    }

    /// The whole stream at once.
    public static func make(_ segments: [Segment]) throws -> Chunk {
        let stream = try SyntheticTS(segments)
        var all = Chunk(bytes: Data(), marks: [])
        while let chunk = try stream.next() {
            all.bytes.append(chunk.bytes)
            all.marks.append(contentsOf: chunk.marks)
        }
        return all
    }

    /// Appends `more` segments, for a stream generated as it plays.
    public func append(_ more: [Segment]) {
        segments.append(contentsOf: more)
    }

    /// The next segment's bytes; nil once every segment is out.
    public func next() throws -> Chunk? {
        if pending == nil {
            guard index < segments.count else { return nil }
            pending = try encode(index)
            index += 1
        }
        // `pending` holds segment `index - 1`.
        guard var current = pending else { return nil }
        var following: [Timed]?
        if index < segments.count {
            var next = try encode(index)
            splice(&current, &next, intoStation: segments[index - 1].kind == .slate && segments[index].kind == .station)
            index += 1
            following = next
        }
        pending = following
        var chunk = Chunk(bytes: Data(), marks: [])
        for item in current.sorted(by: { ($0.time, $0.isVideo ? 0 : 1) < ($1.time, $1.isVideo ? 0 : 1) }) {
            defer {
                var packet: UnsafeMutablePointer<AVPacket>? = item.packet
                av_packet_free(&packet)
            }
            if !item.isVideo {
                // Sound that would run backwards across the splice is what the tuner never sends.
                guard item.packet.pointee.pts > lastAudioPTS else { continue }
                lastAudioPTS = item.packet.pointee.pts
            }
            item.packet.pointee.stream_index = item.isVideo ? 0 : 1
            guard av_write_frame(muxer, item.packet) >= 0 else { throw FixtureError.mux }
            chunk.marks.append(Mark(end: avio_tell(avio), time: item.time))
        }
        if pending == nil { av_write_trailer(muxer) }
        avio_flush(avio)
        chunk.bytes = sink.take()
        sentEnd += Int64(chunk.bytes.count)
        // Everything flushed has left by the last packet's time.
        if let last = chunk.marks.last?.time { chunk.marks.append(Mark(end: sentEnd, time: last)) }
        return chunk
    }

    /// LumaTuner's splice (`splice.rs`): the new segment starts with its intra picture, and nothing either side would
    /// send after it survives. Into a station, the slate's silence ends half a second behind the picture and the
    /// station's sound starts with its first frame from there. LumaTuner writes each PES whole once the next on its
    /// PID starts, so the sound frames that arrive while a broadcast's intra picture is still coming in go out before
    /// it: three here, as for a 100 KB picture at 19.4 Mb/s.
    private func splice(_ current: inout [Timed], _ next: inout [Timed], intoStation: Bool) {
        guard let picture = next.first(where: \.isVideo) else { return }
        let soundFrom = intoStation ? picture.packet.pointee.dts - 45_000 : Int64.min
        current.removeAll { item in
            let drop = item.time >= picture.time || (intoStation && !item.isVideo && item.packet.pointee.pts >= soundFrom)
            if drop { Self.free(item) }
            return drop
        }
        next.removeAll { item in
            let drop = !item.isVideo && (item.time < picture.time || item.packet.pointee.pts < soundFrom)
            if drop { Self.free(item) }
            return drop
        }
        guard intoStation else { return }
        let early = next.indices.filter { !next[$0].isVideo }.prefix(3)
        for (n, i) in early.enumerated() {
            next[i] = Timed(packet: next[i].packet, isVideo: false, time: picture.time - 0.001 * Double(early.count - n))
        }
    }

    private static func free(_ item: Timed) {
        var packet: UnsafeMutablePointer<AVPacket>? = item.packet
        av_packet_free(&packet)
    }

    // MARK: - Encoding

    private func encode(_ index: Int) throws -> [Timed] {
        let segment = segments[index]
        let first = frames
        let count = Int64((segment.seconds * Self.frameRate.seconds).rounded())
        frames += count
        jump += segment.jump
        let startTicks = Int64((Self.start + jump) * 90_000) + first * 3003
        // A station joined mid-broadcast has sound from before its first picture.
        let early: Int64 = segment.kind == .station && index > 0 ? 54_000 : 0
        let out = try encodeVideo(segment, first: first, count: count, startTicks: startTicks)
            + encodeAudio(segment, startTicks: startTicks - early, ticks: count * 3003 + early)
        // The bytes leave on the sender's own clock, which does not jump.
        return jump == 0 ? out : out.map { Timed(packet: $0.packet, isVideo: $0.isVideo, time: $0.time - jump) }
    }

    private func encodeVideo(_ segment: Segment, first: Int64, count: Int64, startTicks: Int64) throws -> [Timed] {
        guard let codec = avcodec_find_encoder(AV_CODEC_ID_MPEG2VIDEO), let context = avcodec_alloc_context3(codec) else {
            throw FixtureError.encoder("mpeg2video")
        }
        var contextPointer: UnsafeMutablePointer<AVCodecContext>? = context
        defer { avcodec_free_context(&contextPointer) }
        context.pointee.width = segment.width
        context.pointee.height = segment.height
        context.pointee.pix_fmt = AV_PIX_FMT_YUV420P
        context.pointee.time_base = AVRational(num: Self.frameRate.den, den: Self.frameRate.num)
        context.pointee.framerate = Self.frameRate
        context.pointee.gop_size = 15
        context.pointee.max_b_frames = 2
        context.pointee.bit_rate = Int64(segment.bitRate)
        context.pointee.rc_max_rate = Int64(segment.bitRate) * 2
        context.pointee.rc_buffer_size = Int32(segment.bitRate)
        if segment.interlaced {
            context.pointee.flags |= Self.interlacedDCT | Self.interlacedME
            context.pointee.field_order = AV_FIELD_TT
        }
        guard avcodec_open2(context, codec, nil) >= 0 else { throw FixtureError.encoder("mpeg2video") }

        guard let frame = av_frame_alloc() else { throw FixtureError.encoder("frame") }
        var framePointer: UnsafeMutablePointer<AVFrame>? = frame
        defer { av_frame_free(&framePointer) }
        frame.pointee.width = segment.width
        frame.pointee.height = segment.height
        frame.pointee.format = AV_PIX_FMT_YUV420P.rawValue
        guard av_frame_get_buffer(frame, 0) >= 0 else { throw FixtureError.encoder("frame") }

        var out: [Timed] = []
        func drain() throws {
            while true {
                guard let packet = av_packet_alloc() else { throw FixtureError.encoder("packet") }
                guard avcodec_receive_packet(context, packet) >= 0 else {
                    var unused: UnsafeMutablePointer<AVPacket>? = packet
                    av_packet_free(&unused)
                    return
                }
                // Encoder ticks are frames; the stream's are 1/90 000 s.
                packet.pointee.pts = startTicks + packet.pointee.pts * 3003
                packet.pointee.dts = startTicks + packet.pointee.dts * 3003
                out.append(Timed(packet: packet, isVideo: true, time: Double(packet.pointee.dts) / 90_000 - segment.videoLead))
            }
        }
        for index in 0..<count {
            guard av_frame_make_writable(frame) >= 0 else { throw FixtureError.encoder("frame") }
            Self.draw(frame, number: first + index, kind: segment.kind)
            frame.pointee.pts = index
            if segment.interlaced {
                frame.pointee.flags |= Self.frameInterlaced | Self.frameTopFieldFirst
            }
            guard avcodec_send_frame(context, frame) >= 0 else { throw FixtureError.encoder("mpeg2video") }
            try drain()
        }
        avcodec_send_frame(context, nil)
        try drain()
        return out
    }

    private func encodeAudio(_ segment: Segment, startTicks: Int64, ticks: Int64) throws -> [Timed] {
        guard let codec = avcodec_find_encoder(AV_CODEC_ID_AC3), let context = avcodec_alloc_context3(codec) else {
            throw FixtureError.encoder("ac3")
        }
        var contextPointer: UnsafeMutablePointer<AVCodecContext>? = context
        defer { avcodec_free_context(&contextPointer) }
        let channels: Int32 = segment.kind == .slate ? 2 : 6
        context.pointee.sample_fmt = AV_SAMPLE_FMT_FLTP
        context.pointee.sample_rate = 48_000
        context.pointee.time_base = AVRational(num: 1, den: 48_000)
        // The slate's frame is 128 bytes: stereo at 32 kb/s. A station's is 1536 bytes: 5.1 at 384 kb/s.
        context.pointee.bit_rate = segment.kind == .slate ? 32_000 : 384_000
        guard av_channel_layout_from_string(&context.pointee.ch_layout, channels == 2 ? "stereo" : "5.1") >= 0,
              avcodec_open2(context, codec, nil) >= 0
        else { throw FixtureError.encoder("ac3") }

        guard let frame = av_frame_alloc() else { throw FixtureError.encoder("frame") }
        var framePointer: UnsafeMutablePointer<AVFrame>? = frame
        defer { av_frame_free(&framePointer) }
        let frameSize = context.pointee.frame_size
        frame.pointee.nb_samples = frameSize
        frame.pointee.format = AV_SAMPLE_FMT_FLTP.rawValue
        frame.pointee.sample_rate = 48_000
        guard av_channel_layout_copy(&frame.pointee.ch_layout, &context.pointee.ch_layout) >= 0,
              av_frame_get_buffer(frame, 0) >= 0
        else { throw FixtureError.encoder("frame") }

        let total = ticks * 48_000 / 90_000
        let startSample = startTicks * 48_000 / 90_000
        var out: [Timed] = []
        func drain() throws {
            while true {
                guard let packet = av_packet_alloc() else { throw FixtureError.encoder("packet") }
                guard avcodec_receive_packet(context, packet) >= 0 else {
                    var unused: UnsafeMutablePointer<AVPacket>? = packet
                    av_packet_free(&unused)
                    return
                }
                let pts = av_rescale_q(packet.pointee.pts, AVRational(num: 1, den: 48_000), AVRational(num: 1, den: 90_000))
                packet.pointee.pts = pts
                packet.pointee.dts = pts
                packet.pointee.duration = av_rescale_q(packet.pointee.duration, AVRational(num: 1, den: 48_000), AVRational(num: 1, den: 90_000))
                out.append(Timed(packet: packet, isVideo: false, time: Double(pts) / 90_000 - segment.audioLead))
            }
        }
        var sample: Int64 = 0
        while sample < total {
            guard av_frame_make_writable(frame) >= 0 else { throw FixtureError.encoder("frame") }
            for channel in 0..<Int(channels) {
                guard let plane = frame.pointee.extended_data[channel] else { continue }
                let samples = UnsafeMutableRawPointer(plane).assumingMemoryBound(to: Float.self)
                // A 440 Hz tone at the front for a station; the slate is silent.
                guard segment.kind == .station, channel < 3 else {
                    samples.update(repeating: 0, count: Int(frameSize))
                    continue
                }
                Self.tone.withUnsafeBufferPointer { tone in
                    var position = Int((startSample + sample) % 48_000)
                    var written = 0
                    while written < Int(frameSize) {
                        let run = min(Int(frameSize) - written, 48_000 - position)
                        (samples + written).update(from: tone.baseAddress! + position, count: run)
                        written += run
                        position = 0
                    }
                }
            }
            frame.pointee.pts = startSample + sample
            guard avcodec_send_frame(context, frame) >= 0 else { throw FixtureError.encoder("ac3") }
            try drain()
            sample += Int64(frameSize)
        }
        avcodec_send_frame(context, nil)
        try drain()
        return out
    }

    /// Diagonal bars moving four pixels a frame; on interlaced pictures the bottom field is two pixels further on,
    /// as a camera would have caught it 1/60 s later, so a deinterlacer has work to do.
    private static func draw(_ frame: UnsafeMutablePointer<AVFrame>, number: Int64, kind: Segment.Kind) {
        let width = Int(frame.pointee.width)
        let height = Int(frame.pointee.height)
        let shift = Int(number % 256) * 4
        let luma = frame.pointee.data.0!
        let stride = Int(frame.pointee.linesize.0)
        // Every row is the same ramp, started further along: copy it rather than compute each pixel.
        let ramp = (0..<(width + 256)).map { x in
            kind == .slate ? UInt8(16 + (x & 0xFF) / 4) : UInt8(16 + (x & 0xFF) * 219 / 255)
        }
        ramp.withUnsafeBufferPointer { ramp in
            for y in 0..<height {
                let fieldShift = y & 1 == 1 ? 2 : 0
                (luma + y * stride).update(from: ramp.baseAddress! + ((y + shift + fieldShift) & 0xFF), count: width)
            }
        }
        for (plane, stride, value) in [
            (frame.pointee.data.1!, Int(frame.pointee.linesize.1), UInt8(kind == .slate ? 128 : 96)),
            (frame.pointee.data.2!, Int(frame.pointee.linesize.2), UInt8(kind == .slate ? 128 : 160)),
        ] {
            for y in 0..<height / 2 { (plane + y * stride).update(repeating: value, count: width / 2) }
        }
    }

    /// One second of a 440 Hz tone at 48 kHz: a whole number of cycles, so it repeats seamlessly.
    private static let tone = (0..<48_000).map { Float(0.2 * sin(2 * Double.pi * 440 * Double($0) / 48_000)) }

    private static let interlacedDCT: Int32 = 1 << 18
    private static let interlacedME: Int32 = 1 << 29
    private static let frameInterlaced: Int32 = 1 << 3
    private static let frameTopFieldFirst: Int32 = 1 << 4
}

public enum FixtureError: Error {
    case mux
    case encoder(String)
}

extension SyntheticTS.Chunk {
    /// When the byte at `offset` has left the tuner.
    public func time(at offset: Int64) -> Double {
        var low = 0
        var high = marks.count
        while low < high {
            let middle = (low + high) / 2
            if marks[middle].end < offset { low = middle + 1 } else { high = middle }
        }
        return low < marks.count ? marks[low].time : (marks.last?.time ?? 0)
    }
}

/// Collects what the muxer writes.
private final class Sink {
    private var bytes = Data()

    func append(_ buffer: UnsafePointer<UInt8>, _ count: Int) {
        bytes.append(buffer, count: count)
    }

    func take() -> Data {
        defer { bytes = Data() }
        return bytes
    }
}

private func writeSink(_ opaque: UnsafeMutableRawPointer?, _ buffer: UnsafePointer<UInt8>?, _ size: Int32) -> Int32 {
    guard let opaque, let buffer, size > 0 else { return 0 }
    Unmanaged<Sink>.fromOpaque(opaque).takeUnretainedValue().append(buffer, Int(size))
    return size
}

extension AVRational {
    fileprivate var seconds: Double { Double(num) / Double(den) }
}
