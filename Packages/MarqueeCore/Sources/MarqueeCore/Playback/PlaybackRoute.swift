import Foundation

/// How one item reaches the screen, and why.
public struct PlaybackRoute: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        /// The player opens the file itself.
        case directPlay
        /// The app repackages the file on the phone without re-encoding the video.
        case remux
        /// The server sends HLS: it re-encodes the video, or copies it and converts the rest.
        case serverTranscode
    }

    public var kind: Kind
    /// Why a heavier route than direct play was needed; empty for direct play.
    public var reasons: [RouteReason]
    /// The audio to play: the pick, or a track in the same language standing in for audio the phone
    /// cannot play.
    public var audio: AudioTrack?
    public var audioIsStandIn: Bool
    /// The remux converts the audio to AAC.
    public var convertsAudio: Bool
    /// The server re-encodes the video. False for direct play, the remux, and a server stream that copies
    /// the video.
    public var reencodesVideo: Bool
    /// The rate the server encodes the video under, when a reason sets one; nil leaves the default.
    public var maxVideoBitrateKbps: Int?
    /// The picture size the server encodes the video down to, "1280x720", when the picked quality is
    /// smaller than the file; nil keeps the file's size.
    public var videoResolution: String?
    /// What the server does to the audio on a server stream; empty on the phone's routes.
    public var audioEnhancements: AudioEnhancements = []
    public var subtitle: SubtitleDelivery
}

public enum SubtitleDelivery: Sendable, Hashable {
    case none
    /// A separate file the app loads and draws.
    case sidecar(SubtitleTrack)
    /// Inside the played stream: MP4 text, closed captions in the video, or a track the remux carries
    /// (text as WebVTT, pictures for the app to draw).
    case inStream(SubtitleTrack)
    /// Burned into the picture by the server.
    case burnedIn(SubtitleTrack)
    /// Chosen but not shown: only a server re-encode could show it, and only a hand pick may cause one.
    case notShown(SubtitleTrack)
}

public enum RouteReason: Sendable, Hashable, CustomStringConvertible {
    /// A container the player cannot open, e.g. "mkv".
    case container(String)
    /// HEVC in an MP4 that may be tagged hev1, which the player shows black.
    case hevcTag
    /// Dolby Vision profile 7: only its HDR10 base layer plays.
    case dolbyVisionBaseLayer
    /// Audio the phone cannot play, e.g. "dts".
    case audio(String)
    /// Video the phone cannot decode, e.g. "vc1".
    case videoCodec(String)
    /// A form of the video the phone cannot decode: "10-bit H.264", "HEVC 4:2:2", "12-bit HEVC".
    case videoFormat(String)
    /// Dolby Vision the phone cannot show: profile 5 (no HDR10 base layer) or an H.264-based profile.
    case dolbyVision(profile: Int)
    /// HDR video on a screen that shows only SDR; the server tone-maps it.
    case hdrOnSDRScreen
    /// Above level 5.1 or 60 frames per second, which HLS on the phone does not take.
    case levelOrFrameRate
    /// Above the quality picked in the player.
    case bitrateLimit(kbps: Int)
    /// A hand-picked subtitle that only the server can show, by burning it in.
    case burnsSubtitle
    /// Playing on the phone failed, so the server takes over.
    case onDeviceFailed
    /// Direct play is turned off in Settings.
    case directPlayOff
    /// AirPlay is showing the video, and the receiver cannot reach a stream made on the phone.
    case airPlay
    /// The server is reached over the internet, too slowly for the remux to read the file.
    case remoteConnection
    /// The link to the server, as last measured, carries less than the file's bitrate with a quarter to
    /// spare; the server re-encodes the video to fit it.
    case slowLink(kbps: Int)
    /// Boost dialog or Normalize loudness is on, which only the server's audio conversion can do.
    case audioEnhancement

