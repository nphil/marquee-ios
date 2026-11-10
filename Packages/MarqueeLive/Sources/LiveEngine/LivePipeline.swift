import Foundation
import Libavcodec
import Libavformat
import Libavutil

/// One playback of a channel's stream, from its feed to the output. A demux thread reads the feed's buffer at the
/// pipeline's delay behind live, feeds `LiveCore` and decodes sound; a video thread decodes pictures and steers the
/// clock. Runs until `stop()`.
public final class LivePipeline: @unchecked Sendable {
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
        /// The tuner closed the stream, and everything it sent has played.
        case ended
        case engine(LiveEvent)
    }

    /// No data this long before the first picture is a failure, as in the tuner's own wait for a first picture
    /// (LumaTuner `stream.rs` `first_picture`).
    public static let firstPictureTimeout = 5.0
    /// What a pipeline behind live gets at once, so the demuxer has an intra picture to start from.
    static let preroll = 1.0

    public let feed: LiveFeed
    private let reader: TimeshiftReader
    private let gate: OutputGate
    private let relay = Relay()
    private let core: LiveCore
    private let onEvent: @Sendable (Event) -> Void
    private let startedAt: Double
    private let wake = NSCondition()
    // Guarded by `wake`.
    private var pending = false
    private var stopped = false
    private var attached = false
    private var paused = false
    private var replacing: LivePipeline?

    /// `behindLive`: how many seconds behind live it plays the feed. `replacing`: the stream on screen now. It plays on
    /// until this one's tuner answers, then stops, and the output is flushed keeping its last picture until this
    /// stream's first.
    public init(
        feed: LiveFeed, behindLive delay: Double = 0, output: any LiveOutput, options: VideoOptions = VideoOptions(),
        replacing previous: LivePipeline? = nil, onEvent: @escaping @Sendable (Event) -> Void
    ) {
        self.feed = feed
        reader = feed.buffer.reader(delay: delay, preroll: Self.preroll)
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

    /// How far behind live it plays, counting a pause.
    public var behindLive: Double { reader.delay }

    /// Paused, the picture and sound hold and the feed's bytes wait in its buffer; playing again goes on from the same
    /// picture, as much further behind live as the pause lasted.
    public func setPaused(_ paused: Bool) {
        wake.withLock { self.paused = paused }
        reader.setPaused(paused)
        core.setPaused(paused, now: monotonicNow())
    }

    public func start() {
        wake.withLock { attached = true }
        if feed.attach({ [weak self] event in self?.handle(event) }) { takeOver() }
        spawn("LiveTV demux") { [self] in demux() }
        spawn("LiveTV video") { [self] in video() }
    }

    /// Stops a stream this one was still to replace and leaves the feed, which frees the tuner when no other pipeline
    /// plays it. Once it returns, nothing from this pipeline reaches the output.
    public func stop() {
        let (previous, attached) = wake.withLock {
            stopped = true
            wake.broadcast()
            defer {
                replacing = nil
                attached = false
            }
            return (replacing, attached)
        }
        previous?.stop()
        reader.cancel()
        if attached { feed.detach() }
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
        case .ended:
            // Reported once the demuxer has played what the buffer holds.
            break
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
            demuxer = try TSDemuxer(reader: reader)
        } catch is CancellationError {
            return
        } catch {
            // A stream that ended before the demuxer could open it.
            if let ending = feed.ending { onEvent(ending) } else { fail("\(error)") }
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
            guard result >= 0 else {
                // The tuner closed the stream and everything it sent has played. FF.exit is a stop.
                if result == FF.eof { onEvent(feed.ending ?? .ended) }
                return
            }
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
        var position = reader.position
        var dataAt = startedAt
        while true {
            wake.lock()
            if !stopped, !pending { _ = wake.wait(until: Date(timeIntervalSinceNow: wait)) }
            let ended = stopped
            let paused = self.paused
            pending = false
            wake.unlock()
            if ended { return }
            let now = monotonicNow()
            // A pause holds the bytes back on purpose.
            let read = reader.position
            if read != position || paused {
                position = read
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
