import Foundation

/// What a download keeps: the server's file as it is, or the server's conversion at one of the
/// streaming quality presets.
public enum DownloadQuality: Hashable, Sendable, Codable {
    case original
    case converted(VideoQuality)

    /// Original, then every preset from the highest.
    public static let choices: [DownloadQuality] = [.original]
        + VideoQuality.allCases.filter { $0.maxBitrateKbps != nil && $0.frame != nil }.map { .converted($0) }

    /// "Original", "8 Mbps 1080p".
    public var title: String {
        switch self {
        case .original: VideoQuality.original.title
        case .converted(let preset): preset.title
        }
    }

    /// About how many bytes the download takes: the version's files for Original, the target's video
    /// bitrate plus the audio over the running time for a conversion. Nil when the server lists neither.
    public func estimatedBytes(media: PlexMedia, target: DownloadTarget?) -> Int64? {
        switch self {
        case .original:
            let sizes = media.parts.compactMap(\.size)
            return sizes.isEmpty ? nil : Int64(sizes.reduce(0, +))
        case .converted:
            guard let target, media.duration > 0 else { return nil }
            let kbps = Int64(target.maxVideoBitrateKbps + DownloadTarget.audioKbps)
            return kbps * 1000 / 8 * Int64(media.duration) / 1000
        }
    }
}

/// What a converted download asks the server for.
public struct DownloadTarget: Hashable, Sendable, Codable {
    /// The server converts the audio to stereo AAC at about this rate.
    public static let audioKbps = 192

    public var maxVideoBitrateKbps: Int
    public var width: Int
    public var height: Int

    /// "1280x720".
    public var videoResolution: String { "\(width)x\(height)" }

    public init(maxVideoBitrateKbps: Int, width: Int, height: Int) {
        self.maxVideoBitrateKbps = maxVideoBitrateKbps
        self.width = width
        self.height = height
    }
}

/// Turns a preset into what the server converts one title to. `PresetTarget` takes the preset as it
/// is. A per-title picker conforms in its place, for example one that measures a title's VMAF at a few
/// bitrates and keeps the lowest that holds a score; the download's quality stays the preset it was
/// asked for.
public protocol DownloadTargetPicking: Sendable {
    func target(for preset: VideoQuality, media: PlexMedia) async -> DownloadTarget
}

public struct PresetTarget: DownloadTargetPicking {
    public init() {}

    public func target(for preset: VideoQuality, media: PlexMedia) async -> DownloadTarget {
        Self.target(for: preset, media: media)
    }

    /// The preset's bitrate and frame, never above the source's own: the server does not enlarge a
    /// picture, and a bitrate above the file's only makes a bigger file of the same picture.
    public static func target(for preset: VideoQuality, media: PlexMedia) -> DownloadTarget {
        let frame = preset.frame ?? (1920, 1080)
        var kbps = preset.maxBitrateKbps ?? VideoQuality.mbps8.rawValue
        if let source = media.bitrate, source > 0 { kbps = min(kbps, source) }
        guard let width = media.width, let height = media.height, width > 0, height > 0,
              width <= frame.width, height <= frame.height else {
            return DownloadTarget(maxVideoBitrateKbps: kbps, width: frame.width, height: frame.height)
        }
        return DownloadTarget(maxVideoBitrateKbps: kbps, width: width, height: height)
    }
}
