import Foundation

/// The hero trailer on a title's page: it starts after a short dwell, with sound, when the setting is on
/// and nothing about the phone argues against it. The TV plays after 2 s of dwell with no mute control and
/// writes no watch state; the phone adds the conditions of a battery and a metered link.
public enum TrailerAutoplay {
    /// How long a page stays in view before its trailer starts.
    public static let dwell: Duration = .seconds(2)

    /// What the phone is doing at this moment.
    public struct Conditions: Sendable, Equatable {
        /// The profile's "Play trailers automatically" setting.
        public var enabled: Bool
        public var lowPowerMode: Bool
        public var reduceMotion: Bool
        /// The link is cellular, a personal hotspot or in Low Data Mode.
        public var metered: Bool
        public var appActive: Bool
        /// The hero is on screen: the page is shown, not covered, and not scrolled past it.
        public var heroVisible: Bool
        /// The full-screen player or Picture in Picture holds the audio.
        public var playerOpen: Bool
        /// Music, a podcast or a call from another app is playing.
        public var otherAudioPlaying: Bool

        public init(
            enabled: Bool = true, lowPowerMode: Bool = false, reduceMotion: Bool = false, metered: Bool = false,
            appActive: Bool = true, heroVisible: Bool = true, playerOpen: Bool = false, otherAudioPlaying: Bool = false
        ) {
            self.enabled = enabled
            self.lowPowerMode = lowPowerMode
            self.reduceMotion = reduceMotion
            self.metered = metered
            self.appActive = appActive
            self.heroVisible = heroVisible
            self.playerOpen = playerOpen
            self.otherAudioPlaying = otherAudioPlaying
        }
    }

    public enum Verdict: Sendable, Equatable {
        /// Play it; muted when other audio is already playing, so the trailer never talks over it.
        case play(muted: Bool)
        case hold
    }

    public static func decide(_ conditions: Conditions) -> Verdict {
        let c = conditions
        guard c.enabled, !c.lowPowerMode, !c.reduceMotion, !c.metered, c.appActive, c.heroVisible, !c.playerOpen
        else { return .hold }
        return .play(muted: c.otherAudioPlaying)
    }

    /// The file to preview: the first of the trailer's versions the phone plays untouched. A preview never
    /// remuxes or asks the server to transcode, which would cost more than a still image is worth.
    public static func directPart(of media: [PlexMedia], capabilities: DeviceCapabilities) -> PlexPart? {
        for version in media {
            for part in version.parts where !part.key.isEmpty {
                let tracks = MediaTracks(part: part)
                let route = PlaybackRouteDecider.decide(
                    media: version, part: part, tracks: tracks, audio: tracks.audio.first,
                    subtitle: SubtitleDecision(track: nil, source: .setting), capabilities: capabilities
                )
                if route.kind == .directPlay, !route.convertsAudio { return part }
            }
        }
        return nil
    }
}
