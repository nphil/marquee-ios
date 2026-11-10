import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A channel's stream as it came from the tuner, kept so playback can pause and go back. One writer, the connection,
/// and any number of readers, each playing the bytes back a set delay after they came. The bytes go to segment files
/// in a folder of the buffer's own, so minutes of them cost disk rather than memory; the oldest whole segment goes once
/// the buffer holds more than `Limits.bytes` or its newest byte is older than `Limits.seconds`. Without a folder, or
/// once the disk refuses a write, new segments stay in memory under `Limits.memoryBytes`.
public final class TimeshiftBuffer: @unchecked Sendable {
    public struct Limits: Sendable, Equatable {
        public var bytes: Int64
        public var seconds: Double

        public init(bytes: Int64, seconds: Double) {
            self.bytes = bytes
            self.seconds = seconds
        }

        /// How far back playback can go.
        public static let longest = 30.0 * 60
        /// 4 GB holds 27 min of an HD station at its 19.4 Mb/s ceiling.
        public static let diskBytes: Int64 = 4 << 30
        /// 26 s at 19.4 Mb/s.
        public static let memoryBytes: Int64 = 64 << 20

        /// `longest`, within half the volume's free space and at most `diskBytes`.
        public static func onDisk(freeSpace: Int64) -> Limits {
            Limits(bytes: min(diskBytes, max(0, freeSpace) / 2), seconds: longest)
        }

        public static let inMemory = Limits(bytes: memoryBytes, seconds: longest)
    }

    /// A reader started at the farthest point back has this much of the bit rate rising before the bytes it plays
    /// are evicted.
    static let margin = 5.0
    /// Writes within this of the last mark extend it: the pace readers keep needs no finer.
    static let markSpacing = 0.02

    fileprivate let condition = NSCondition()
    fileprivate let clock: @Sendable () -> Double
    private let folder: URL?
    // Guarded by `condition`.
    private var limits: Limits
    private var segmentBytes: Int64
    private var segments: [Segment] = []
    /// Where each run of bytes ends and when it came, in order; those before `head` are evicted and dropped in bulk.
    private var marks: [Mark] = []
    private var head = 0
    fileprivate private(set) var written: Int64 = 0
    /// The newest disk segment's, while it takes writes.
    private var writer: Int32 = -1
    private var diskFailed = false
    fileprivate private(set) var finished = false
    fileprivate private(set) var discarded = false

    private struct Segment {
        let start: Int64
        var end: Int64
        /// Nil for a segment in memory.
        let path: String?
        var bytes = Data()
    }

    private struct Mark {
        var end: Int64
        let arrival: Double
    }

    /// `folder`: where the segment files go, made if missing; nil keeps them in memory.
    public convenience init(folder: URL?, limits: Limits) {
        self.init(folder: folder, limits: limits, segmentBytes: nil) { monotonicNow() }
    }

