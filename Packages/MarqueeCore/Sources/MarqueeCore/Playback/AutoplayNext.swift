import Foundation

/// What the player does at an episode's credits marker once Autoplay Next Episode is on.
public enum CreditsAutoplay: String, Codable, CaseIterable, Sendable {
    /// The Up Next card counts down, then plays the next episode.
    case countdown
    /// Binge mode: the next episode starts at the credits marker with no card.
    case skipInstantly

    public var title: String {
        switch self {
        case .countdown: "Countdown"
        case .skipInstantly: "Skip Credits Instantly"
        }
    }
}

/// The profile's autoplay rule: whether the next episode follows by itself, at the credits and at the end.
public struct AutoplayNext: Equatable, Sendable {
    public enum AtCredits: Equatable, Sendable {
        /// The Up Next card shows and waits to be tapped.
        case offer
        /// The Up Next card counts down this many seconds, then plays.
        case countdown(seconds: Int)
        /// The next episode starts now, with no card.
        case playNow
    }

    public var enabled: Bool
    public var credits: CreditsAutoplay
    /// Seconds of the Up Next countdown.
    public var delay: Int

    public init(enabled: Bool = true, credits: CreditsAutoplay = .countdown, delay: Int = 5) {
        self.enabled = enabled
        self.credits = credits
        self.delay = delay
    }

    /// Reads a profile saved before the toggle: a delay above 0 was Next Episode "After N s", 0 was Off.
    public init(legacyDelay: Int) {
        self.init(enabled: legacyDelay > 0, delay: legacyDelay > 0 ? legacyDelay : 5)
    }

    public var atCredits: AtCredits {
        guard enabled else { return .offer }
        return credits == .skipInstantly ? .playNow : .countdown(seconds: max(delay, 1))
    }

    /// An episode that reaches its end plays the next one when on, unless "Watch credits" was chosen: that
    /// stays on the finished screen.
    public func playsNextAtEnd(creditsWatched: Bool) -> Bool {
        enabled && !creditsWatched
    }
}
