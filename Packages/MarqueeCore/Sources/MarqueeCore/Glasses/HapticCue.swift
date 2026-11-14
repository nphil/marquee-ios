import Foundation

/// The phone remote's vocabulary of touches. Each cue has its own shape (strength, sharpness, count and
/// length) so it can be told apart in the hand without looking at the phone.
public enum HapticCue: String, CaseIterable, Sendable {
    /// The focus moved one item: a light, crisp tick.
    case focusStep
    /// The focus met the end of a row or list: a dull thud that lasts.
    case edge
    /// An item was chosen: one firm, sharp click.
    case select
    /// Went back a page: two soft knocks, the second fainter.
    case back
    /// The playhead crossed a detent while scrubbing: the faintest bright tick.
    case scrubDetent
    /// Playback started or paused: two knocks, the second stronger.
    case playPause
    /// Something failed: three heavy dull knocks.
    case error
    /// The volume moved one step: a soft, round thump.
    case volumeStep
    /// The volume met silent or full: two firm thumps.
    case volumeLimit

    public struct Event: Sendable, Equatable, Hashable {
        /// Seconds from the start of the cue.
        public let time: TimeInterval
        /// From 0 to 1.
        public let intensity: Double
        /// From 0 (dull) to 1 (crisp).
        public let sharpness: Double
        /// Zero is a single tap; above zero a held buzz of that many seconds.
        public let duration: TimeInterval
    }

    public var events: [Event] {
        switch self {
        case .focusStep: [Self.tap(0, 0.45, 0.65)]
        case .edge: [Self.buzz(0, 0.8, 0.1, 0.1)]
        case .select: [Self.tap(0, 1, 0.9)]
        case .back: [Self.tap(0, 0.7, 0.3), Self.tap(0.08, 0.4, 0.3)]
        case .scrubDetent: [Self.tap(0, 0.3, 1)]
        case .playPause: [Self.tap(0, 0.55, 0.5), Self.tap(0.1, 0.95, 0.5)]
        case .error: [Self.tap(0, 1, 0.15), Self.tap(0.12, 1, 0.15), Self.tap(0.24, 1, 0.15)]
        case .volumeStep: [Self.tap(0, 0.5, 0.25)]
        case .volumeLimit: [Self.tap(0, 1, 0.25), Self.tap(0.07, 1, 0.25)]
        }
    }

    private static func tap(_ time: TimeInterval, _ intensity: Double, _ sharpness: Double) -> Event {
        Event(time: time, intensity: intensity, sharpness: sharpness, duration: 0)
    }

    private static func buzz(_ time: TimeInterval, _ intensity: Double, _ sharpness: Double, _ duration: TimeInterval) -> Event {
        Event(time: time, intensity: intensity, sharpness: sharpness, duration: duration)
    }
}
