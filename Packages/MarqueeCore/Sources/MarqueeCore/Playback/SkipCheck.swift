import Foundation

/// Confirms that a skip past the intro landed. A seek can be refused or lost, for example when the stream
/// is replaced while the seek is on its way, and the intro then plays on with its offer already gone. Once
/// playback has run `settle` seconds after the skip with no seek or restart pending, a playhead still
/// short of the intro's end means the skip missed: it is tried once more, and a second miss gives up so
/// the Skip Intro offer can come back.
public struct SkipCheck: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        /// Too early to tell, or a seek is still on its way.
        case waiting
        /// The playhead reached the intro's end.
        case landed
        /// Missed once: seek to the intro's end again.
        case retry
        /// Missed twice: stop trying and offer the skip again.
        case missed
    }

    /// Seconds of playback after the skip before the playhead is judged.
    public static let settle: TimeInterval = 3
    /// How far short of the intro's end still counts as there.
    public static let tolerance: TimeInterval = 1

    /// The intro's end, where the skip went.
    public let target: TimeInterval
    public private(set) var retried = false
    /// Seconds played since the skip, or since the retry.
    public private(set) var played: TimeInterval = 0

    public init(target: TimeInterval) {
        self.target = target
    }

    /// - Parameters:
    ///   - playhead: Where playback is now.
    ///   - advanced: Seconds the playhead moved forward since the last check while playing.
    ///   - pending: A seek, a landing or a restart is still on its way; the count starts again after it.
    public mutating func check(playhead: TimeInterval, advanced: TimeInterval, pending: Bool) -> Verdict {
        if playhead >= target - Self.tolerance { return .landed }
        guard !pending else {
            played = 0
            return .waiting
        }
        played += max(0, advanced)
        guard played >= Self.settle else { return .waiting }
        guard retried else {
            retried = true
            played = 0
            return .retry
        }
        return .missed
    }
}
