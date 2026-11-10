import Foundation

/// Which bytes of a file are safely on disk: sorted, separate half-open ranges. A download saves it
/// only after flushing the file, so a stop at any moment loses at most what arrived since.
public struct ByteSpans: Hashable, Sendable, Codable {
    public struct Span: Hashable, Sendable, Codable {
        public var lower: Int64
        public var upper: Int64

        public var range: Range<Int64> { lower..<upper }
    }

    public private(set) var spans: [Span] = []

    public init(_ ranges: [Range<Int64>] = []) {
        for range in ranges { insert(range) }
    }

    public var ranges: [Range<Int64>] { spans.map(\.range) }

    public var byteCount: Int64 { spans.reduce(0) { $0 + $1.upper - $1.lower } }

    public func isComplete(length: Int64) -> Bool {
        length == 0 || (spans.count == 1 && spans[0].lower == 0 && spans[0].upper >= length)
    }

    /// Adds `range`, joining it with the ranges it overlaps or touches.
    public mutating func insert(_ range: Range<Int64>) {
        guard !range.isEmpty else { return }
        var lower = range.lowerBound, upper = range.upperBound
        var kept: [Span] = []
        var placed = false
        for span in spans {
            if span.upper < lower {
                kept.append(span)
            } else if span.lower > upper {
                if !placed {
                    kept.append(Span(lower: lower, upper: upper))
                    placed = true
                }
                kept.append(span)
            } else {
                lower = min(lower, span.lower)
                upper = max(upper, span.upper)
            }
        }
        if !placed { kept.append(Span(lower: lower, upper: upper)) }
        spans = kept
    }

    /// The first range below `length`, at most `size` long, that is neither on disk nor in `busy`
    /// (ranges being fetched now). Nil when every byte is one or the other.
    public func next(length: Int64, size: Int64, busy: [Range<Int64>] = []) -> Range<Int64>? {
        var taken = self
        for range in busy { taken.insert(range) }
        var start: Int64 = 0
        for span in taken.spans {
            if span.lower > start { break }
            start = max(start, span.upper)
        }
        guard start < length else { return nil }
        let blocker = taken.spans.first { $0.lower > start }?.lower ?? length
        return start..<min(start + max(size, 1), blocker, length)
    }
}

/// How a title's bytes are fetched.
public enum TransferPlan {
    /// One connection by default: against the owner's server one filled the link and more only made
    /// the disks seek (Stashy measured 32 MB/s on one against 14 MB/s on eight). Away from home the
    /// distance can hold one connection back, so there a second is tried once.
    public static func triesSecondConnection(isLocal: Bool) -> Bool { !isLocal }

    /// The second connection stays only when the trial moved clearly more, in bytes per second.
    public static func keepsSecondConnection(single: Double, dual: Double) -> Bool {
        single > 0 && dual >= single * 1.25
    }

    /// One request's range in the foreground: small enough that the connections finish together.
    public static let foregroundChunk: Int64 = 16 << 20

    /// One background task's range. iOS runs background tasks one after another and wakes the app
    /// between them, so each carries a good share of the file.
    public static let backgroundSlice: Int64 = 64 << 20

    /// Seconds before trying again after the network failed `attempt` times in a row: 2, 4, 8 … 60.
    public static func retryDelay(attempt: Int) -> Int {
        min(60, 1 << min(max(attempt, 1), 6))
    }
}

/// What an answer to a range request means for the download.
public enum RangeReply: Hashable, Sendable {
    /// The range asked for, out of a file this long.
    case partial(length: Int64)
    /// The whole file instead of the range: the server ignores ranges, so the download restarts on one
    /// connection from the first byte.
    case whole(length: Int64?)
    /// The server is still converting; ask again after this many seconds.
    case notReady(retryAfter: Int)
    case failed(status: Int)

    /// Judges the status and `Content-Range` (`bytes 0-1023/4096`) of the answer to a request for
    /// `requested`, with the answer's `Content-Length`.
    public static func judge(status: Int, contentRange: String?, contentLength: Int64?, retryAfter: String?, requested: Range<Int64>) -> RangeReply {
        switch status {
        case 206:
            guard let parsed = contentRange.flatMap(parse), parsed.start == requested.lowerBound, let length = parsed.length else {
                return .whole(length: nil)
            }
            return .partial(length: length)
        case 200:
            return .whole(length: contentLength)
        case 503:
            return .notReady(retryAfter: retryAfter.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.map { min(max($0, 1), 30) } ?? 5)
        default:
            return .failed(status: status)
        }
    }

    /// `bytes 0-1023/4096` → start 0, length 4096; `*` for the length gives nil.
    static func parse(_ header: String) -> (start: Int64, length: Int64?)? {
        let text = header.trimmingCharacters(in: .whitespaces)
        guard text.lowercased().hasPrefix("bytes ") else { return nil }
        let parts = text.dropFirst(6).split(separator: "/", maxSplits: 1)
        guard parts.count == 2, let dash = parts[0].firstIndex(of: "-"), let start = Int64(parts[0][..<dash]) else { return nil }
        return (start, Int64(parts[1]))
    }
}
