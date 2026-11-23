import Foundation

/// A rung of Auto quality (`AdaptiveQuality`): Original, one of the quality menu's presets, or, for a title
/// HomeLabber has measured, a bitrate at a size picked from its curve.
public enum AutoRung: Sendable, Hashable {
    case preset(VideoQuality)
    case mapped(StreamStep)

    public static let original = AutoRung.preset(.original)

    /// The preset to treat the rung as where only a preset is meant, such as whether the stream is converted at
    /// all. A mapped step counts as the smallest preset whose cap carries it, so never as Original.
    public var quality: VideoQuality {
        switch self {
        case .preset(let quality):
            return quality
        case .mapped(let step):
            let cap = step.target.maxVideoBitrateKbps
            return VideoQuality.allCases.filter { ($0.maxBitrateKbps ?? 0) >= cap }.min { $0.rawValue < $1.rawValue } ?? .mbps20
        }
    }

    /// "Original", "8 Mbps 1080p", "3.2 Mbps 720p".
    public var title: String {
        switch self {
        case .preset(let quality): quality.title
        case .mapped(let step): step.title
        }
    }

    /// The bitrate and size a mapped rung asks the server for, in place of its `quality`'s cap and frame
    /// (`RouteLimits.target`); nil for Original and the presets.
    public var target: DownloadTarget? {
        guard case .mapped(let step) = self else { return nil }
        return step.target
    }
}

extension AutoRung: CustomStringConvertible {
    /// For the diagnostic log: a preset's case name, or a mapped step's size and video bitrate.
    public var description: String {
        switch self {
        case .preset(let quality): "\(quality)"
        case .mapped(let step): "\(step.target.height)p@\(step.target.videoKbps)k"
        }
    }
}
