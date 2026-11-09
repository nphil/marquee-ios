import Foundation

/// When a remux's playlist goes to AVPlayer. The playlist grows while AVPlayer reads it, and AVPlayer
/// joins such a playlist three target durations (10 s each) before its end; given fewer, it waits for
/// a later re-read, which held starts on the iPhone about 5 s after the first segment. Handed over once
/// `lead` seconds are ready past the landing point, AVPlayer can start from its first read. A slow source
/// never holds the playlist back longer than `cap`.
public struct RemuxHandOff: Sendable {
    public enum Reason: String, Sendable {
        /// `lead` seconds are ready past the landing point.
        case lead
        /// `cap` ran out first.
        case cap
        /// Production waits for the playhead: as far ahead as the remux goes.
        case paced
        /// The whole file is remuxed.
        case end
    }

    public enum Decision: Equatable, Sendable {
        /// Not yet; the share of the lead in hand, nil until the run's timeline is known.
        case wait(Double?)
        case handOver(Reason)
    }

    public static let lead: TimeInterval = 32
    public static let cap: Duration = .milliseconds(1500)

    /// Where playback lands, on the movie's timeline.
    public let landing: TimeInterval

    public init(landing: TimeInterval) {
        self.landing = landing
    }

    /// - Parameters:
    ///   - origin: The run's start on the movie's timeline, once known.
    ///   - mediaSeconds: Media remuxed so far, on the run's timeline.
    ///   - elapsed: Time since the playlist could have gone to the player.
    public func decide(
        origin: TimeInterval?, mediaSeconds: TimeInterval, isPaced: Bool, finished: Bool, elapsed: Duration
    ) -> Decision {
        if finished { return .handOver(.end) }
        if isPaced { return .handOver(.paced) }
        var share: Double?
        if let origin {
            let needed = max(0, landing - origin) + Self.lead
            if mediaSeconds >= needed { return .handOver(.lead) }
            share = max(0, mediaSeconds) / needed
        }
        if elapsed >= Self.cap { return .handOver(.cap) }
        return .wait(share)
    }
}
