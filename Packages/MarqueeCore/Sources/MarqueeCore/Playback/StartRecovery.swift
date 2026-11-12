import Foundation

/// Bounds a server stream's start and decides what follows one that failed. The steps before the player
/// have timeouts of their own: the address probe, the transcode decision and the other requests. The
/// player's wait for the stream has none, so a stream asked for that never becomes ready counts as failed
/// after `readyDeadline`. A failed start is tried twice more, each time on a new session and with the
/// server's addresses probed again; then the player shows the failure with Retry.
public struct StartRecovery: Sendable, Equatable {
    public enum Step: Sendable, Equatable {
        /// A new session after this wait.
        case retry(after: Duration)
        case giveUp
    }

    /// From the stream going to the player to it being ready to play.
    public static let readyDeadline: Duration = .seconds(30)
    static let delays: [Duration] = [.seconds(2), .seconds(5)]

    /// Failed starts in a row.
    public private(set) var failures = 0

    public init() {}

    public mutating func failed() -> Step {
        failures += 1
        return failures <= Self.delays.count ? .retry(after: Self.delays[failures - 1]) : .giveUp
    }

    /// The stream plays, or the user asked again: the count starts over.
    public mutating func reset() {
        failures = 0
    }
}
