import Foundation
import MarqueeCore

/// One Plex Home profile's playback, audio and subtitle settings (behaviour spec §1, §3, §4) and its Home rows.
/// Decoding fills a missing or unreadable key with its default, so settings saved by an older build load.
struct ProfileSettings: Equatable, Sendable {
    /// Seconds for both skip directions.
    var skipInterval = 10
    /// Whether taps after a skip keep skipping, or only a double-tap skips.
    var skipTaps = SkipTapMode.doubleTap
    /// Seconds before an intro skips itself; 0 skips only when asked.
    var introSkipDelay = 5
    /// Seconds of countdown at the credits before the next episode; 0 turns auto-next off.
    var nextEpisodeDelay = 5
    var directPlay = DirectPlayMode.auto
    var aspect = VideoAspect.fit
    /// How the screen turns while a player is open.
    var videoOrientation = VideoOrientation.followDevice
    /// Live TV reads an HDHomeRun tuner on the home network itself; off, every channel plays through Plex.
    var readsTunerDirectly = true
    /// Nil plays the file's default audio track.
    var audioLanguage: TrackLanguage?
    var subtitles = SubtitleSettings()
    /// Remembers the audio and subtitles picked for each show or movie, per profile and server.
    var remembersTracks = true
    var subtitleStyle = SubtitleLook()
    var homeRows = HomeLayout()
    var posterLabels = PosterLabels()
    /// The default quality: Auto, or a fixed one; picking one in the player's More menu saves it too.
    var quality = QualitySetting.auto
    /// Boost dialog and Normalize loudness, from the player's Audio menu.
    var audioEnhancements: AudioEnhancements = []
    /// Libraries switched off under Favorite Libraries, by `HomeLayout.libraryID`. Empty shows every library,
    /// and one the server adds later shows until switched off.
    var hiddenLibraries: Set<String> = []
    /// Plays a title's trailer in its page's hero after a moment (behaviour spec: Play trailers
    /// automatically, on by default).
    var playsTrailers = true
    /// Plays a show's theme tune on its pages (DESIGN §8.3), on by default.
    var playsThemeMusic = true
    /// The theme tune's volume, 0 to 1.
    var themeMusicVolume = 0.5

    static let skipIntervals = [5, 10, 15, 30, 60]
    static let countdowns = [3, 5, 10, 15, 30]
}

extension ProfileSettings: Codable {
    enum CodingKeys: String, CodingKey {
        case skipInterval, skipTaps, introSkipDelay, nextEpisodeDelay, directPlay, aspect, videoOrientation, readsTunerDirectly
        case audioLanguage, subtitles, remembersTracks, subtitleStyle, homeRows
        case posterLabels, audioEnhancements, hiddenLibraries, playsTrailers, playsThemeMusic, themeMusicVolume
        /// "quality" held a fixed quality before Auto existed (`LegacyKeys`).
        case quality = "qualitySetting"
    }

    private enum LegacyKeys: String, CodingKey {
        case quality
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys) -> T? { try? c.decodeIfPresent(T.self, forKey: key) }
        self.init()
        skipInterval = value(.skipInterval) ?? skipInterval
        skipTaps = value(.skipTaps) ?? skipTaps
        introSkipDelay = value(.introSkipDelay) ?? introSkipDelay
        nextEpisodeDelay = value(.nextEpisodeDelay) ?? nextEpisodeDelay
        directPlay = value(.directPlay) ?? directPlay
        aspect = value(.aspect) ?? aspect
        videoOrientation = value(.videoOrientation) ?? videoOrientation
        readsTunerDirectly = value(.readsTunerDirectly) ?? readsTunerDirectly
        audioLanguage = value(.audioLanguage)
        subtitles = value(.subtitles) ?? subtitles
        remembersTracks = value(.remembersTracks) ?? remembersTracks
        subtitleStyle = value(.subtitleStyle) ?? subtitleStyle
        homeRows = value(.homeRows) ?? homeRows
        posterLabels = value(.posterLabels) ?? posterLabels
        let legacy = try? decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent(VideoQuality.self, forKey: .quality)
        quality = value(.quality) ?? QualitySetting.saved(legacy: legacy)
        audioEnhancements = value(.audioEnhancements) ?? audioEnhancements
        hiddenLibraries = value(.hiddenLibraries) ?? hiddenLibraries
        playsTrailers = value(.playsTrailers) ?? playsTrailers
        playsThemeMusic = value(.playsThemeMusic) ?? playsThemeMusic
        themeMusicVolume = value(.themeMusicVolume) ?? themeMusicVolume
    }
}

/// Behaviour spec §4: Force plays every file as it is, with no fallback, so choosing it asks first.
enum DirectPlayMode: String, Codable, CaseIterable, Sendable {
    case auto, disabled, force

    var title: String {
        switch self {
        case .auto: "Auto"
        case .disabled: "Disabled"
        case .force: "Force"
        }
    }
}

enum VideoAspect: String, Codable, CaseIterable, Sendable {
    case fit, fill, original, zoom, stretch

    var title: String {
        switch self {
        case .fit: "Fit"
        case .fill: "Fill"
        case .original: "Original Size"
        case .zoom: "Zoom"
        case .stretch: "Stretch"
        }
    }
}