    /// The server has to re-encode the video for this reason.
    var needsReencode: Bool {
        switch self {
        case .videoCodec, .videoFormat, .dolbyVision, .hdrOnSDRScreen, .levelOrFrameRate, .bitrateLimit, .burnsSubtitle, .slowLink:
            true
        case .container, .hevcTag, .dolbyVisionBaseLayer, .audio, .onDeviceFailed, .directPlayOff, .airPlay, .remoteConnection,
             .audioEnhancement:
            false
        }
    }

    public var description: String {
        switch self {
        case .container(let name): "\(name.uppercased()) file"
        case .hevcTag: "HEVC needs a new tag"
        case .dolbyVisionBaseLayer: "Dolby Vision profile 7 plays as HDR10"
        case .audio(let codec): "\(codec.uppercased()) audio"
        case .videoCodec(let codec): "\(codec.uppercased()) video"
        case .videoFormat(let format): format
        case .dolbyVision(let profile): "Dolby Vision profile \(profile)"
        case .hdrOnSDRScreen: "HDR on an SDR screen"
        case .levelOrFrameRate: "Above level 5.1 or 60 fps"
        case .bitrateLimit(let kbps): "Quality limit \(kbps / 1000) Mbps"
        case .burnsSubtitle: "Subtitles burned in"
        case .onDeviceFailed: "Playing on the phone failed"
        case .directPlayOff: "Direct play turned off"
        case .airPlay: "AirPlay needs a server stream"
        case .remoteConnection: "Server reached over the internet"
        case .slowLink(let kbps): "Link measured at \(Double(kbps / 100) / 10) Mbps"
        case .audioEnhancement: "Boost dialog or Normalize loudness on"
        }
    }
}

/// The highest quality a video plays at (behaviour spec §4, "Default quality"): the server converts a
/// file above it to fit. The raw value is the bitrate ceiling in kbit/s, 0 for Original.
public enum VideoQuality: Int, Sendable, Hashable, Codable, CaseIterable {
    case original = 0
    case mbps20 = 20_000
    case mbps12 = 12_000
    case mbps8 = 8_000
    case mbps4 = 4_000
    case mbps2 = 2_000

    /// Nil for Original.
    public var maxBitrateKbps: Int? { self == .original ? nil : rawValue }

    /// The largest picture at this quality, width by height; nil for Original.
    public var frame: (width: Int, height: Int)? {
        switch self {
        case .original: nil
        case .mbps20, .mbps12, .mbps8: (1920, 1080)
        case .mbps4, .mbps2: (1280, 720)
        }
    }

    /// "Original", "20 Mbps 1080p".
    public var title: String {
        guard let kbps = maxBitrateKbps, let frame else { return "Original" }
        return "\(kbps / 1000) Mbps \(frame.height)p"
    }
}

/// Plex Pass audio processing the server applies while it converts the audio. Either one needs the
/// track's loudness analysed first (`AudioTrack.canNormalizeLoudness`).
public struct AudioEnhancements: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Clearer speech.
    public static let boostDialog = AudioEnhancements(rawValue: 1)
    /// Even loudness across the video.
    public static let normalizeLoudness = AudioEnhancements(rawValue: 2)
}

/// Limits set in the player and in Settings.
public struct RouteLimits: Sendable, Hashable {
    /// Why the server streams even what the phone could play: `.onDeviceFailed`, `.directPlayOff` or
    /// `.airPlay`.
    public var serverReason: RouteReason?
    /// Settings force direct play: every file plays on the phone as it is, never through the server.
    public var phoneOnly: Bool
    /// The picked quality; a source above its bitrate or picture size is converted down.
    public var quality: VideoQuality
    /// The server is reached through a remote or relay address. A file that needs the remux then streams
    /// from the server: the remux reads the file's header, index and start point one request at a time,
    /// which took 11 s before the first picture over a 14 Mbit/s remote path. Direct play is unaffected.
    public var remoteConnection: Bool
    /// The link to the server as the last stream measured it, in kbit/s.
    public var linkKbps: Int?
    /// Boost dialog or Normalize loudness is on: the server streams, copying the video when it can.
    public var audioEnhancements: AudioEnhancements

