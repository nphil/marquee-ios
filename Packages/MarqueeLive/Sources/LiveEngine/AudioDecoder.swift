import Foundation
import Libavcodec
import Libavutil
import Libswresample

/// Decodes one audio stream to stereo Float32 at 48 kHz, interleaved. The fixed format means a station switching
/// between 5.1 and 2.0 never needs the renderer flushed. Confined to one thread.
final class AudioDecoder {
    static let sampleRate: Int32 = 48_000
    static let channels: Int32 = 2

    let codecID: AVCodecID
    let name: String
    private let context: CodecContext
    private let frame: Frame
    private var resampler: OpaquePointer?
    private var resamplerInput: (format: Int32, rate: Int32, channels: Int32, mask: UInt64)?
    private var samples: [Float] = []
    /// The channels the station sends, before the downmix.
    private(set) var sourceChannels: Int32 = 0

    init(parameters: UnsafePointer<AVCodecParameters>) throws {
        codecID = parameters.pointee.codec_id
        guard let codec = avcodec_find_decoder(codecID) else {
            throw LiveEngineError.unsupportedCodec(String(cString: avcodec_get_name(codecID)))
        }
        name = String(cString: codec.pointee.name)
        context = try CodecContext(codec: codec)
        frame = try Frame()
        var result = avcodec_parameters_to_context(context.pointer, parameters)
        guard result >= 0 else { throw LiveEngineError.failure("audio parameters", result) }
        context.pointer.pointee.pkt_timebase = AVRational(num: 1, den: 90_000)
        var options: OpaquePointer?
        defer { av_dict_free(&options) }
        if codecID == AV_CODEC_ID_AC3 || codecID == AV_CODEC_ID_EAC3 {
            // The stream's own downmix, with the centre and surround levels it carries, rather than swresample's.
            av_dict_set(&options, "downmix", "stereo", 0)
        }
        result = avcodec_open2(context.pointer, codec, &options)
        guard result >= 0 else { throw LiveEngineError.failure("open \(name)", result) }
    }

    deinit {
        swr_free(&resampler)
    }

    /// Notes the channel count the demuxer's parser found, for diagnostics.
    func noteSource(_ parameters: UnsafePointer<AVCodecParameters>) {
        sourceChannels = parameters.pointee.ch_layout.nb_channels
    }

    /// Sends `packet` and hands each decoded stretch to `body`: interleaved stereo samples and their start
    /// in 90 kHz ticks (nil when the stream gave none). A packet the decoder rejects is skipped.
    func decode(_ packet: UnsafeMutablePointer<AVPacket>, _ body: (UnsafeBufferPointer<Float>, Int64?) -> Void) {
        guard avcodec_send_packet(context.pointer, packet) >= 0 else { return }
        while avcodec_receive_frame(context.pointer, frame.pointer) >= 0 {
            defer { av_frame_unref(frame.pointer) }
            let f = frame.pointer
            guard f.pointee.nb_samples > 0, prepareResampler(for: f) else { continue }
            let capacity = swr_get_out_samples(resampler, f.pointee.nb_samples)
            guard capacity > 0 else { continue }
            if samples.count < Int(capacity * Self.channels) {
                samples = [Float](repeating: 0, count: Int(capacity * Self.channels))
            }
            let produced = samples.withUnsafeMutableBytes { raw -> Int32 in
                var out: UnsafeMutablePointer<UInt8>? = raw.baseAddress?.assumingMemoryBound(to: UInt8.self)
                return withUnsafeMutablePointer(to: &out) { outPointer in
                    f.pointee.extended_data.withMemoryRebound(to: UnsafePointer<UInt8>?.self, capacity: 8) { input in
                        swr_convert(resampler, outPointer, capacity, input, f.pointee.nb_samples)
                    }
                }
            }
            guard produced > 0 else { continue }
            let pts = f.pointee.best_effort_timestamp == FF.noPTS ? nil : f.pointee.best_effort_timestamp
            samples.withUnsafeBufferPointer { all in
                body(UnsafeBufferPointer(rebasing: all[0..<Int(produced * Self.channels)]), pts)
            }
        }
    }

    func flush() {
        avcodec_flush_buffers(context.pointer)
    }

    /// (Re)builds the resampler when the decoded format, rate or layout changes.
    private func prepareResampler(for f: UnsafeMutablePointer<AVFrame>) -> Bool {
        let input = (
            format: f.pointee.format, rate: f.pointee.sample_rate, channels: f.pointee.ch_layout.nb_channels,
            mask: f.pointee.ch_layout.order == AV_CHANNEL_ORDER_NATIVE ? f.pointee.ch_layout.u.mask : 0
        )
        if let current = resamplerInput, resampler != nil, current == input { return true }
        swr_free(&resampler)
        var stereo = AVChannelLayout()
        av_channel_layout_default(&stereo, Self.channels)
        defer { av_channel_layout_uninit(&stereo) }
        let result = withUnsafePointer(to: &f.pointee.ch_layout) { layout in
            swr_alloc_set_opts2(
                &resampler, &stereo, AV_SAMPLE_FMT_FLT, Self.sampleRate,
                layout, AVSampleFormat(rawValue: f.pointee.format), f.pointee.sample_rate, 0, nil
            )
        }
        guard result >= 0, swr_init(resampler) >= 0 else {
            swr_free(&resampler)
            return false
        }
        resamplerInput = input
        return true
    }
}

/// The tuner's slate carries the same frame of AC-3 silence over and over: stereo at 48 kHz and 32 kb/s, 128 bytes
/// (LumaTuner `splice.rs` `SILENCE`). No station sends AC-3 that thin, so a frame of that size and rate marks the slate.
enum SlateSilence {
    static func matches(_ packet: UnsafePointer<AVPacket>) -> Bool {
        guard packet.pointee.size == 128, let data = packet.pointee.data else { return false }
        // Sync word 0x0B77, then CRC, then fscod (48 kHz = 0) and frmsizecod (32 kb/s = 0) in one byte.
        return data[0] == 0x0B && data[1] == 0x77 && data[4] == 0x00
    }
}
