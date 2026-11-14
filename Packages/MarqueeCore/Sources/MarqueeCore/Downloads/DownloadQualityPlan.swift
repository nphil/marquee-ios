import Foundation

/// The Download menu's choices for one version of a title: Original, then High, Medium and Low as the
/// server converts them, each with its size. A tier's bitrate and size come from HomeLabber's
/// measured VMAF scores when it has the title, else from an estimate made here. On a phone that
/// decodes HEVC, a 4K title adds High at 4K, always estimated: HomeLabber scores H.264 only.
///
/// A conversion is never asked for above the original's video bitrate. A tier that would be is
/// Original instead when the phone plays the original offline, and is capped at its bitrate when not.
public struct DownloadQualityPlan: Sendable, Hashable {
    public struct Option: Sendable, Hashable, Identifiable {
        public enum Basis: Sendable, Hashable {
            case original
            /// From HomeLabber's VMAF score of the title at this bitrate.
            case measured(vmaf: Double)
            case estimated
        }

        public var quality: DownloadQuality
        /// What the server converts to; nil for Original.
        public var target: DownloadTarget?
        public var basis: Basis
        /// About how large the download comes to; nil when the server lists no size or running time.
        public var bytes: Int64?
        /// The picture's size as the badges name it, such as "720p"; nil when the server does not say.
        public var resolution: String?

        public var id: String {
            target.map { "\(quality.title.lowercased())-\($0.height)" } ?? "original"
        }
    }

    /// Original first, then the conversions from the largest. A tier that comes to Original or to the
    /// tier above it is left out, since the choice above holds it.
    public private(set) var options: [Option]
    private var tiers: [DownloadTier: Option]

    /// What a download at a default quality takes: Original, or the tier's choice, which may be
    /// Original or the tier above.
    public func option(for quality: DownloadQuality) -> Option? {
        switch quality {
        case .original: options.first
        case .tier(let tier): tiers[tier]
        }
    }

    /// - Parameters:
    ///   - animated: The title, or an episode's show, is animation (`isAnimated(genres:)`).
    ///   - hevc: The phone decodes HEVC, which the 4K choice needs.
    ///   - originalPlays: The phone plays the original offline.
    ///   - map: HomeLabber's scores for the title; ignored when they are for another version.
    public init(media: PlexMedia, animated: Bool, hevc: Bool, originalPlays: Bool, map: QualityMapEntry?) {
        let source = Source(media: media, fallbackFPS: map?.fps)
        let measured = map?.mediaID == String(media.id) ? map : nil
        let factor = Self.factor(source, animated: animated)
        let sizes = media.parts.compactMap(\.size)
        let frame = DownloadRecord.Frame(media: media, target: nil)
        let original = Option(
            quality: .original, target: nil, basis: .original, bytes: sizes.isEmpty ? nil : Int64(sizes.reduce(0, +)),
            resolution: frame.map { FormatBadge.resolution(width: $0.width).rawValue }
        )
        func option(_ quality: DownloadQuality, _ target: DownloadTarget, _ basis: Option.Basis) -> Option? {
            guard let target = Self.capped(target, source: source, originalPlays: originalPlays) else { return nil }
            return Option(
                quality: quality, target: target, basis: basis, bytes: media.duration > 0 ? target.bytes(duration: media.duration) : nil,
                resolution: FormatBadge.resolution(width: target.width).rawValue
            )
        }

        var options = [original]
        if source.height >= 2160, hevc {
            let kbps = max(TranscodeLadder.floor(height: 2160), TranscodeLadder.roundUp(Int((Self.uhdNeed * factor).rounded())))
            if let uhd = option(.tier(.high), DownloadTarget(videoKbps: kbps, height: 2160, codec: "hevc"), .estimated) {
                options.append(uhd)
            }
        }
        var tiers: [DownloadTier: Option] = [:]
        var above: Option?
        for tier in DownloadTier.allCases {
            let found: Option?
            if let point = measured?.tiers[tier] {
                let height = PictureClass.heights.last { $0 <= min(point.height, source.height) } ?? 480
                found = option(.tier(tier), DownloadTarget(videoKbps: point.kbps, height: height), .measured(vmaf: point.vmaf))
            } else {
                found = option(.tier(tier), Self.estimate(tier, source: source, factor: factor), .estimated)
            }
            guard let found else {
                tiers[tier] = original
                continue
            }
            // A lower tier that costs no less than the one above is the one above.
            if let above, let higher = above.target, let target = found.target, target.videoKbps >= higher.videoKbps {
                tiers[tier] = above
                continue
            }
            options.append(found)
            tiers[tier] = found
            above = found
        }
        self.options = options
        self.tiers = tiers
    }

    /// Animation and anime need about two thirds of live action's bitrate.
    public static func isAnimated(genres: [String]) -> Bool {
        genres.contains { ["animation", "anime"].contains($0.lowercased()) }
    }