    public init(
        serverReason: RouteReason? = nil, phoneOnly: Bool = false, quality: VideoQuality = .original, remoteConnection: Bool = false,
        linkKbps: Int? = nil, audioEnhancements: AudioEnhancements = []
    ) {
        self.serverReason = serverReason
        self.phoneOnly = phoneOnly
        self.quality = quality
        self.remoteConnection = remoteConnection
        self.linkKbps = linkKbps
        self.audioEnhancements = audioEnhancements
    }
}

public enum PlaybackRouteDecider {
    /// Picks the lightest route that plays `part` with the chosen audio and subtitle, from Plex's stream
    /// facts alone:
    /// 1. Direct play: MP4/MOV with H.264 or hvc1 HEVC and audio the player takes.
    /// 2. Remux on the phone: other containers, hev1 HEVC, Dolby Vision 7 (base layer), audio the remux
    ///    converts, embedded subtitles it carries. Without a remux the server copies the video instead.
    /// 3. Server re-encode: video the phone cannot decode, Dolby Vision it cannot show, HDR on an SDR
    ///    screen or HLS limits for copied video, a quality limit, or a hand-picked subtitle to burn in.
    ///
    /// Audio the phone cannot play is first swapped for a playable track in the same language (not
    /// commentary, same dub-ness and audio description). Subtitle defaults never burn; a remembered pick
    /// burns only when the video is re-encoded anyway.
    ///
    /// With `limits.phoneOnly` the server is never used: the file plays directly, or through the remux when
    /// it needs one, and a subtitle only the server could show is not shown.
    ///
    /// - Parameter hevcSampleEntry: `hvc1` or `hev1` when the app has read the MP4's sample entry; HEVC in
    ///   an MP4 without it is remuxed to be safe.
    public static func decide(
        media: PlexMedia,
        part: PlexPart,
        tracks: MediaTracks,
        audio: AudioTrack?,
        subtitle: SubtitleDecision,
        capabilities: DeviceCapabilities,
        limits: RouteLimits = RouteLimits(),
        hevcSampleEntry: String? = nil
    ) -> PlaybackRoute {
        let container = (part.container ?? media.container ?? "").lowercased()
        let video = part.videoStream
        let codec = (video?.codec ?? media.videoCodec ?? "").lowercased()
        var serverReasons: [RouteReason] = []
        var remuxReasons: [RouteReason] = []

        if let reason = limits.serverReason { serverReasons.append(reason) }
        if !limits.audioEnhancements.isEmpty { serverReasons.append(.audioEnhancement) }
        if let video, let reason = undecodable(video, codec: codec, capabilities) { serverReasons.append(reason) }
        let shrinks = exceeds(media, video, limits.quality.frame)
        if let cap = limits.quality.maxBitrateKbps, shrinks || (media.bitrate ?? 0) > cap { serverReasons.append(.bitrateLimit(kbps: cap)) }
        if let link = limits.linkKbps, let bitrate = media.bitrate, link * 4 < bitrate * 5 { serverReasons.append(.slowLink(kbps: link)) }

        if !directContainers.contains(container) {
            remuxReasons.append(.container(container.isEmpty ? "unknown" : container))
        } else if isHEVC(codec), container != "mov", !["hvc1", "dvh1"].contains(hevcSampleEntry?.lowercased() ?? "") {
            remuxReasons.append(.hevcTag)
        }
        let dolbyVisionProfile = isHEVC(codec) ? video?.dolbyVision?.profile : nil
        if dolbyVisionProfile == 7 { remuxReasons.append(.dolbyVisionBaseLayer) }

        var playedAudio = audio
        var audioIsStandIn = false
        var audioNeedsConversion = false
        if let audio, !capabilities.nativeAudioCodecs.contains(audio.codec) {
            if let standIn = standIn(for: audio, in: tracks, capabilities) {
                playedAudio = standIn
                audioIsStandIn = true
            } else {
                audioNeedsConversion = true
                remuxReasons.append(.audio(audio.codec.isEmpty ? "unknown" : audio.codec))
            }
        }

        // Profile 5 has no base layer to fall back on: it plays only untouched or through a remux that
        // keeps its metadata. A server stream drops the metadata, so the server must tone-map it.
        if dolbyVisionProfile == 5,
           !capabilities.dolbyVisionProfiles.contains(5)
            || (!remuxReasons.isEmpty && !(capabilities.canRemux && capabilities.remuxKeepsDolbyVision)) {
            serverReasons.append(.dolbyVision(profile: 5))
        }

        var kind: PlaybackRoute.Kind
        var reencodes = serverReasons.contains(where: \.needsReencode)
        if limits.phoneOnly {
            serverReasons = []
            reencodes = false
            kind = remuxReasons.isEmpty || !capabilities.canRemux ? .directPlay : .remux
        } else if !serverReasons.isEmpty {
            kind = .serverTranscode
        } else if remuxReasons.isEmpty {
            kind = .directPlay
        } else if capabilities.canRemux, !audioNeedsConversion || capabilities.remuxConvertsAudio {
            if limits.remoteConnection {
                serverReasons.append(.remoteConnection)
                kind = .serverTranscode
            } else {
                kind = .remux
            }
        } else {
            kind = .serverTranscode
        }
        if !limits.phoneOnly, kind != .directPlay, !reencodes, let video, let reason = hlsLimit(video, codec: codec, capabilities) {
            serverReasons.append(reason)
            kind = .serverTranscode
            reencodes = true
        }
        // The same holds for a server stream picked for any other reason: profile 5 is tone-mapped, never copied.
        if kind == .serverTranscode, !reencodes, dolbyVisionProfile == 5 {
            serverReasons.append(.dolbyVision(profile: 5))
            reencodes = true
        }

        var delivery = SubtitleDelivery.none
        if let track = subtitle.track {
            if let onPhone = onDevice(track, kind: kind, reencodes: reencodes, capabilities) {
                delivery = onPhone
            } else if limits.phoneOnly {
                delivery = .notShown(track)
            } else {
                switch subtitle.source {
                case .handPick:
                    if !reencodes { serverReasons.append(.burnsSubtitle) }
                    kind = .serverTranscode
                    reencodes = true
                    delivery = .burnedIn(track)
                case .remembered:
                    delivery = reencodes ? .burnedIn(track) : .notShown(track)
                case .server, .fileDefault, .setting:
                    delivery = .notShown(track)
                }
            }
        }

        // A fifth of a slow link stays free for audio and the requests around the stream.
        let slowLinkCap = serverReasons.lazy.compactMap { reason -> Int? in
            if case .slowLink(let kbps) = reason { return kbps * 4 / 5 }
            return nil
        }.first
        let converts = kind == .serverTranscode && reencodes
        let frame = limits.quality.frame.map { "\($0.width)x\($0.height)" }
        return PlaybackRoute(
            kind: kind,
            reasons: kind == .directPlay ? [] : serverReasons + remuxReasons,
            audio: playedAudio,
            audioIsStandIn: audioIsStandIn,
            convertsAudio: kind == .remux && audioNeedsConversion,
            reencodesVideo: converts,
            maxVideoBitrateKbps: converts ? [limits.quality.maxBitrateKbps, slowLinkCap].compactMap(\.self).min() : nil,
            videoResolution: converts && shrinks ? frame : nil,
            audioEnhancements: kind == .serverTranscode ? limits.audioEnhancements : [],
            subtitle: delivery
        )
    }

