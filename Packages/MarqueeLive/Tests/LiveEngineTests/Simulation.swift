import Foundation
import Libavcodec
import Libavformat
import Libavutil
import LiveFixtures
@testable import LiveEngine

/// An output that records what it is given and plays against a clock the test moves.
final class RecordingOutput: LiveOutput, @unchecked Sendable {
    struct Picture {
        let time: Double
        let immediately: Bool
        let width: Int32
        let height: Int32
        /// When it was handed over, on the test's clock.
        let at: Double
    }

    struct Sound {
        let time: Double
        let duration: Double
        let at: Double
    }

    private let lock = NSLock()
    private let wallClock: @Sendable () -> Double
    private var base = (time: 0.0, at: 0.0)
    private var _rate = 0.0
    private var _pictures: [Picture] = []
    private var _sound: [Sound] = []
    private var _flushes = 0

    /// `wallClock`: the clock the presentation time runs against.
    init(wallClock: @escaping @Sendable () -> Double) {
        self.wallClock = wallClock
    }

    var pictures: [Picture] { lock.withLock { _pictures } }
    var sound: [Sound] { lock.withLock { _sound } }
    var rate: Double { lock.withLock { _rate } }
    var flushes: Int { lock.withLock { _flushes } }

    var time: Double {
        lock.withLock { base.time + (wallClock() - base.at) * _rate }
    }

    func setRate(_ rate: Double, time: Double?) {
        lock.withLock {
            let now = wallClock()
            base = (time ?? base.time + (now - base.at) * _rate, now)
            _rate = rate
        }
    }

    func enqueueVideo(_ frame: UnsafeMutablePointer<AVFrame>, time: Double, immediately: Bool) {
        let picture = Picture(
            time: time, immediately: immediately, width: frame.pointee.width, height: frame.pointee.height, at: wallClock()
        )
        lock.withLock { _pictures.append(picture) }
    }

    func enqueueAudio(_ samples: UnsafeBufferPointer<Float>, time: Double) {
        let sound = Sound(time: time, duration: Double(samples.count / 2) / 48_000, at: wallClock())
        lock.withLock { _sound.append(sound) }
    }

    func flush(keepingImage: Bool) {
        lock.withLock { _flushes += 1 }
    }
}

