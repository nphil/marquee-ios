import Foundation

/// What follows a stream that failed while it played: a lost connection, a timeout, a read error (EIO), a
/// 5xx or a server conversion that was lost is a hiccup of the server or the link, so the player starts the
/// same stream again at the last played position, after 1, 2, 4 and 8 s and then every 8 s, until `budget`
/// from the first failure has passed. Only a refusal that will not change (401, 403, 404, 410), or the
/// budget running out, ends the playback. A server that stalled for 23 s once ended a film with one
/// failed read (2026-11-25).
public struct StreamReconnect: Sendable, Equatable {
    public enum Step: Sendable, Equatable {
        /// Attempt `attempt` (from 1), after `after`.
        case reconnect(attempt: Int, after: Duration)
        case giveUp
    }

    /// From the first failure of a run of failures to the last attempt's start.
    public static let budget: TimeInterval = 30
    static let longestDelay: TimeInterval = 8
    /// Played seconds on the new stream after which the run of failures counts as over.
    static let settledAfter: TimeInterval = 20

    public private(set) var attempts = 0
    private var firstFailure: TimeInterval?
    private var landedAt: TimeInterval?

    public init() {}

    /// - Parameter now: Seconds on a monotonic clock.
    public mutating func failed(now: TimeInterval) -> Step {
        let first = firstFailure ?? now
        firstFailure = first
        landedAt = nil
        let left = Self.budget - (now - first)
        guard left > 0 else { return .giveUp }
        attempts += 1
        let delay = min(min(pow(2, Double(attempts - 1)), Self.longestDelay), left)
        return .reconnect(attempt: attempts, after: .milliseconds(Int((delay * 1000).rounded())))
    }

    /// The new stream is playing at `movie`.
    public mutating func landed(at movie: TimeInterval) {
        guard attempts > 0 else { return }
        landedAt = movie
    }

    /// The playhead moved to `movie`; a stream that has played for a while is a new start for the next failure.
    public mutating func playing(at movie: TimeInterval) {
        guard let landedAt, movie - landedAt >= Self.settledAfter else { return }
        reset()
    }

    /// The user asked again, or another item loads.
    public mutating func reset() {
        attempts = 0
        firstFailure = nil
        landedAt = nil
    }

    /// Whether a failure can be one of these: false for what the server or the file will answer the same
    /// next time. `status` is an HTTP status when the failure carries one.
    public static func isRetryable(status: Int?) -> Bool {
        guard let status else { return true }
        return ![401, 403, 404, 410].contains(status)
    }

    /// The same for AVPlayer's error: its domain and code, and the comment it logged.
    public static func isRetryable(domain: String?, code: Int, comment: String? = nil) -> Bool {
        if ConversionWatch.isNotFound(domain: domain, code: code, comment: comment) { return false }
        switch (domain, code) {
        // No permission, authentication required.
        case ("NSURLErrorDomain", -1102), ("NSURLErrorDomain", -1013), ("NSURLErrorDomain", -1012): return false
        // CoreMedia's HTTP 403 and 401.
        case ("CoreMediaErrorDomain", -12660), ("CoreMediaErrorDomain", -12661): return false
        // The file cannot be opened or decoded: a new try says the same.
        case ("AVFoundationErrorDomain", -11828), ("AVFoundationErrorDomain", -11821): return false
        default: break
        }
        guard let comment else { return true }
        for status in [401, 403, 410] where comment.localizedCaseInsensitiveContains("HTTP \(status)") { return false }
        return true
    }
}