    init(folder: URL?, limits: Limits, segmentBytes: Int64?, clock: @escaping @Sendable () -> Double) {
        self.clock = clock
        let made = folder.flatMap { (try? FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)) != nil ? $0 : nil }
        self.folder = made
        self.limits = made == nil ? Limits(bytes: min(limits.bytes, Limits.memoryBytes), seconds: limits.seconds) : limits
        self.segmentBytes = segmentBytes ?? Self.segmentBytes(for: self.limits.bytes)
    }

    deinit {
        if writer >= 0 { closeFile(writer) }
    }

    /// Every buffer's folder goes in this one.
    public static func root(in temporary: URL) -> URL {
        temporary.appendingPathComponent("Timeshift", isDirectory: true)
    }

    /// A buffer in a folder of its own under `temporary`, as large as the volume's free space allows, or in memory when
    /// that is less than `Limits.memoryBytes`.
    public static func temporary(in temporary: URL = FileManager.default.temporaryDirectory) -> TimeshiftBuffer {
        // The strict figure: the "important usage" one counts purgeable space iOS may never free.
        let free = (try? temporary.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity ?? 0
        let limits = Limits.onDisk(freeSpace: Int64(free))
        guard limits.bytes > Limits.memoryBytes else { return TimeshiftBuffer(folder: nil, limits: .inMemory) }
        return TimeshiftBuffer(folder: root(in: temporary).appendingPathComponent(UUID().uuidString, isDirectory: true), limits: limits)
    }

    /// Deletes the folders a previous run left: it ended without discarding its buffers (a crash, or the system ending
    /// the app). Call at launch, before any buffer is made: the folders are listed at once and deleted on `queue`.
    public static func removeLeftovers(
        in temporary: URL = FileManager.default.temporaryDirectory, on queue: DispatchQueue = .global(qos: .utility)
    ) {
        let found = (try? FileManager.default.contentsOfDirectory(at: root(in: temporary), includingPropertiesForKeys: nil)) ?? []
        guard !found.isEmpty else { return }
        queue.async {
            for url in found { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// About 1/128 of the cap, in whole TS packets and at most 32 MB, so an eviction gives back little at a time.
    static func segmentBytes(for cap: Int64) -> Int64 {
        max(188, min(cap / 128, 32 << 20) / 188 * 188)
    }

    public var now: Double { clock() }

    public var isOnDisk: Bool { condition.withLock { folder != nil && !diskFailed } }

    // MARK: Writer

    public func write(_ data: Data) {
        data.withUnsafeBytes { write($0) }
    }

    public func write(_ bytes: UnsafeRawBufferPointer) {
        guard !bytes.isEmpty, let base = bytes.baseAddress else { return }
        condition.lock()
        defer { condition.unlock() }
        guard !finished, !discarded else { return }
        let now = clock()
        var offset = 0
        while offset < bytes.count {
            if needsSegment { addSegment() }
            let last = segments.count - 1
            let room = Int(segmentBytes - (segments[last].end - segments[last].start))
            let chunk = UnsafeRawBufferPointer(start: base + offset, count: min(room, bytes.count - offset))
            var count = chunk.count
            if segments[last].path == nil {
                segments[last].bytes.append(chunk.bindMemory(to: UInt8.self))
            } else {
                count = writeFully(writer, chunk)
                if count < chunk.count { moveToMemory() }
            }
            segments[last].end += Int64(count)
            written += Int64(count)
            offset += count
        }
        mark(now)
        evict(now)
        condition.broadcast()
    }

    /// No more bytes will come; readers play out what is left, then see `.end`.
    public func finish() {
        condition.withLock {
            finished = true
            if writer >= 0 { closeFile(writer) }
            writer = -1
            condition.broadcast()
        }
    }

    /// Ends the buffer: readers see `.cancelled`, and the folder is deleted before this returns.
    public func discard() {
        let folder: URL? = condition.withLock {
            defer { discarded = true }
            if writer >= 0 { closeFile(writer) }
            writer = -1
            segments.removeAll()
            marks.removeAll()
            head = 0
            condition.broadcast()
            return discarded ? nil : self.folder
        }
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    /// A writer feeding the buffer can stop.
    public var isDiscarded: Bool { condition.withLock { discarded } }

    private var needsSegment: Bool {
        guard let last = segments.last else { return true }
        return last.end - last.start >= segmentBytes || (last.path != nil && writer < 0)
    }

    private func addSegment() {
        if writer >= 0 { closeFile(writer) }
        writer = -1
        if let folder, !diskFailed {
            let path = folder.appendingPathComponent("\(written).ts").path
            writer = openFile(path, forWriting: true)
            if writer >= 0 {
                segments.append(Segment(start: written, end: written, path: path))
                return
            }
            moveToMemory()
        }
        segments.append(Segment(start: written, end: written, path: nil, bytes: Data(capacity: Int(segmentBytes))))
    }

    /// The disk refused a write. What reached it stays readable; new bytes go to memory under its smaller cap, so the
    /// segments on disk are the next to go.
    private func moveToMemory() {
        if writer >= 0 { closeFile(writer) }
        writer = -1
        diskFailed = true
        limits.bytes = min(limits.bytes, Limits.memoryBytes)
        segmentBytes = Self.segmentBytes(for: limits.bytes)
    }

    private func mark(_ now: Double) {
        if marks.count > head, now - marks[marks.count - 1].arrival < Self.markSpacing {
            marks[marks.count - 1].end = written
        } else {
            marks.append(Mark(end: written, arrival: now))
        }
    }

    private func evict(_ now: Double) {
        while segments.count > 1 {
            let first = segments[0]
            let full = written - first.start > limits.bytes
            let old = (arrival(of: first.end - 1) ?? now) < now - limits.seconds
            guard full || old else { break }
            segments.removeFirst()
            if let path = first.path { removeFile(path) }
        }
        while head < marks.count, marks[head].end <= oldest { head += 1 }
        if head >= 4096, head * 2 >= marks.count {
            marks.removeFirst(head)
            head = 0
        }
    }

    // MARK: Positions. Called with `condition` held.

    fileprivate var oldest: Int64 { segments.first?.start ?? written }

    /// The first mark from `head` that `isPast` holds for; it holds for every later one.
    private func firstMark(_ isPast: (Mark) -> Bool) -> Int {
        var low = head
        var high = marks.count
        while low < high {
            let middle = (low + high) / 2
            if isPast(marks[middle]) { high = middle } else { low = middle + 1 }
        }
        return low
    }

    /// When the byte at `offset` came; nil when it has not.
    fileprivate func arrival(of offset: Int64) -> Double? {
        let index = firstMark { $0.end > offset }
        return index < marks.count ? marks[index].arrival : nil
    }

    /// Where the bytes that came by `time` end.
    fileprivate func end(arrivedBy time: Double) -> Int64 {
        let index = firstMark { $0.arrival > time }
        return index > head ? marks[index - 1].end : oldest
    }

    /// The TS packet holding the first byte that came at or after `time`.
    fileprivate func position(arrivingFrom time: Double) -> Int64 {
        let index = firstMark { $0.arrival >= time }
        let start = index > head ? marks[index - 1].end : oldest
        return max(oldest, start - start % 188)
    }

    fileprivate func reach(at now: Double) -> Double {
        let kept = max(oldest, written - (limits.bytes - segmentBytes))
        guard kept < written, let arrival = arrival(of: kept) else { return 0 }
        return max(0, min(now - arrival, limits.seconds) - Self.margin)
    }

    /// How long ago the oldest byte held came.
    fileprivate func span(at now: Double) -> Double {
        arrival(of: oldest).map { max(0, now - $0) } ?? 0
    }

    // MARK: Readers

    /// How far behind live a reader can start and play on at that delay: the span of what the next evictions keep,
    /// less `margin`.
    public var reach: Double {
        condition.withLock { reach(at: clock()) }
    }

    /// A reader `delay` seconds behind live. It starts `preroll` seconds earlier and those bytes come at once, so the
    /// demuxer has a picture to start from; a delay past what the buffer holds starts at its oldest byte.
    public func reader(delay: Double, preroll: Double) -> TimeshiftReader {
        condition.withLock {
            let now = clock()
            let delay = max(0, delay)
            let start = position(arrivingFrom: now - delay - preroll)
            let shift = min(delay, max(0, now - preroll - (arrival(of: start) ?? now)))
            return TimeshiftReader(buffer: self, offset: start, shift: shift)
        }
    }

    fileprivate enum Step {
        case ready(TimeshiftReader.Poll)
        case disk(DiskRead)
    }

    fileprivate struct DiskRead {
        let path: String
        let segment: Int64
        let offset: Int64
        let count: Int
    }

    /// What `reader` reads next, copying it now when it is in memory. Called with `condition` held.
    fileprivate func next(for reader: TimeshiftReader, into target: UnsafeMutableRawBufferPointer, now: Double) -> Step {
        if reader.cancelled || discarded { return .ready(.cancelled) }
        if reader.pausedAt != nil { return .ready(.wait(until: nil)) }
        if reader.offset < oldest {
            // Paused past what the buffer keeps, or the bit rate rose under a reader far back: it plays on from the
            // farthest point that stays.
            reader.offset = position(arrivingFrom: now - reach(at: now))
            reader.shift = max(0, now - (arrival(of: reader.offset) ?? now))
        }
        guard reader.offset < written else { return .ready(finished ? .end : .wait(until: nil)) }
        let due = end(arrivedBy: now - reader.shift)
        guard due > reader.offset else {
            return .ready(.wait(until: arrival(of: reader.offset).map { $0 + reader.shift }))
        }
        var low = 0
        var high = segments.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if segments[middle].start <= reader.offset { low = middle } else { high = middle - 1 }
        }
        let segment = segments[low]
        let start = reader.offset
        let count = Int(min(Int64(target.count), due - start, segment.end - start))
        reader.offset += Int64(count)
        guard let path = segment.path else {
            segment.bytes.withUnsafeBytes { bytes in
                target.baseAddress!.copyMemory(from: bytes.baseAddress! + Int(start - segment.start), byteCount: count)
            }
            return .ready(.bytes(count))
        }
        return .disk(DiskRead(path: path, segment: segment.start, offset: start - segment.start, count: count))
    }
}

/// Plays a `TimeshiftBuffer` back a set delay after the bytes came: each byte is due that long after its arrival, so
/// the stream keeps the tuner's own pace. Pausing holds the bytes and adds the pause to the delay. One thread reads;
/// any may pause or cancel.
public final class TimeshiftReader: @unchecked Sendable {
    public enum ReadResult: Equatable, Sendable {
        case bytes(Int)
        /// The writer finished and every byte was read.
        case end
        case cancelled
    }

    enum Poll: Equatable {
        case bytes(Int)
        /// Nothing is due before this time on the buffer's clock; nil, before the next write, resume or cancel.
        case wait(until: Double?)
        case end
        case cancelled
    }

    private let buffer: TimeshiftBuffer
    // Guarded by the buffer's condition.
    fileprivate var offset: Int64
    fileprivate var shift: Double
    fileprivate var pausedAt: Double?
    fileprivate var cancelled = false
    /// The reading thread's descriptor for the segment it reads.
    private var file: (segment: Int64, descriptor: Int32)?

    fileprivate init(buffer: TimeshiftBuffer, offset: Int64, shift: Double) {
        self.buffer = buffer
        self.offset = offset
        self.shift = shift
    }

    deinit {
        if let file, file.descriptor >= 0 { closeFile(file.descriptor) }
    }

    /// Where the next read starts in the stream.
    public var position: Int64 { buffer.condition.withLock { offset } }

    /// How far behind live this reader plays, counting a pause; at most what the buffer still holds.
    public var delay: Double {
        buffer.condition.withLock {
            let now = buffer.clock()
            return min(shift + (pausedAt.map { now - $0 } ?? 0), buffer.span(at: now))
        }
    }

    public var isPaused: Bool { buffer.condition.withLock { pausedAt != nil } }

    /// Holds the bytes; resuming plays on from the same byte with the pause added to the delay.
    public func setPaused(_ paused: Bool) {
        buffer.condition.withLock {
            let now = buffer.clock()
            if paused {
                pausedAt = pausedAt ?? now
            } else if let start = pausedAt {
                shift += now - start
                pausedAt = nil
            }
            buffer.condition.broadcast()
        }
    }

    /// Wakes a waiting read with `.cancelled`; later reads return it too.
    public func cancel() {
        buffer.condition.withLock {
            cancelled = true
            buffer.condition.broadcast()
        }
    }

    /// Blocks until bytes are due, every byte was read after the writer finished, or the reader is cancelled.
    public func read(into target: UnsafeMutableRawBufferPointer) -> ReadResult {
        guard !target.isEmpty else { return .bytes(0) }
        let condition = buffer.condition
        condition.lock()
        while true {
            let now = buffer.clock()
            switch buffer.next(for: self, into: target, now: now) {
            case .disk(let read):
                condition.unlock()
                return .bytes(readDisk(read, into: target))
            case .ready(.wait(let until)):
                if let until {
                    _ = condition.wait(until: Date(timeIntervalSinceNow: until - now))
                } else {
                    condition.wait()
                }
            case .ready(.bytes(let count)):
                condition.unlock()
                return .bytes(count)
            case .ready(.end):
                condition.unlock()
                return .end
            case .ready(.cancelled):
                condition.unlock()
                return .cancelled
            }
        }
    }

    /// The next read without waiting, at the buffer's clock.
    func poll(into target: UnsafeMutableRawBufferPointer) -> Poll {
        let step = buffer.condition.withLock { buffer.next(for: self, into: target, now: buffer.clock()) }
        switch step {
        case .ready(let poll): return poll
        case .disk(let read): return .bytes(readDisk(read, into: target))
        }
    }

    /// Outside the buffer's lock, through this reader's own descriptor. A segment deleted under it reads as zeros,
    /// which the demuxer skips to the next sync byte; the next read moves past it.
    private func readDisk(_ read: TimeshiftBuffer.DiskRead, into target: UnsafeMutableRawBufferPointer) -> Int {
        if file?.segment != read.segment {
            if let file, file.descriptor >= 0 { closeFile(file.descriptor) }
            file = (read.segment, openFile(read.path, forWriting: false))
        }
        let base = target.baseAddress!
        var done = 0
        if let descriptor = file?.descriptor, descriptor >= 0 {
            while done < read.count {
                let count = pread(descriptor, base + done, read.count - done, off_t(read.offset) + off_t(done))
                if count > 0 {
                    done += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
        if done < read.count { (base + done).initializeMemory(as: UInt8.self, repeating: 0, count: read.count - done) }
        return read.count
    }
}

// Outside the types, where `write` is the system call rather than the buffer's own.

private func openFile(_ path: String, forWriting: Bool) -> Int32 {
    forWriting ? open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600) : open(path, O_RDONLY | O_CLOEXEC)
}

private func closeFile(_ descriptor: Int32) {
    _ = close(descriptor)
}

private func removeFile(_ path: String) {
    _ = unlink(path)
}

/// The bytes written before the first failure.
private func writeFully(_ descriptor: Int32, _ bytes: UnsafeRawBufferPointer) -> Int {
    var done = 0
    while done < bytes.count {
        let count = write(descriptor, bytes.baseAddress! + done, bytes.count - done)
        if count > 0 {
            done += count
        } else if count < 0, errno == EINTR {
            continue
        } else {
            break
        }
    }
    return done
}
