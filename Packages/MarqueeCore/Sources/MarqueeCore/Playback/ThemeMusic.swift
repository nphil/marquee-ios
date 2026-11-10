import Foundation

/// Theme music on a show's pages (DESIGN §8.3): the show's theme tune plays while its page is on screen
/// and nothing else holds the sound.
public enum ThemeMusic {
    /// The tune a title's page plays: a show's own, and on a season's page its show's.
    public static func key(for item: PlexMetadata) -> String? {
        let key = switch item.type {
        case .show: item.theme
        case .season: item.parentTheme
        default: String?.none
        }
        return key?.isEmpty == false ? key : nil
    }

    /// What the phone is doing at this moment.
    public struct Conditions: Sendable, Equatable {
        /// The profile's "Play Theme Music" setting.
        public var enabled: Bool
        public var appActive: Bool
        /// The page is shown, not covered by another page.
        public var pageVisible: Bool
        /// The full-screen player or Picture in Picture holds the audio.
        public var playerOpen: Bool
        /// Music, a podcast or a call from another app is playing.
        public var otherAudioPlaying: Bool
        /// The page's trailer is playing with sound.
        public var trailerSounding: Bool

        public init(
            enabled: Bool = true, appActive: Bool = true, pageVisible: Bool = true, playerOpen: Bool = false,
            otherAudioPlaying: Bool = false, trailerSounding: Bool = false
        ) {
            self.enabled = enabled
            self.appActive = appActive
            self.pageVisible = pageVisible
            self.playerOpen = playerOpen
            self.otherAudioPlaying = otherAudioPlaying
            self.trailerSounding = trailerSounding
        }
    }

    /// Unlike a trailer, which plays muted over other audio, the tune waits for it to stop. A trailer that
    /// started first keeps the sound; one that starts while the tune plays is muted (`TrailerAutoplay`).
    public static func plays(_ conditions: Conditions) -> Bool {
        let c = conditions
        return c.enabled && c.appActive && c.pageVisible && !c.playerOpen && !c.otherAudioPlaying && !c.trailerSounding
    }
}

/// How loud the theme tune is over time. Its gain moves at a steady pace towards full over `fadeIn` or
/// towards silence over `fadeOut`, from wherever it is, so a fade reversed midway carries on without a
/// jump. The volume is the setting times the gain squared, which is heard as an even fade.
public struct ThemeFade: Sendable, Equatable {
    public static let fadeIn: TimeInterval = 1.5
    public static let fadeOut: TimeInterval = 1

    /// 0 is silent, 1 full.
    public private(set) var gain: Double = 0
    /// Heading for full; otherwise for silence.
    public var rising = false

    public init() {}

    public var isSettled: Bool { gain == (rising ? 1 : 0) }

    public mutating func advance(by seconds: TimeInterval) {
        guard seconds > 0 else { return }
        gain = rising ? min(1, gain + seconds / Self.fadeIn) : max(0, gain - seconds / Self.fadeOut)
    }

    /// The player's volume at `level`, the volume setting from 0 to 1.
    public func volume(level: Double) -> Float {
        Float(min(max(level, 0), 1) * gain * gain)
    }
}
