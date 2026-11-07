import Foundation

/// Bytes on their way from the network to the demuxer: one writer, one reader. A reader that falls a whole
/// capacity behind loses the oldest bytes rather than stalling the connection; the demuxer finds the next
/// TS sync byte and carries on.
public final class ByteRing: @unchecked Sendable {
    public enum ReadResult: Equatable, Sendable {
        case bytes(Int)
        /// The writer finished and every byte was read.
        case end
        case cancelled
    }

    private let condition = NSCondition()
    private let storage: UnsafeMutableRawBufferPointer
    // Totals since the start; positions in `storage` are these modulo the capacity. Guarded by `condition`.
    private var written: Int64 = 0
    private var read: Int64 = 0
    private var droppedBytes: Int64 = 0
    private var finished = false
    private var isCancelled = false

    public let capacity: Int

    /// 8 MB holds about 3.4 s of an HD station at 19.4 Mb/s.
    public init(capacity: Int = 8 << 20) {
        self.capacity = capacity
        storage = .allocate(byteCount: capacity, alignment: 16)
    }

    deinit { storage.deallocate() }

    public func write(_ bytes: UnsafeRawBufferPointer) {
        guard !bytes.isEmpty, let base = bytes.baseAddress else { return }
        condition.lock()
        defer { condition.unlock() }
        guard !finished, !isCancelled else { return }
        // Only the newest `capacity` bytes of an oversized write can survive.
        let skipped = max(0, bytes.count - capacity)
        let count = bytes.count - skipped
        let overflow = max(0, Int(written - read) + count - capacity)
        read += Int64(overflow)
        droppedBytes += Int64(skipped + overflow)
        var offset = Int(written % Int64(capacity))
        var copied = 0
        while copied < count {
            let chunk = min(count - copied, capacity - offset)
            storage.baseAddress!.advanced(by: offset)
                .copyMemory(from: base.advanced(by: skipped + copied), byteCount: chunk)
            copied += chunk
            offset = (offset + chunk) % capacity
        }
        written += Int64(count)
        condition.broadcast()
    }

    public func write(_ data: Data) {
        data.withUnsafeBytes { write($0) }
    }

    /// No more bytes will come; the reader drains what is left, then sees `.end`.
    public func finish() {
        condition.lock()
        finished = true
        condition.broadcast()
        condition.unlock()
    }

    /// Wakes a waiting reader with `.cancelled`; later reads return it too.
    public func cancel() {
        condition.lock()
        isCancelled = true
        condition.broadcast()
        condition.unlock()
    }

    /// Blocks until at least one byte is available, the writer finishes or the ring is cancelled.
    public func read(into buffer: UnsafeMutableRawBufferPointer) -> ReadResult {
        guard !buffer.isEmpty, let target = buffer.baseAddress else { return .bytes(0) }
        condition.lock()
        defer { condition.unlock() }
        while written == read, !finished, !isCancelled { condition.wait() }
        if isCancelled { return .cancelled }
        let available = Int(written - read)
        if available == 0 { return .end }
        let count = min(available, buffer.count)
        var offset = Int(read % Int64(capacity))
        var copied = 0
        while copied < count {
            let chunk = min(count - copied, capacity - offset)
            target.advanced(by: copied).copyMemory(from: storage.baseAddress!.advanced(by: offset), byteCount: chunk)
            copied += chunk
            offset = (offset + chunk) % capacity
        }
        read += Int64(count)
        return .bytes(count)
    }

    public struct Counts: Sendable, Equatable {
        public var written: Int64
        public var buffered: Int
        public var dropped: Int64
    }

    public var counts: Counts {
        condition.lock()
        defer { condition.unlock() }
        return Counts(written: written, buffered: Int(written - read), dropped: droppedBytes)
    }
}
