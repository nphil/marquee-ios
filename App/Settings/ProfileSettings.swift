import Foundation
import MarqueeCore

/// One Plex Home profile's playback, audio and subtitle settings (behaviour spec §1, §3, §4) and its Home rows.
/// Decoding fills a missing or unreadable key with its default, so settings saved by an older build load.
struct ProfileSettings: Equatable, Sendable {
    /// Seconds for both skip directions.
    var skipInterval = 10
    /// Seconds before an intro skips itself; 0 skips only when asked.
    var introSkipDelay = 5
    /// Seconds of countdown at the credits before the next episode; 0 turns auto-next off.
    var nextEpisodeDelay = 5
    var directPlay = DirectPlayMode.auto
    var aspect = VideoAspect.fit
    /// Live TV reads an HDHomeRun tuner on the home network itself; off, every channel plays through Plex.
    var readsTunerDirectly = true
    /// Nil plays the file's default audio track.
    var audioLanguage: TrackLanguage?
    var subtitles = SubtitleSettings()
    /// Remembers the audio and subtitles picked for each show or movie, per profile and server.
    var remembersTracks = true
    var subtitleStyle = SubtitleStyle()
    var homeRows = HomeLayout()

    static let skipIntervals = [5, 10, 15, 30, 60]
    static let countdowns = [3, 5, 10, 15, 30]
}

extension ProfileSettings: Codable {
    enum CodingKeys: String, CodingKey {
        case skipInterval, introSkipDelay, nextEpisodeDelay, directPlay, aspect, readsTunerDirectly
        case audioLanguage, subtitles, remembersTracks, subtitleStyle, homeRows
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys) -> T? { try? c.decodeIfPresent(T.self, forKey: key) }
        self.init()
        skipInterval = value(.skipInterval) ?? skipInterval
        introSkipDelay = value(.introSkipDelay) ?? introSkipDelay
        nextEpisodeDelay = value(.nextEpisodeDelay) ?? nextEpisodeDelay
        directPlay = value(.directPlay) ?? directPlay
        aspect = value(.aspect) ?? aspect
        readsTunerDirectly = value(.readsTunerDirectly) ?? readsTunerDirectly
        audioLanguage = value(.audioLanguage)
        subtitles = value(.subtitles) ?? subtitles
        remembersTracks = value(.remembersTracks) ?? remembersTracks
        subtitleStyle = value(.subtitleStyle) ?? subtitleStyle
        homeRows = value(.homeRows) ?? homeRows
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

/// How subtitles look over the video (behaviour spec §3, "Subtitle look").
struct SubtitleStyle: Equatable, Sendable {
    var size = Size.medium
    var colour = Colour.white
    var edge = Edge.shadow
    /// A dark box behind the text.
    var hasBackground = false
    var isBold = false
    var position = Position.bottom

    enum Size: String, Codable, CaseIterable, Sendable {
        case small, medium, large, extraLarge

        var title: String {
            switch self {
            case .small: "Small"
            case .medium: "Medium"
            case .large: "Large"
            case .extraLarge: "Extra Large"
            }
        }

        /// Text height as a share of the picture's height.
        var heightFraction: Double {
            switch self {
            case .small: 0.045
            case .medium: 0.055
            case .large: 0.067
            case .extraLarge: 0.08
            }
        }
    }

    /// The colour of the text; the views map it onto the picture palette.
    enum Colour: String, Codable, CaseIterable, Sendable {
        case white, yellow, cyan

        var title: String {
            switch self {
            case .white: "White"
            case .yellow: "Yellow"
            case .cyan: "Cyan"
            }
        }
    }

    enum Edge: String, Codable, CaseIterable, Sendable {
        case none, outline, shadow

        var title: String {
            switch self {
            case .none: "None"
            case .outline: "Outline"
            case .shadow: "Drop Shadow"
            }
        }
    }

    enum Position: String, Codable, CaseIterable, Sendable {
        case bottom, top

        var title: String { self == .bottom ? "Bottom" : "Top" }
    }
}

extension SubtitleStyle: Codable {
    enum CodingKeys: String, CodingKey {
        case size, colour, edge, hasBackground, isBold, position
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys) -> T? { try? c.decodeIfPresent(T.self, forKey: key) }
        self.init()
        size = value(.size) ?? size
        colour = value(.colour) ?? colour
        edge = value(.edge) ?? edge
        hasBackground = value(.hasBackground) ?? hasBackground
        isBold = value(.isBold) ?? isBold
        position = value(.position) ?? position
    }
}
