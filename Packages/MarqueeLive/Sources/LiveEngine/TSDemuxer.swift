import Foundation
import Libavcodec
import Libavformat
import Libavutil
import Synchronization

/// What the read callback reaches through `opaque`.
private final class RingInput: Sendable {
    let ring: ByteRing
    /// Set from any thread, read by FFmpeg's interrupt callback on the demux thread.
    let cancelled = Atomic(false)

    init(ring: ByteRing) { self.ring = ring }
}

/// An MPEG-TS demuxer reading a `ByteRing` through a custom, non-seekable AVIOContext. Streams appear
/// as their PMT arrives; nothing waits for stream info, which a live start does not need. Confined to the
/// thread that reads it.
final class TSDemuxer {
    let context: UnsafeMutablePointer<AVFormatContext>
    private let avio: UnsafeMutablePointer<AVIOContext>
    private let opaque: Unmanaged<RingInput>
    private var isOpen = true

    /// Blocks until the first bytes arrive. `probeBytes` is what the demuxer reads before returning:
    /// a slate runs at well under 1 Mb/s, so even 32 KB would hold the first picture back.
    init(ring: ByteRing, probeBytes: Int64 = 188 * 7) throws {
        let input = RingInput(ring: ring)
        let bufferSize: Int32 = 64 * 1024
        guard let buffer = av_malloc(Int(bufferSize)) else { throw LiveEngineError.outOfMemory }
        let opaque = Unmanaged.passRetained(input)
        guard let avio = avio_alloc_context(
            buffer.assumingMemoryBound(to: UInt8.self), bufferSize, 0, opaque.toOpaque(), readPacket, nil, nil
        ) else {
            av_free(buffer)
            opaque.release()
            throw LiveEngineError.outOfMemory
        }
        avio.pointee.seekable = 0
        var format = avformat_alloc_context()
        if let format {
            format.pointee.pb = avio
            format.pointee.flags |= FF.customIO
            format.pointee.probesize = probeBytes
            format.pointee.interrupt_callback.callback = interrupt
            format.pointee.interrupt_callback.opaque = opaque.toOpaque()
        }
        let result = avformat_open_input(&format, nil, av_find_input_format("mpegts"), nil)
        guard result >= 0, let format else {
            Self.freeAVIO(avio)
            opaque.release()
            throw result == FF.exit ? CancellationError() as any Error : LiveEngineError.failure("open stream", result)
        }
        context = format
        self.avio = avio
        self.opaque = opaque
    }

    deinit { close() }

    /// av_read_frame: 0 with a packet, FF.eof at the end, FF.exit when cancelled, else an error.
    func read(into packet: UnsafeMutablePointer<AVPacket>) -> Int32 {
        av_read_frame(context, packet)
    }

    func stream(_ index: Int32) -> UnsafeMutablePointer<AVStream>? {
        guard index >= 0, index < Int32(context.pointee.nb_streams) else { return nil }
        return context.pointee.streams[Int(index)]
    }

    /// The stream count and the PMT version: either changes when the program's sounds may have. LumaTuner's slate
    /// sends a PMT without descriptors; the station's, with each sound's language, follows on the same PIDs.
    var programShape: ProgramShape {
        let pmtVersion = context.pointee.nb_programs > 0 ? context.pointee.programs[0]?.pointee.pmt_version ?? -1 : -1
        return ProgramShape(streams: context.pointee.nb_streams, pmtVersion: pmtVersion)
    }

    struct ProgramShape: Equatable {
        var streams: UInt32 = 0
        var pmtVersion: Int32 = -1
    }

    /// Stops a read blocked in the ring; the next read returns FF.exit.
    func cancel() {
        opaque.takeUnretainedValue().cancelled.store(true, ordering: .relaxed)
        opaque.takeUnretainedValue().ring.cancel()
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        var format: UnsafeMutablePointer<AVFormatContext>? = context
        avformat_close_input(&format)
        Self.freeAVIO(avio)
        opaque.release()
    }

    /// Frees an AVIOContext and its buffer, which FFmpeg may have replaced since `avio_alloc_context`.
    private static func freeAVIO(_ avio: UnsafeMutablePointer<AVIOContext>) {
        av_free(avio.pointee.buffer)
        var context: UnsafeMutablePointer<AVIOContext>? = avio
        avio_context_free(&context)
    }
}

// C trampolines: non-capturing, reaching their state only through `opaque`.

private func readPacket(_ opaque: UnsafeMutableRawPointer?, _ buffer: UnsafeMutablePointer<UInt8>?, _ size: Int32) -> Int32 {
    guard let opaque, let buffer, size > 0 else { return FF.einval }
    let input = Unmanaged<RingInput>.fromOpaque(opaque).takeUnretainedValue()
    switch input.ring.read(into: UnsafeMutableRawBufferPointer(start: buffer, count: Int(size))) {
    case .bytes(let count): return Int32(count)
    case .end: return FF.eof
    case .cancelled: return FF.exit
    }
}

private func interrupt(_ opaque: UnsafeMutableRawPointer?) -> Int32 {
    guard let opaque else { return 0 }
    return Unmanaged<RingInput>.fromOpaque(opaque).takeUnretainedValue().cancelled.load(ordering: .relaxed) ? 1 : 0
}