    // MARK: Estimate

    /// What the estimate knows of the original.
    struct Source {
        /// The size class.
        var height: Int
        var videoKbps: Int?
        var codec: String?
        var fps: Double

        init(media: PlexMedia, fallbackFPS: Double?) {
            height = PictureClass.of(media) ?? 1080
            let streams = media.parts.first?.streams ?? []
            let video = streams.first { $0.kind == .video }
            let audio = streams.filter { $0.kind == .audio }.compactMap(\.bitrate).reduce(0, +)
            videoKbps = video?.bitrate ?? media.bitrate.map { max(1, $0 - audio) }
            codec = video?.codec ?? media.videoCodec
            fps = video?.frameRate ?? Self.fps(media.videoFrameRate) ?? fallbackFPS ?? 24
        }

        /// Plex's `videoFrameRate`: "24p", "PAL", "NTSC", "60p".
        static func fps(_ text: String?) -> Double? {
            switch text?.uppercased() {
            case nil: nil
            case "PAL": 25
            case "NTSC": 29.97
            case let value?: Double(value.filter { $0.isNumber || $0 == "." })
            }
        }
    }

    /// kbit/s of Plex's hardware H.264 that reach each tier's score for live action at 24 fps from a
    /// typical 1080 original: at the original's size, and one size below it scaled back up. One size
    /// below cannot reach High, and two sizes below reach none. Other sizes scale by their pixels to
    /// the power 0.75.
    static let need: [[DownloadTier: Double]] = [
        [.high: 8000, .medium: 5000, .low: 3400],
        [.medium: 4000, .low: 2600],
    ]

    /// HEVC at 2160 for High: 1080's rate scaled by the pixels, two thirds of it for HEVC.
    static let uhdNeed = 15000.0

    /// The cheapest size and bitrate that reach the tier's score, at Plex's least rate for each size.
    static func estimate(_ tier: DownloadTier, source: Source, factor: Double) -> DownloadTarget {
        let reference = min(source.height, 1080)
        let scale = pow(pixels(reference) / pixels(1080), 0.75)
        let sizes = Array(PictureClass.heights.filter { $0 <= reference }.reversed().prefix(need.count))
        var best: DownloadTarget?
        for (steps, height) in sizes.enumerated() {
            guard let base = need[steps][tier] else { continue }
            let kbps = max(TranscodeLadder.floor(height: height), TranscodeLadder.roundUp(Int((base * scale * factor).rounded())))
            if best.map({ kbps < $0.videoKbps }) ?? true { best = DownloadTarget(videoKbps: kbps, height: height) }
        }
        return best ?? DownloadTarget(videoKbps: TranscodeLadder.floor(height: reference), height: reference)
    }

    /// Frame rate: by its square root, 0.9 to 1.5 times. Animation: 0.65 times. The original's own
    /// bitrate, in H.264 terms against a typical one at its size, says how much detail it holds:
    /// by the fifth root, 0.85 to 1.2 times.
    static func factor(_ source: Source, animated: Bool) -> Double {
        let motion = min(max((source.fps / 24).squareRoot(), 0.9), 1.5)
        var detail = 1.0
        if let kbps = source.videoKbps, kbps > 0 {
            let typical: Double = switch source.height {
            case 2160...: 28000
            case 1080...: 10000
            case 720...: 5000
            default: 2000
            }
            detail = min(max(pow(Double(kbps) * efficiency(of: source.codec) / typical, 0.2), 0.85), 1.2)
        }
        return motion * (animated ? 0.65 : 1) * detail
    }

    /// How many H.264 bits a codec's bit is worth.
    static func efficiency(of codec: String?) -> Double {
        switch codec?.lowercased() {
        case "hevc", "h265": 1.5
        case "av1": 1.8
        case "vp9": 1.4
        case "mpeg2video", "mpeg2": 0.6
        case "vc1", "wmv3": 0.8
        case "mpeg4", "msmpeg4v3": 0.7
        default: 1
        }
    }

    /// Nil when the original holds the target: it is Original then. When the original does not play
    /// offline, the target drops to the original's bitrate and the largest size Plex makes at it.
    static func capped(_ target: DownloadTarget, source: Source, originalPlays: Bool) -> DownloadTarget? {
        guard let limit = source.videoKbps, target.videoKbps >= limit else { return target }
        if originalPlays { return nil }
        let kbps = max(limit / 50 * 50, 50)
        let height = PictureClass.heights.last { $0 <= target.height && TranscodeLadder.floor(height: $0) <= kbps } ?? 480
        if target.height >= 2160, height < 2160 { return nil }
        return DownloadTarget(videoKbps: kbps, height: height, codec: target.codec)
    }

    private static func pixels(_ height: Int) -> Double {
        Double(PictureClass.width(of: height) * height)
    }
}
