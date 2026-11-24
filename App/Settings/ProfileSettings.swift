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
    /// Autoplay Next Episode: the next episode follows by itself, at the credits and at the end.
    var autoplaysNext = true
    /// What autoplay does at a credits marker.
    var creditsAutoplay = CreditsAutoplay.countdown
    /// Seconds of the Up Next countdown at the credits (always above 0; Off is `autoplaysNext`).
    var nextEpisodeDelay = 5
    var directPlay = DirectPlayMode.auto
    var aspect = VideoAspect.fit
    /// How the screen turns while a player is open.
    var videoOrientation = VideoOrientation.followDevice
    /// Live TV reads an HDHomeRun tuner on the home network itself; off, every channel plays through Plex.
    var readsTunerDirectly = true
    /// Interlaced channels play the original broadcast (about 60 pictures a second) instead of the tuner's 30.
    var prefersSmoothMotion = true
    var subtitleStyle = SubtitleLook()
    /// Reads picture subtitles (PGS, DVD) into a text rendition on the phone for Picture in Picture and AirPlay
    /// (`RemuxOptions.bitmapSubtitleText`); off by default, since the recognised text can contain mistakes.
    var textFromPictureSubtitles = false
    /// Sharpening and upscaling of standard video on the phone (VideoEngine's `PictureEnhancer`); off by default.
    var pictureEnhance = PictureEnhance()
    var homeRows = HomeLayout()
    var posterLabels = PosterLabels()
    /// The default quality: Auto, or a fixed one; picking one in the player's More menu saves it too.
    var quality = QualitySetting.auto
    /// Caps video at `PlayerModel.savedDataCap` on mobile data, a personal hotspot or Low Data Mode; off by default.
    var savesData = false
    /// Boost dialog and Normalize loudness, from the player's Audio menu.
    var audioEnhancements: AudioEnhancements = []
    /// Libraries switched off under Favorite Libraries, by `HomeLayout.libraryID`. Empty shows every library,
    /// and one the server adds later shows until switched off.
    var hiddenLibraries: Set<String> = []
    /// Next-episode cards taken off Continue Watching, which stay off until their show is viewed again.
    var rewatchDismissed = RewatchDismissals()
    /// Plays a title's trailer in its page's hero after a moment (behaviour spec: Play trailers
    /// automatically, on by default).
    var playsTrailers = true
    /// Plays a show's theme tune on its pages (DESIGN §8.3), on by default.
    var playsThemeMusic = true
    /// The theme tune's volume, 0 to 1.
    var themeMusicVolume = 0.5

    var autoplay: AutoplayNext {
        AutoplayNext(enabled: autoplaysNext, credits: creditsAutoplay, delay: nextEpisodeDelay)
    }

    static let skipIntervals = [5, 10, 15, 30, 60]
    static let countdowns = [3, 5, 10, 15, 30]
}

extension ProfileSettings: Codable {
    enum CodingKeys: String, CodingKey {
        case skipInterval, skipTaps, introSkipDelay, nextEpisodeDelay, autoplaysNext, creditsAutoplay, directPlay, aspect, videoOrientation, readsTunerDirectly, prefersSmoothMotion
        case subtitleStyle, textFromPictureSubtitles, pictureEnhance, homeRows
        case posterLabels, audioEnhancements, hiddenLibraries, rewatchDismissed, playsTrailers, playsThemeMusic, themeMusicVolume, savesData
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
        // Saved before the toggle, the delay alone said it: 0 was Off.
        let savedDelay: Int? = value(.nextEpisodeDelay)
        let migrated = savedDelay.map(AutoplayNext.init(legacyDelay:)) ?? AutoplayNext()
        nextEpisodeDelay = migrated.delay
        autoplaysNext = value(.autoplaysNext) ?? migrated.enabled
        creditsAutoplay = value(.creditsAutoplay) ?? creditsAutoplay
        directPlay = value(.directPlay) ?? directPlay
        aspect = value(.aspect) ?? aspect
        videoOrientation = value(.videoOrientation) ?? videoOrientation
        readsTunerDirectly = value(.readsTunerDirectly) ?? readsTunerDirectly
        prefersSmoothMotion = value(.prefersSmoothMotion) ?? prefersSmoothMotion
        subtitleStyle = value(.subtitleStyle) ?? subtitleStyle
        homeRows = value(.homeRows) ?? homeRows
        posterLabels = value(.posterLabels) ?? posterLabels
        let legacy = try? decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent(VideoQuality.self, forKey: .quality)
        quality = value(.quality) ?? QualitySetting.saved(legacy: legacy)
        savesData = value(.savesData) ?? savesData
        textFromPictureSubtitles = value(.textFromPictureSubtitles) ?? textFromPictureSubtitles
        pictureEnhance = value(.pictureEnhance) ?? pictureEnhance
        audioEnhancements = value(.audioEnhancements) ?? audioEnhancements
        hiddenLibraries = value(.hiddenLibraries) ?? hiddenLibraries
        rewatchDismissed = value(.rewatchDismissed) ?? rewatchDismissed
        playsTrailers = value(.playsTrailers) ?? playsTrailers
        playsThemeMusic = value(.playsThemeMusic) ?? playsThemeMusic
        themeMusicVolume = value(.themeMusicVolume) ?? themeMusicVolume
    }
}

/// Enhance picture: how the phone upscales standard video, and how hard it sharpens and debands it. Sharpen and
/// deband apply only while the upscaler is not Off.
struct PictureEnhance: Equatable, Codable, Sendable {
    enum Upscaler: String, Codable, CaseIterable, Sendable {
        case off, automatic, lineArt

        var title: String {
            switch self {
            case .off: "Off"
            case .automatic: "Automatic"
            case .lineArt: "Line art"
            }
        }
    }

    var upscaler = Upscaler.off
    var sharpen = 0.3
    var deband = 0.3
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
