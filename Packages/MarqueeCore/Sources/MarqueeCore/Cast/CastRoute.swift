import Foundation

/// A Chromecast running Google's Default Media Receiver, and the video it opens as a file. Limits from
/// Google's supported-media list for Cast devices.
public struct CastReceiver: Sendable, Hashable {
    /// The largest picture it shows.
    public var maxWidth: Int
    public var maxHeight: Int
    /// HEVC Main and Main 10 up to level 5.1.
    public var playsHEVC: Bool
    /// The highest H.264 level, as Plex writes it (41 for 4.1).
    public var maxH264Level: Int

    public init(maxWidth: Int, maxHeight: Int, playsHEVC: Bool, maxH264Level: Int) {
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.playsHEVC = playsHEVC
        self.maxH264Level = maxH264Level
    }

    /// Chromecast Ultra and Google TV Streamer show 4K HEVC. Every other receiver is taken as a 1080p
    /// H.264 one, which all of them play: Chromecast with Google TV reports the same model name for its
    /// HD and 4K versions, and TVs with Chromecast built in report their own.
    public init(modelName: String?) {
        switch modelName?.lowercased() {
        case "chromecast ultra", "google tv streamer":
            self.init(maxWidth: 3840, maxHeight: 2160, playsHEVC: true, maxH264Level: 42)
        default:
            self.init(maxWidth: 1920, maxHeight: 1080, playsHEVC: false, maxH264Level: 41)
        }
    }
}

public enum CastRouteDecider {
    /// The highest rate the server encodes video for a Chromecast at, whatever the picked quality.
    public static let maxVideoBitrateKbps = 20_000

    /// Picks how `part` reaches the receiver with the chosen audio and subtitle:
    /// 1. Direct play: the receiver opens the file itself. MP4 with video it decodes, AAC or MP3 as the
    ///    file's first audio track, no subtitle, within the picked quality.
    /// 2. Server stream: HLS of H.264 and AAC, copying H.264 the receiver decodes and converting the rest.
    ///    The Default Media Receiver draws none of Plex's subtitle formats, so a subtitle is burned in.
    ///
    /// Settings' Force Direct Play applies to the phone only: a file the receiver cannot open streams from
    /// the server. Turning direct play off sends every file through the server.
    public static func decide(
        media: PlexMedia,
        part: PlexPart,
        tracks: MediaTracks,
        audio: AudioTrack?,
        subtitle: SubtitleDecision,
        receiver: CastReceiver,
        limits: RouteLimits = RouteLimits()
    ) -> PlaybackRoute {
        let container = (part.container ?? media.container ?? "").lowercased()
        let video = part.videoStream
        let codec = (video?.codec ?? media.videoCodec ?? "").lowercased()
        let frame = (width: receiver.maxWidth, height: receiver.maxHeight)
        var reasons: [RouteReason] = []

        if let reason = limits.serverReason, reason != .onDeviceFailed, reason != .airPlay { reasons.append(reason) }
        if !limits.audioEnhancements.isEmpty { reasons.append(.audioEnhancement) }
        let videoReason = video.flatMap { undecodable($0, codec: codec, receiver) }
        if let videoReason { reasons.append(videoReason) }
        let tooLarge = PlaybackRouteDecider.exceeds(media, video, frame)
        if tooLarge, let height = video?.height ?? media.height { reasons.append(.videoFormat("\(height)p")) }
        let shrinks = PlaybackRouteDecider.exceeds(media, video, limits.quality.frame)
        if let cap = limits.quality.maxBitrateKbps, shrinks || (media.bitrate ?? 0) > cap { reasons.append(.bitrateLimit(kbps: cap)) }
        if !["mp4", "m4v"].contains(container) { reasons.append(.container(container.isEmpty ? "unknown" : container)) }
        if let audio {
            if audio.id != tracks.audio.first?.id { reasons.append(.notFirstAudioTrack) }
            if !["aac", "mp3"].contains(audio.codec) { reasons.append(.audio(audio.codec.isEmpty ? "unknown" : audio.codec)) }
        }

        var delivery = SubtitleDelivery.none
        if let track = subtitle.track {
            // Captions inside the video are not a stream the server can burn.
            if track.isInVideoStream {
                delivery = .notShown(track)
            } else {
                reasons.append(.burnsSubtitle)
                delivery = .burnedIn(track)
            }
        }

        guard !reasons.isEmpty else {
            return PlaybackRoute(
                kind: .directPlay, reasons: [], audio: audio, audioIsStandIn: false, convertsAudio: false,
                reencodesVideo: false, maxVideoBitrateKbps: nil, videoResolution: nil, subtitle: delivery
            )
        }
        // The server sends H.264 only, so other video is re-encoded even when the receiver decodes it.
        let copies = videoReason == nil && PlaybackRouteDecider.isH264(codec)
        let reencodes = !copies || reasons.contains(where: \.needsReencode)
        // Its H.264 has to stay within level 4.1: 1080p, or the picked quality's size when smaller.
        let quality = limits.quality.frame ?? (width: 1920, height: 1080)
        let target = quality.width < 1920 ? quality : (width: 1920, height: 1080)
        let size = PlaybackRouteDecider.exceeds(media, video, target) ? target : nil
        return PlaybackRoute(
            kind: .serverTranscode,
            reasons: reasons,
            audio: audio,
            audioIsStandIn: false,
            convertsAudio: false,
            reencodesVideo: reencodes,
            maxVideoBitrateKbps: reencodes ? min(limits.quality.maxBitrateKbps ?? maxVideoBitrateKbps, maxVideoBitrateKbps) : nil,
            videoResolution: reencodes ? size.map { "\($0.width)x\($0.height)" } : nil,
            audioEnhancements: limits.audioEnhancements,
            subtitle: delivery
        )
    }

    /// Why the receiver cannot decode the video, or nil when it can.
    private static func undecodable(_ video: PlexStream, codec: String, _ receiver: CastReceiver) -> RouteReason? {
        let depth = video.bitDepth ?? 8
        let chroma = video.chromaSubsampling.flatMap { $0.filter(\.isNumber) == "420" ? nil : $0 }
        if let rate = video.frameRate, rate > 60.5 { return .levelOrFrameRate }
        if PlaybackRouteDecider.isH264(codec) {
            if let dolbyVision = video.dolbyVision { return .dolbyVision(profile: dolbyVision.profile) }
            if depth > 8 { return .videoFormat("\(depth)-bit H.264") }
            if let chroma { return .videoFormat("H.264 \(chroma)") }
            if let level = video.level, level > receiver.maxH264Level { return .videoFormat("H.264 level \(Double(level) / 10)") }
            return nil
        }
        guard PlaybackRouteDecider.isHEVC(codec), receiver.playsHEVC else { return .videoCodec(codec.isEmpty ? "unknown" : codec) }
        // Profile 8 carries an HDR10, HLG or SDR base layer the receiver shows; the others need Dolby Vision.
        if let dolbyVision = video.dolbyVision, dolbyVision.profile != 8 { return .dolbyVision(profile: dolbyVision.profile) }
        if depth > 10 { return .videoFormat("\(depth)-bit HEVC") }
        if let chroma { return .videoFormat("HEVC \(chroma)") }
        if let level = video.level, level > 153 { return .levelOrFrameRate }
        return nil
    }
}