/// A test-moved clock.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0.0

    var now: Double {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// Plays a stream through `LiveCore` on a simulated clock, as `LivePipeline`'s two threads would: each demuxed
/// packet is ingested when the tuner would have sent its last byte, and the video side steps when woken or when
/// its wait runs out. Decoding takes no simulated time.
struct Simulation {
    let output: RecordingOutput
    let core: LiveCore
    let events: [(time: Double, event: LiveEvent)]
    /// When the request went out.
    let startedAt: Double
    /// When the tuner sent the first byte of each segment after the first.
    let splices: [Double]

    /// `delivery` maps when the tuner sent a byte to when it reached the phone, both in seconds from its first byte;
    /// `tail` runs the clock on after the last byte. Each hook runs at its time from the first byte's delivery, and
    /// gets the clock's reading.
    static func run(
        _ segments: [SyntheticTS.Segment], options: VideoOptions = VideoOptions(), tail: Double = 1,
        delivery relative: (Double) -> Double = { $0 }, at hooks: [(Double, (LiveCore, Double) -> Void)] = []
    ) throws -> Simulation {
        let stream = try fixture(segments)
        let origin = stream.chunk.marks[0].time
        func delivery(_ sent: Double) -> Double { origin + relative(sent - origin) }
        let clock = TestClock()
        let output = RecordingOutput { [clock] in clock.now }
        let collected = EventLog()
        let startedAt = delivery(origin) - 0.03
        let core = LiveCore(output: output, options: options, startedAt: startedAt) { [clock] event in
            collected.append(clock.now, event)
        }
        // A reader there before the first byte gets every byte at once.
        let buffer = TimeshiftBuffer(folder: nil, limits: .inMemory)
        let reader = buffer.reader(delay: 0, preroll: 0)
        buffer.write(stream.chunk.bytes)
        buffer.finish()
        let demuxer = try TSDemuxer(reader: reader)
        let packet = try Packet()
        var pendingHooks = hooks.map { (delivery(origin) + $0.0, $0.1) }.sorted { $0.0 < $1.0 }
        var nextStep = startedAt
        var shape = TSDemuxer.ProgramShape()
        var last = startedAt

        func advance(to time: Double) {
            while nextStep <= time {
                while let hook = pendingHooks.first, hook.0 <= nextStep {
                    clock.now = hook.0
                    hook.1(core, hook.0)
                    pendingHooks.removeFirst()
                }
                clock.now = nextStep
                nextStep += max(core.step(now: nextStep), 0.001)
            }
        }

        while demuxer.read(into: packet.pointer) >= 0 {
            defer { av_packet_unref(packet.pointer) }
            let arrival = max(delivery(stream.chunk.time(at: avio_tell(demuxer.context.pointee.pb))), last)
            last = arrival
            advance(to: arrival)
            clock.now = arrival
            if demuxer.programShape != shape {
                shape = demuxer.programShape
                core.updateStreams(demuxer.context)
            }
            guard let avStream = demuxer.stream(packet.pointer.pointee.stream_index) else { continue }
            if core.ingest(packet.pointer, stream: avStream, now: arrival) { nextStep = min(nextStep, arrival) }
        }
        advance(to: last + tail)
        return Simulation(
            output: output, core: core, events: collected.events, startedAt: startedAt,
            splices: stream.splices.map(delivery)
        )
    }

    var phases: [LivePhase] {
        events.compactMap { if case .phase(let phase) = $0.event { phase } else { nil } }
    }

    func times(of phase: LivePhase) -> [Double] {
        events.compactMap { if case .phase(phase) = $0.event { $0.time } else { nil } }
    }

    func count(_ match: (LiveEvent) -> Bool) -> Int {
        events.filter { match($0.event) }.count
    }

    // MARK: - Fixtures

    struct Stream {
        let chunk: SyntheticTS.Chunk
        let splices: [Double]
    }

    private static let cache = FixtureCache()

    /// Generated once per segment list for the whole test run.
    static func fixture(_ segments: [SyntheticTS.Segment]) throws -> Stream {
        try cache.stream(for: segments)
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [(time: Double, event: LiveEvent)] = []

    func append(_ time: Double, _ event: LiveEvent) {
        lock.withLock { _events.append((time, event)) }
    }

    var events: [(time: Double, event: LiveEvent)] { lock.withLock { _events } }
}

/// Each segment list is generated once, by the first test that asks; tests asking for other lists generate theirs at
/// the same time instead of queueing behind it.
private final class FixtureCache: @unchecked Sendable {
    private final class Entry: @unchecked Sendable {
        let lock = NSLock()
        var stream: Simulation.Stream?
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func stream(for segments: [SyntheticTS.Segment]) throws -> Simulation.Stream {
        let key = segments.map { "\($0.kind) \($0.width)x\($0.height) \($0.interlaced) \($0.seconds) \($0.bitRate) \($0.jump)" }
            .joined(separator: "|")
        let entry = lock.withLock {
            if let entry = entries[key] { return entry }
            let entry = Entry()
            entries[key] = entry
            return entry
        }
        return try entry.lock.withLock {
            if let stream = entry.stream { return stream }
            let generator = try SyntheticTS(segments)
            var chunk = SyntheticTS.Chunk(bytes: Data(), marks: [])
            var splices: [Double] = []
            while let next = try generator.next() {
                if !chunk.bytes.isEmpty, let first = next.marks.first { splices.append(first.time) }
                chunk.bytes.append(next.bytes)
                chunk.marks.append(contentsOf: next.marks)
            }
            let stream = Simulation.Stream(chunk: chunk, splices: splices)
            entry.stream = stream
            return stream
        }
    }
}
