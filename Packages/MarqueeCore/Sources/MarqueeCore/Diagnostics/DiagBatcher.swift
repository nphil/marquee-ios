import Foundation

/// One rendered log line and the level it was logged at.
public struct DiagLine: Sendable, Equatable {
    public var text: String
    public var level: DiagLevel

    public init(_ text: String, level: DiagLevel = .info) {
        self.text = text
        self.level = level
    }
}

/// One message for the log server: lines joined by newlines, and the highest level among them.
public struct DiagMessage: Sendable, Equatable {
    public var text: String
    public var level: DiagLevel
}

/// Packs log lines into messages that fit ntfy's 4096-byte message limit, with room for a header line.
public enum DiagPacker {
    public static let messageLimit = 3800

    /// Lines in order, as few messages as fit `limit` UTF-8 bytes each. A line longer than a whole message
    /// is cut, never inside a character.
    public static func pack(_ lines: [DiagLine], limit: Int = messageLimit) -> [DiagMessage] {
        var messages: [DiagMessage] = []
        var text = ""
        var bytes = 0
        var level = DiagLevel.debug
        for line in lines {
            let fitted = clamp(line.text, toBytes: limit)
            let size = fitted.utf8.count
            if bytes > 0, bytes + 1 + size > limit {
                messages.append(DiagMessage(text: text, level: level))
                text = ""
                bytes = 0
                level = .debug
            }
            if bytes > 0 {
                text += "\n"
                bytes += 1
            }
            text += fitted
            bytes += size
            level = max(level, line.level)
        }
        if bytes > 0 { messages.append(DiagMessage(text: text, level: level)) }
        return messages
    }

    /// The longest prefix of `text` within `limit` UTF-8 bytes that ends on a whole character, with `…`
    /// in place of what was cut.
    public static func clamp(_ text: String, toBytes limit: Int) -> String {
        let utf8 = Array(text.utf8)
        guard utf8.count > limit else { return text }
        let ellipsis = Array("…".utf8)
        var end = max(0, limit - ellipsis.count)
        // Back off continuation bytes (10xxxxxx), then the lead byte of the scalar they belong to.
        while end > 0, end < utf8.count, utf8[end] & 0xC0 == 0x80 { end -= 1 }
        return String(decoding: utf8[..<end], as: UTF8.self) + "…"
    }
}

/// A conservative copy of the log server's own rate limit, so the app never trips it: ntfy's default
/// lets a client burst 60 messages and then refills one every 5 seconds.
public struct TokenBucket: Sendable, Equatable {
    public let capacity: Double
    /// Seconds for one message to come back.
    public let refill: TimeInterval
    public private(set) var tokens: Double
    private var updated: Date

    public init(capacity: Int, refill: TimeInterval, now: Date) {
        self.capacity = Double(capacity)
        self.refill = refill
        tokens = Double(capacity)
        updated = now
    }

    /// Takes one message's worth if there is one.
    public mutating func take(now: Date) -> Bool {
        top(now)
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }

    /// Seconds until a message may go; zero when one may go now.
    public func wait(now: Date) -> TimeInterval {
        var copy = self
        copy.top(now)
        return copy.tokens >= 1 ? 0 : (1 - copy.tokens) * refill
    }

    private mutating func top(_ now: Date) {
        let elapsed = max(0, now.timeIntervalSince(updated))
        tokens = min(capacity, tokens + elapsed / refill)
        updated = now
    }
}

/// When to try again after a send failed: the server's `Retry-After` on 429 and 5xx answers, otherwise
/// doubling from 5 seconds to 5 minutes.
public struct DiagBackoff: Sendable, Equatable {
    public static let first: TimeInterval = 5
    public static let longest: TimeInterval = 300

    public private(set) var failures = 0
    public private(set) var notBefore: Date?

    public init() {}

    public func ready(now: Date) -> Bool {
        notBefore.map { now >= $0 } ?? true
    }

    public mutating func succeeded() {
        failures = 0
        notBefore = nil
    }

    /// Records a failed send: `status` nil when no answer came.
    public mutating func failed(status: Int?, retryAfter: String?, now: Date) {
        failures += 1
        let doubling = min(Self.longest, Self.first * pow(2, Double(failures - 1)))
        var delay = doubling
        if let status, status == 429 || (500..<600).contains(status),
           let header = retryAfter, let asked = Self.seconds(retryAfter: header, now: now) {
            // An hour at most, so a wrong header cannot silence the log for a day.
            delay = min(3600, max(asked, 1))
        }
        notBefore = now.addingTimeInterval(delay)
    }

    /// `Retry-After` as delay seconds or an HTTP date.
    public static func seconds(retryAfter header: String, now: Date) -> TimeInterval? {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        if let seconds = TimeInterval(trimmed), seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: trimmed) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}

/// Folds a run of identical events into its first line and, when the run ends, its last line marked
/// `×N` with the number of repeats.
public struct DiagCoalescer: Sendable {
    private var last: DiagEvent?
    private var repeated: DiagEvent?
    private var count = 0

    public init() {}

    /// The lines `event` adds: none while it repeats the one before.
    public mutating func add(_ event: DiagEvent, in calendar: Calendar = .current) -> [DiagLine] {
        if let last, last.repeats(event) {
            repeated = event
            count += 1
            return []
        }
        var lines = flush(in: calendar)
        last = event
        lines.append(DiagLine(event.line(in: calendar), level: event.level))
        return lines
    }

    /// The end of the current run, if it repeated; the next event starts afresh either way.
    public mutating func flush(in calendar: Calendar = .current) -> [DiagLine] {
        defer {
            repeated = nil
            count = 0
        }
        guard let repeated, count > 0 else { return [] }
        // A later event that matches still repeats the same line, so it folds into a new run.
        return [DiagLine(repeated.line(in: calendar) + " ×\(count)", level: repeated.level)]
    }
}
