import Foundation

/// Notices that the server lost the conversion a stream plays from. Plex ends a transcode session that
/// sits idle, and a paused stream is one: after a 3 min 40 s pause (2026-11-19) every segment answered 404.
/// AVPlayer retries a missing segment for about 30 s before it fails the item, so the picture froze that
/// long before the start recovery began. The 404s in AVPlayer's error log say it at the first sign.
///
/// A stream gets a fresh watch. The model feeds it the stream's 404s and failure and acts on the verdict.
public struct ConversionWatch: Sendable {
    /// Two misses this close are a lost session, not a slow segment.
    public static let window: TimeInterval = 6
    /// One miss is while less than this is buffered ahead: there is no room left to wait.
    public static let thinBuffer: TimeInterval = 10
    /// A recovery this soon after another counts against the budget.
    public static let settle: TimeInterval = 60
    /// Recoveries within `settle` before the watch stops, so a session that is lost again and again is
    /// left to the start recovery.
    public static let budget = 2

    public enum Cause: String, Sendable {
        /// Two misses within `window`.
        case repeated
        /// A miss with `thinBuffer` or less buffered.
        case thinBuffer
        /// The item failed with a 404.
        case failed
    }

    public enum Verdict: Equatable, Sendable {
        case wait
        /// Start the conversion again where the playhead is; `missed` counts the 404s seen.
        case recover(Cause, missed: Int)
        /// Lost again and again: the usual start recovery takes it.
        case giveUp
    }

    private var misses: [TimeInterval] = []
    private var missed = 0
    private var recoveries: [TimeInterval] = []

    public init() {}

    /// A segment answered 404.
    /// - Parameters:
    ///   - now: a monotonic time, in seconds.
    ///   - bufferAhead: seconds loaded past the playhead; nil when unknown, which counts as none.
    public mutating func notFound(at now: TimeInterval, bufferAhead: TimeInterval?) -> Verdict {
        misses.removeAll { now - $0 > Self.window }
        misses.append(now)
        missed += 1
        if misses.count >= 2 { return lost(.repeated, at: now) }
        if (bufferAhead ?? 0) < Self.thinBuffer { return lost(.thinBuffer, at: now) }
        return .wait
    }

    /// The item failed with a 404: AVPlayer gave up on the missing segments.
    public mutating func failed(at now: TimeInterval) -> Verdict {
        missed += 1
        return lost(.failed, at: now)
    }

    /// The model starts the conversion again: the old stream's misses no longer count, and the recovery
    /// counts against the budget.
    public mutating func recovered(at now: TimeInterval) {
        recoveries.append(now)
        streamStarted()
    }

    /// A stream starts: the misses of the one before no longer count.
    public mutating func streamStarted() {
        misses = []
        missed = 0
    }

    private mutating func lost(_ cause: Cause, at now: TimeInterval) -> Verdict {
        recoveries.removeAll { now - $0 > Self.settle }
        return recoveries.count < Self.budget ? .recover(cause, missed: missed) : .giveUp
    }

    /// Whether AVPlayer reports a 404: an error-log entry for a segment (CoreMediaErrorDomain -12938,
    /// "HTTP 404: File Not Found"), or the item's error (NSURLErrorDomain -1100, "The requested URL was not
    /// found on this server.") or an error beneath it.
    public static func isNotFound(domain: String?, code: Int, comment: String? = nil) -> Bool {
        if domain == "CoreMediaErrorDomain", code == -12938 { return true }
        if domain == "NSURLErrorDomain", code == -1100 { return true }
        return comment?.localizedCaseInsensitiveContains("HTTP 404") ?? false
    }
}