    /// The file's picture is larger than `frame`.
    private static func exceeds(_ media: PlexMedia, _ video: PlexStream?, _ frame: (width: Int, height: Int)?) -> Bool {
        guard let frame, let width = video?.width ?? media.width, let height = video?.height ?? media.height else { return false }
        return width > frame.width || height > frame.height
    }

    private static let directContainers: Set<String> = ["mp4", "m4v", "mov"]

    private static func isHEVC(_ codec: String) -> Bool {
        ["hevc", "h265", "hvc1", "hev1"].contains(codec)
    }

    private static func isH264(_ codec: String) -> Bool {
        ["h264", "avc", "avc1"].contains(codec)
    }

    /// Why the phone cannot decode the video, or nil when it can.
    private static func undecodable(_ video: PlexStream, codec: String, _ capabilities: DeviceCapabilities) -> RouteReason? {
        let depth = video.bitDepth ?? 8
        let chroma = video.chromaSubsampling.flatMap { $0.filter(\.isNumber) == "420" ? nil : $0 }
        switch codec {
        case _ where isH264(codec):
            if let dolbyVision = video.dolbyVision { return .dolbyVision(profile: dolbyVision.profile) }
            if depth > 8 { return .videoFormat("\(depth)-bit H.264") }
            if let chroma { return .videoFormat("H.264 \(chroma)") }
            return nil
        case _ where isHEVC(codec):
            guard capabilities.hevc else { return .videoCodec("hevc") }
            if depth > 10 { return .videoFormat("\(depth)-bit HEVC") }
            if let chroma { return .videoFormat("HEVC \(chroma)") }
            if depth == 10, !capabilities.hevcMain10 { return .videoFormat("10-bit HEVC") }
            return nil
        case "av1":
            return capabilities.av1 ? nil : .videoCodec("av1")
        default:
            return .videoCodec(codec.isEmpty ? "unknown" : codec)
        }
    }

