import Foundation

/// The parameters of a server HLS stream (`/video/:/transcode/universal/start.m3u8`). The audio and
/// subtitle the server uses are the part's selected streams: set them with
/// `PlexLibrary.selectStreams` before starting.
public struct TranscodeRequest: Sendable, Hashable {
    /// `/library/metadata/<ratingKey>`, or a tuned channel's `/livetv/sessions/<id>`.
    public var path: String
    public var mediaIndex: Int
    public var partIndex: Int
    /// Names the stream on the server; timeline reports and `stopTranscode` use it too.
    public var session: String
    /// Where playback starts, in seconds.
    public var offset: Double
    /// The server may copy the video when the phone can play it, converting only the rest.
    public var copiesVideo: Bool
    public var burnsSubtitles: Bool
    public var maxVideoBitrateKbps: Int
    /// e.g. "1920x1080".
    public var videoResolution: String

    /// - Parameters:
    ///   - maxVideoBitrateKbps: The picked quality; defaults to the source bitrate, at least 8 Mbit/s.
    ///   - videoResolution: The picked quality's size; defaults to the source size.
    public init(
        item: PlexMetadata,
        mediaIndex: Int = 0,
        partIndex: Int = 0,
        route: PlaybackRoute,
        maxVideoBitrateKbps: Int? = nil,
        videoResolution: String? = nil,
        offset: Double = 0,
        session: String = UUID().uuidString
    ) {
        let media = item.media.indices.contains(mediaIndex) ? item.media[mediaIndex] : nil
        path = "/library/metadata/\(item.ratingKey)"
        self.mediaIndex = mediaIndex
        self.partIndex = partIndex
        self.session = session
        self.offset = offset
        copiesVideo = !route.reencodesVideo
        burnsSubtitles = if case .burnedIn = route.subtitle { true } else { false }
        self.maxVideoBitrateKbps = maxVideoBitrateKbps ?? max(media?.bitrate ?? 0, 8_000)
        self.videoResolution = videoResolution ?? "\(media?.width ?? 1920)x\(media?.height ?? 1080)"
    }

    /// A channel the server tuned, named after the tune's session so the transcoder finds the stream.
    /// The server copies H.264 and HEVC and converts the rest (MPEG-2), since AVPlayer has no MPEG-2
    /// decoder.
    public init(
        live session: PlexLiveSession,
        maxVideoBitrateKbps: Int = 8_000,
        videoResolution: String = "1920x1080"
    ) {
        path = session.path
        mediaIndex = 0
        partIndex = 0
        self.session = session.sessionIdentifier
        offset = 0
        copiesVideo = session.phoneDecodesVideo
        burnsSubtitles = false
        self.maxVideoBitrateKbps = maxVideoBitrateKbps
        self.videoResolution = videoResolution
    }

    func queryItems(location: String) -> [URLQueryItem] {
        [
            ("hasMDE", "1"),
            ("path", path),
            ("mediaIndex", String(mediaIndex)),
            ("partIndex", String(partIndex)),
            ("protocol", "hls"),
            ("fastSeek", "1"),
            ("directPlay", "0"),
            ("directStream", copiesVideo ? "1" : "0"),
            ("directStreamAudio", "1"),
            ("subtitles", burnsSubtitles ? "burn" : "none"),
            ("subtitleSize", "100"),
            ("audioBoost", "100"),
            ("videoQuality", "100"),
            ("maxVideoBitrate", String(maxVideoBitrateKbps)),
            ("videoResolution", videoResolution),
            ("autoAdjustQuality", "0"),
            ("location", location),
            ("session", session),
            (PlexHeader.sessionIdentifier, session),
            ("offset", String(offset)),
            ("copyts", "1"),
            ("mediaBufferSize", "102400"),
        ].map { URLQueryItem(name: $0.0, value: $0.1) }
    }
}
