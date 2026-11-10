import Foundation

/// What the player's first-start badge says about the stream that is about to play: the picture size, the
/// high dynamic range kind and the surround sound. Each part is nil when it is unknown or does not apply,
/// so a plain 1080p stereo file still shows its size and nothing is made up.
public struct FormatBadge: Sendable, Hashable {
    public enum Resolution: String, Sendable {
        case sd = "SD", p720 = "720p", p1080 = "1080p", p1440 = "1440p", uhd4K = "4K", uhd8K = "8K"
    }

    public enum Range: Sendable {
        case hdr10, hdr10Plus, hlg, dolbyVision

        public var name: String {
            switch self {
            case .hdr10: "HDR10"
            case .hdr10Plus: "HDR10+"
            case .hlg: "HLG"
            case .dolbyVision: "Dolby Vision"
            }
        }
    }

    public enum Sound: Sendable {
        case atmos, surround51, surround71

        public var name: String {
            switch self {
            case .atmos: "Dolby Atmos"
            case .surround51: "5.1"
            case .surround71: "7.1"
            }
        }
    }

    public var resolution: Resolution?
    public var range: Range?
    public var sound: Sound?

    public var isEmpty: Bool { resolution == nil && range == nil && sound == nil }

    /// "4K, Dolby Vision, Dolby Atmos", for VoiceOver.
    public var spoken: String {
        [resolution?.rawValue, range?.name, sound?.name].compactMap { $0 }.joined(separator: ", ")
    }

    /// The badge for what plays on `route`. A re-encode by the server shows the size it was encoded to and
    /// no range, since the server tone-maps; sound is claimed only where the audio is passed through.
    public static func make(video: PlexStream?, media: PlexMedia?, audio: PlexStream?, route: PlaybackRoute?) -> FormatBadge {
        var badge = FormatBadge()
        let reencodes = route?.reencodesVideo == true

        if let width = route?.videoResolution.flatMap(Self.width(of:)) ?? video?.width ?? media?.width {
            badge.resolution = resolution(width: width)
        } else if let height = video?.height ?? media?.height {
            badge.resolution = resolution(width: Int((Double(height) * 16 / 9).rounded()))
        }

        if let video, !reencodes {
            let title = [video.displayTitle, video.extendedDisplayTitle].compactMap { $0 }.joined(separator: " ").lowercased()
            let baseLayerOnly = route?.reasons.contains(.dolbyVisionBaseLayer) == true
            if video.dolbyVision != nil, !baseLayerOnly {
                badge.range = .dolbyVision
            } else if video.colorTrc == "smpte2084" {
                badge.range = title.contains("hdr10+") ? .hdr10Plus : .hdr10
            } else if video.colorTrc == "arib-std-b67" {
                badge.range = .hlg
            }
        }

        if let audio, route?.kind != .serverTranscode, route?.convertsAudio != true {
            let title = [audio.displayTitle, audio.extendedDisplayTitle, audio.title].compactMap { $0 }.joined(separator: " ").lowercased()
            let channels = audio.channels ?? media?.audioChannels ?? 0
            if title.contains("atmos") {
                badge.sound = .atmos
            } else if channels >= 8 {
                badge.sound = .surround71
            } else if channels >= 6 {
                badge.sound = .surround51
            }
        }
        return badge
    }

    /// Width bands, not heights: a 2.39:1 film in a 1080p file is 1920 × 800.
    static func resolution(width: Int) -> Resolution {
        switch width {
        case 7000...: .uhd8K
        case 3200...: .uhd4K
        case 2400...: .p1440
        case 1800...: .p1080
        case 1200...: .p720
        default: .sd
        }
    }

    /// "1280x720" → 1280.
    static func width(of size: String) -> Int? {
        size.split(separator: "x").first.flatMap { Int($0) }
    }
}