    /// Why copied video cannot go out as HLS (the remux and a server stream both produce HLS).
    private static func hlsLimit(_ video: PlexStream, codec: String, _ capabilities: DeviceCapabilities) -> RouteReason? {
        let pq = video.colorTrc == "smpte2084", hlg = video.colorTrc == "arib-std-b67"
        let dolbyVisionHDR = video.dolbyVision.map { $0.baseLayerCompatibility != 2 } ?? false
        if pq || hlg || dolbyVisionHDR, !capabilities.hdrDisplay { return .hdrOnSDRScreen }
        // Plex writes H.264 level 5.1 as 51 and HEVC level 5.1 as 153 (general_level_idc).
        let maxLevel = isHEVC(codec) ? 153 : isH264(codec) ? 51 : Int.max
        if let level = video.level, level > maxLevel { return .levelOrFrameRate }
        if let rate = video.frameRate, rate > 60.5 { return .levelOrFrameRate }
        return nil
    }

    /// How the phone shows `track` on this route without a server re-encode, or nil when it cannot.
    private static func onDevice(
        _ track: SubtitleTrack,
        kind: PlaybackRoute.Kind,
        reencodes: Bool,
        _ capabilities: DeviceCapabilities
    ) -> SubtitleDelivery? {
        if track.isExternal {
            return !track.isImageBased || capabilities.drawsImageSubtitles ? .sidecar(track) : nil
        }
        if track.isInVideoStream { return reencodes ? nil : .inStream(track) }
        switch kind {
        case .directPlay:
            return track.isImageBased ? nil : .inStream(track)
        case .remux:
            let carried = track.isImageBased ? capabilities.drawsImageSubtitles : capabilities.remuxCarriesTextSubtitles
            return carried ? .inStream(track) : nil
        case .serverTranscode:
            return nil
        }
    }

    /// A playable track in the same language to play instead of `audio`: never a commentary, and with
    /// the same dub-ness and audio description. The one with the most channels wins.
    private static func standIn(for audio: AudioTrack, in tracks: MediaTracks, _ capabilities: DeviceCapabilities) -> AudioTrack? {
        guard !audio.isCommentary, audio.language.isKnown else { return nil }
        let candidates = tracks.audio.filter {
            $0.id != audio.id && capabilities.nativeAudioCodecs.contains($0.codec) && $0.language.matches(audio.language)
                && !$0.isCommentary && $0.isDub == audio.isDub && $0.isAudioDescription == audio.isAudioDescription
        }
        let most = candidates.map { $0.channels ?? 0 }.max()
        return candidates.first { ($0.channels ?? 0) == most }
    }
}
