import Foundation

/// A converted download's quality. Each tier aims for a VMAF score against the original, measured at
/// the picture size the tier is made at.
public enum DownloadTier: String, Hashable, Sendable, Codable, CaseIterable {
    case high, medium, low

    /// The VMAF score aimed for.
    public var vmaf: Double {
        switch self {
        case .high: 95
        case .medium: 90
        case .low: 85
        }
    }

    public var title: String {
        switch self {
        case .high: "High"
        case .medium: "Medium"
        case .low: "Low"
        }
    }
}

/// What a download keeps: the server's file as it is, or the server's conversion at a tier.
public enum DownloadQuality: Hashable, Sendable, Codable {
    case original
    case tier(DownloadTier)

    /// Original, then the tiers from the highest.
    public static let choices: [DownloadQuality] = [.original] + DownloadTier.allCases.map(DownloadQuality.tier)

    /// "Original", "Medium".
    public var title: String {
        switch self {
        case .original: "Original"
        case .tier(let tier): tier.title
        }
    }

    private enum CodingKeys: String, CodingKey { case original, tier, converted }
    private enum ValueKeys: String, CodingKey { case value = "_0" }

    /// Downloads and settings saved before the tiers named a streaming preset's bitrate (`converted`);
    /// it becomes the tier of about that size.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if values.contains(.tier) {
            self = .tier(try values.nestedContainer(keyedBy: ValueKeys.self, forKey: .tier).decode(DownloadTier.self, forKey: .value))
        } else if values.contains(.converted) {
            let kbps = try values.nestedContainer(keyedBy: ValueKeys.self, forKey: .converted).decode(Int.self, forKey: .value)
            self = .tier(kbps >= 8_000 ? .high : kbps >= 4_000 ? .medium : .low)
        } else {
            self = .original
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .original:
            _ = values.nestedContainer(keyedBy: ValueKeys.self, forKey: .original)
        case .tier(let tier):
            var nested = values.nestedContainer(keyedBy: ValueKeys.self, forKey: .tier)
            try nested.encode(tier, forKey: .value)
        }
    }
}

/// What a converted download asks the server for: a video bitrate at a picture size.
public struct DownloadTarget: Hashable, Sendable, Codable {
    /// The server converts the audio to stereo AAC at about this rate.
    public static let audioKbps = 192

    /// The video bitrate wanted, in kbit/s.
    public var videoKbps: Int
    /// The `maxVideoBitrate` sent for it: the server's encoder makes less than the cap allows, and picks
    /// the picture size from the cap, so the cap is found by asking the server's decisions.
    public var maxVideoBitrateKbps: Int
    /// The frame the picture is fitted into: 854x480, 1280x720, 1920x1080 or 3840x2160.
    public var width: Int
    public var height: Int
    /// "h264", or "hevc" for the 4K choice.
    public var codec: String

    /// `height` is a size class: 480, 720, 1080 or 2160.
    public init(videoKbps: Int, height: Int, codec: String = "h264") {
        self.videoKbps = videoKbps
        self.height = height
        width = PictureClass.width(of: height)
        self.codec = codec
        maxVideoBitrateKbps = TranscodeLadder.firstCap(videoKbps: videoKbps, height: height)
    }

    /// "1280x720".
    public var videoResolution: String { "\(width)x\(height)" }

    /// About how many bytes the video and audio come to over `duration` milliseconds.
    public func bytes(duration: Int) -> Int64 {
        Int64(videoKbps + Self.audioKbps) * 1000 / 8 * Int64(max(0, duration)) / 1000
    }

    private enum CodingKeys: String, CodingKey { case videoKbps, maxVideoBitrateKbps, width, height, codec }

    /// Conversions saved before the tiers kept only the cap and the frame.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        maxVideoBitrateKbps = try values.decode(Int.self, forKey: .maxVideoBitrateKbps)
        videoKbps = try values.decodeIfPresent(Int.self, forKey: .videoKbps) ?? maxVideoBitrateKbps
        width = try values.decode(Int.self, forKey: .width)
        height = try values.decode(Int.self, forKey: .height)
        codec = try values.decodeIfPresent(String.self, forKey: .codec) ?? "h264"
    }
}

/// Plex's picture-size classes, as its `videoResolution` names them.
public enum PictureClass {
    /// Smallest first.
    public static let heights = [480, 720, 1080, 2160]

    /// The class a version is in: Plex's `videoResolution`, else the width in `FormatBadge`'s bands
    /// (a 1920x800 scope film is 1080), else the height.
    public static func of(_ media: PlexMedia) -> Int? {
        switch media.videoResolution?.lowercased() {
        case "4k", "2160", "2160p": return 2160
        case "1080", "1080p": return 1080
        case "720", "720p": return 720
        case "480", "576", "sd", "480p", "576p": return 480
        default: break
        }
        let video = media.parts.first?.videoStream
        if let width = media.width ?? video?.width, width > 0 {
            return width >= 3200 ? 2160 : width >= 1800 ? 1080 : width >= 1200 ? 720 : 480
        }
        if let height = media.height ?? video?.height, height > 0 {
            return height >= 1500 ? 2160 : height >= 900 ? 1080 : height >= 600 ? 720 : 480
        }
        return nil
    }

    public static func width(of height: Int) -> Int {
        switch height {
        case 2160: 3840
        case 1080: 1920
        case 720: 1280
        case 480: 854
        default: height * 16 / 9
        }
    }
}
