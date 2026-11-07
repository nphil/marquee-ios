import Foundation
import Libavcodec
import Libavformat
import Libavutil

/// One channel's stream from the request to the output. The connection fills a ring; a demux thread feeds
/// `LiveCore` and decodes sound; a video thread decodes pictures and steers the clock. Runs until `stop()`.
public final class LivePipeline: @unchecked Sendable {
    public enum Input: Sendable {
        /// The tuner's stream URL, `…/auto/v<channel>`.
        case tuner(URL)
        /// Bytes fed by the caller: a recording, in tests and the bench.
        case ring(ByteRing)
    }

    public enum Event: Sendable, Equatable {
        /// The tuner answered 200; the stream this one replaces has stopped.
        case connected
        case refused(TunerRefusal)
        /// Nothing arrived for `firstPictureTimeout` before the first picture.
        case noPicture
        /// The connection broke.
        case lost(String)
        /// The stream cannot be read or its pictures decoded.
        case failed(String)
        /// The tuner closed the stream.
        case ended
        case engine(LiveEvent)
    }

    /// No data this long before the first picture is a failure, as in the tuner's own wait for a first picture
    /// (LumaTuner `stream.rs` `first_picture`).
    public static let firstPictureTimeout = 5.0

    private let input: Input
    private let ring: ByteRing
    private let gate: OutputGate
    private let relay = Relay()
    private let core: LiveCore
    private let onEvent: @Sendable (Event) -> Void
    private let startedAt: Double
    private let wake = NSCondition()
    // Guarded by `wake`.
    private var pending = false
    private var stopped = false
    private var connection: TunerConnection?
    private var replacing: LivePipeline?

    /// `replacing`: the stream on screen now. It plays on until this one's tuner answers, then stops, and the output
    /// is flushed keeping its last picture until this stream's first.
    public init(
        input: Input, output: any LiveOutput, options: VideoOptions = VideoOptions(), replacing previous: LivePipeline? = nil,
        onEvent: @escaping @Sendable (Event) -> Void
    ) {
        self.input = input
        if case .ring(let ring) = input { self.ring = ring } else { ring = ByteRing() }
        gate = OutputGate(output)
        startedAt = monotonicNow()
        self.onEvent = onEvent
        replacing = previous
        let relay = relay
        core = LiveCore(output: gate, options: options, startedAt: startedAt) { event in relay.engine(event) }
        relay.pipeline = self
    }

    public var diagnostics: LiveDiagnostics { core.snapshot }
    public var phase: LivePhase { core.currentPhase }

    /// Background without picture-in-picture: sound goes on and pictures wait for the next intra picture.
    public func setVideoEnabled(_ enabled: Bool) { core.setVideoEnabled(enabled) }

    public func start() {
        switch input {
        case .tuner(let url):
            let connection = TunerConnection(url: url, ring: ring) { [weak self] event in self?.handle(event) }
            wake.withLock { self.connection = connection }
            connection.start()
        case .ring:
            takeOver()
        }
        spawn("LiveTV demux") { [self] in demux() }
        spawn("LiveTV video") { [self] in video() }
    }

    /// Ends the stream, frees the tuner and stops a stream this one was still to replace. Once it returns, nothing
    /// from this pipeline reaches the output.
    public func stop() {
        let (connection, previous) = wake.withLock {
            stopped = true
            wake.broadcast()
            defer { replacing = nil }
            return (self.connection, replacing)
        }
        previous?.stop()
        connection?.cancel()
        ring.cancel()
        gate.close()
    }

    private func handle(_ event: TunerConnection.Event) {
        switch event {
        case .response(let status, let after):
            core.note(response: after)
            guard status == 200 else { return }
            takeOver()
            onEvent(.connected)
        case .firstByte(let after):
            core.note(firstByte: after)
        case .refused(let refusal):
            onEvent(.refused(refusal))
            stop()
        case .ended(let error):
            onEvent(error.map { .lost($0) } ?? .ended)
        }
    }

    /// Stops the stream on screen; its last picture stays until this stream's first.
    private func takeOver() {
        let previous = wake.withLock {
            defer { replacing = nil }
            return replacing
        }
        guard let previous else { return }
        previous.stop()
        gate.setRate(0, time: nil)
        gate.flush(keepingImage: true)
    }

    private func fail(_ message: String) {
        onEvent(.failed(message))
        stop()
    }

    private func signal() {
        wake.withLock {
            pending = true
            wake.signal()
        }
    }

    private func spawn(_ name: String, _ body: @escaping @Sendable () -> Void) {
        let thread = Thread(block: body)
        thread.name = name
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func demux() {
        let demuxer: TSDemuxer
        do {
            demuxer = try TSDemuxer(ring: ring)
        } catch {
            if !(error is CancellationError) { fail("\(error)") }
            return
        }
        guard let packet = try? Packet() else {
            fail("\(LiveEngineError.outOfMemory)")
            return
        }
        var shape = TSDemuxer.ProgramShape()
        while true {
            let result = demuxer.read(into: packet.pointer)
            if result == FF.eagain { continue }
            guard result >= 0 else { return }
            if demuxer.programShape != shape {
                shape = demuxer.programShape
                core.updateStreams(demuxer.context)
            }
            if let stream = demuxer.stream(packet.pointer.pointee.stream_index),
               core.ingest(packet.pointer, stream: stream, now: monotonicNow()) {
                signal()
            }
            av_packet_unref(packet.pointer)
        }
    }

    private func video() {
        var wait = 0.0
        var written: Int64 = 0
        var dataAt = startedAt
        while true {
            wake.lock()
            if !stopped, !pending { _ = wake.wait(until: Date(timeIntervalSinceNow: wait)) }
            let ended = stopped
            pending = false
            wake.unlock()
            if ended { return }
            let now = monotonicNow()
            let total = ring.counts.written
            if total != written {
                written = total
                dataAt = now
            }
            if core.currentPhase == .opening, now - dataAt >= Self.firstPictureTimeout {
                onEvent(.noPicture)
                stop()
                return
            }
            wait = core.step(now: now)
        }
    }

    /// Carries the core's events to the pipeline, which does not exist yet when the core is made.
    private final class Relay: @unchecked Sendable {
        weak var pipeline: LivePipeline?

        func engine(_ event: LiveEvent) {
            guard let pipeline else { return }
            if case .failed(let message) = event {
                pipeline.fail(message)
            } else {
                pipeline.onEvent(.engine(event))
            }
        }
    }
}
