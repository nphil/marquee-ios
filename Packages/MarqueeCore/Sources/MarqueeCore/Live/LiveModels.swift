import Foundation

/// A DVR on the server: one guide lineup and the tuners that receive it (`GET /livetv/dvrs`).
public struct LiveDVR: Identifiable, Hashable, Sendable, Codable {
    public var id: String { key }
    public var key: String
    public var uuid: String
    /// The lineup's name, e.g. "Antenna".
    public var title: String
    /// The guide provider, e.g. `tv.plex.providers.epg.cloud:5`; channel and guide paths start with it.
    public var epgIdentifier: String
    public var devices: [TunerDevice]
    /// Every channel a device maps, enabled or not.
    public var mappings: [LiveChannelMapping]
    /// Minutes recordings start early and end late, from the DVR's settings.
    public var startOffsetMinutes: Int
    public var endOffsetMinutes: Int

    public init(
        key: String,
        uuid: String,
        title: String,
        epgIdentifier: String,
        devices: [TunerDevice],
        mappings: [LiveChannelMapping],
        startOffsetMinutes: Int = 0,
        endOffsetMinutes: Int = 0
    ) {
        self.key = key
        self.uuid = uuid
        self.title = title
        self.epgIdentifier = epgIdentifier
        self.devices = devices
        self.mappings = mappings
        self.startOffsetMinutes = startOffsetMinutes
        self.endOffsetMinutes = endOffsetMinutes
    }

    /// The device that receives `channelKey` and its mapping: the first live device with the channel
    /// enabled, else the first that has it enabled at all.
    public func receiver(of channelKey: String) -> (device: TunerDevice, mapping: LiveChannelMapping)? {
        let enabled = mappings.filter { $0.channelKey == channelKey && $0.isEnabled }
        let candidates = enabled.compactMap { mapping in
            devices.first { $0.key == mapping.deviceKey }.map { (device: $0, mapping: mapping) }
        }
        return candidates.first { $0.device.isAlive } ?? candidates.first
    }

    /// Whether `device` has `channelKey` enabled, so a recording of that channel may take one of its tuners.
    public func device(_ device: TunerDevice, carries channelKey: String) -> Bool {
        mappings.contains { $0.deviceKey == device.key && $0.channelKey == channelKey && $0.isEnabled }
    }
}

/// One channel as one device receives it (`Device.ChannelMapping`).
public struct LiveChannelMapping: Hashable, Sendable, Codable {
    public var channelKey: String
    public var deviceKey: String
    /// The tuner's own number for the channel (its `GuideNumber`), e.g. "2.1".
    public var number: String
    public var isEnabled: Bool

    public init(channelKey: String, deviceKey: String, number: String, isEnabled: Bool) {
        self.channelKey = channelKey
        self.deviceKey = deviceKey
        self.number = number
        self.isEnabled = isEnabled
    }
}

/// A tuner device of a DVR: an HDHomeRun, LumaTuner, an IPTV proxy or another grabber.
public struct TunerDevice: Identifiable, Hashable, Sendable, Codable {
    public var id: String { key }
    public var key: String
    /// `device://<grabber>/<device id>`.
    public var uuid: String
    public var uri: URL
    public var name: String
    public var tunerCount: Int
    /// False once Plex reports the device dead.
    public var isAlive: Bool

    public init(key: String, uuid: String, uri: URL, name: String, tunerCount: Int, isAlive: Bool) {
        self.key = key
        self.uuid = uuid
        self.uri = uri
        self.name = name
        self.tunerCount = tunerCount
        self.isAlive = isAlive
    }

    /// Real HDHomeRuns, LumaTuner and the HDHomeRun-emulating IPTV proxies: the phone can read these itself.
    public var speaksHDHomeRun: Bool { uuid.hasPrefix("device://tv.plex.grabbers.hdhomerun/") }

    /// The device's own stream of `channel`, `<uri>/auto/v<number>`.
    public func streamURL(_ channel: LiveChannel) -> URL {
        uri.appendingPathComponent("auto").appendingPathComponent("v" + channel.number)
    }
}

/// A channel of the lineup that a device has enabled.
public struct LiveChannel: Identifiable, Hashable, Sendable, Codable {
    /// The channel key: `Channel.id`, `ChannelMapping.channelKey` and the guide's `channelIdentifier`.
    public var id: String
    public var dvrKey: String
    /// The tuner's number for it, e.g. "2.1".
    public var number: String
    public var callSign: String
    /// The network or station name.
    public var title: String
    /// An absolute image URL on Plex's image host, drawn through the server's photo transcoder.
    public var logo: String?
    public var isHD: Bool
    public var device: TunerDevice

    public init(
        id: String,
        dvrKey: String,
        number: String,
        callSign: String,
        title: String,
        logo: String?,
        isHD: Bool,
        device: TunerDevice
    ) {
        self.id = id
        self.dvrKey = dvrKey
        self.number = number
        self.callSign = callSign
        self.title = title
        self.logo = logo
        self.isHD = isHD
        self.device = device
    }

    /// "2.1 WXXX".
    public var label: String { callSign.isEmpty ? number : "\(number) \(callSign)" }

    /// Orders "2.1" < "2.10" < "10.1": each dot-separated part compared as a number.
    public static func numberOrder(_ a: LiveChannel, _ b: LiveChannel) -> Bool {
        let left = a.number.split(separator: ".").map { Int($0) ?? Int.max }
        let right = b.number.split(separator: ".").map { Int($0) ?? Int.max }
        if left != right { return left.lexicographicallyPrecedes(right) }
        return a.callSign < b.callSign
    }
}

/// One showing of a programme on one channel. A programme simulcast on two channels is two airings.
public struct LiveAiring: Identifiable, Hashable, Sendable, Codable {
    public enum Kind: String, Sendable, Codable {
        case episode, movie, other
    }

    /// `Media.id`, unique per airing.
    public var id: String
    public var channelKey: String
    public var ratingKey: String
    /// The guide provider's metadata path.
    public var key: String
    /// `plex://episode/…`; record options are asked for by it.
    public var guid: String
    public var kind: Kind
    /// The show or movie title.
    public var title: String
    public var episodeTitle: String?
    public var season: Int?
    public var episode: Int?
    public var year: Int?
    public var summary: String?
    public var start: Date
    public var end: Date
    /// A first showing (`premiere`).
    public var isNew: Bool
    public var isHD: Bool
    public var genres: [String]
    /// Poster-style image: the show's for an episode. An absolute URL on Plex's image host.
    public var thumb: String?
    public var art: String?
    public var contentRating: String?

    public init(
        id: String,
        channelKey: String,
        ratingKey: String = "",
        key: String = "",
        guid: String = "",
        kind: Kind = .other,
        title: String,
        episodeTitle: String? = nil,
        season: Int? = nil,
        episode: Int? = nil,
        year: Int? = nil,
        summary: String? = nil,
        start: Date,
        end: Date,
        isNew: Bool = false,
        isHD: Bool = false,
        genres: [String] = [],
        thumb: String? = nil,
        art: String? = nil,
        contentRating: String? = nil
    ) {
        self.id = id
        self.channelKey = channelKey
        self.ratingKey = ratingKey
        self.key = key
        self.guid = guid
        self.kind = kind
        self.title = title
        self.episodeTitle = episodeTitle
        self.season = season
        self.episode = episode
        self.year = year
        self.summary = summary
        self.start = start
        self.end = end
        self.isNew = isNew
        self.isHD = isHD
        self.genres = genres
        self.thumb = thumb
        self.art = art
        self.contentRating = contentRating
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    public func isOn(at date: Date) -> Bool { start <= date && date < end }

    /// Share of the airing shown by `date`, 0...1.
    public func progress(at date: Date) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(date.timeIntervalSince(start) / duration, 0), 1)
    }

    /// "S2 E5", "S2", "E5" or nil.
    public var episodeCode: String? { Self.episodeCode(season: season, episode: episode) }

    static func episodeCode(season: Int?, episode: Int?) -> String? {
        switch (season, episode) {
        case let (season?, episode?): "S\(season) E\(episode)"
        case let (season?, nil): "S\(season)"
        case let (nil, episode?): "E\(episode)"
        case (nil, nil): nil
        }
    }
}

/// A genre the guide provider groups channels by (`GridChannelFilter`).
public struct LiveChannelFilter: Identifiable, Hashable, Sendable, Codable {
    public var id: String { key }
    public var title: String
    /// The channel list of the genre, `/<provider>/lineups/dvr/channels?genre=…`.
    public var key: String

    public init(title: String, key: String) {
        self.title = title
        self.key = key
    }
}

// MARK: - Playback

/// Where a live stream is.
public enum LiveState: Sendable, Hashable {
    case idle
    case opening
    /// The tuner's own slate is on screen (Direct only).
    case slate
    /// A station picture is on screen; motion and sound have not started.
    case picture
    case playing
    /// Out of data; the last picture stays.
    case stalled
    case failed(LiveError)
}

/// Why a live stream did not play.
public enum LiveError: Error, Sendable, Hashable {
    /// The tuner said no: its `X-HDHomeRun-Error` code and sentence. 805 means the TV is busy.
    case refused(code: Int?, message: String)
    case network(String)
    /// Nothing arrived within 5 s.
    case noData
    case unsupported(String)
    /// The channel is copy-protected; neither path can play it.
    case protectedChannel
    /// Plex answered a tune or stream request with an error.
    case server(status: Int, message: String?)
}

extension LiveError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .refused(_, let message): message
        case .network(let detail): "The stream could not be reached (\(detail))"
        case .noData: "The tuner sent nothing"
        case .unsupported(let detail): "This channel can't be played here (\(detail))"
        case .protectedChannel: "Protected channel"
        case .server(let status, let message): message ?? "Plex couldn't tune the channel (\(status))"
        }
    }
}

/// What the live player plays through: the phone reading the tuner (Direct) or a Plex tune (Plex).
@MainActor
public protocol LiveSource: AnyObject {
    var state: LiveState { get }
    /// One line for the player's status label; nil keeps the label hidden.
    var status: String? { get }
    /// The current tune's diagnostics line, once known.
    var diagnosticsLine: String? { get }
    /// Tunes `channel`, replacing whatever played.
    func play(_ channel: LiveChannel) async
    /// Ends the stream and frees the tuner; the last picture stays.
    func stop()
}

/// A channel the server tuned (`POST /livetv/dvrs/{dvr}/channels/{channel}/tune`).
public struct PlexLiveSession: Identifiable, Sendable, Hashable {
    /// `Media.uuid`; the stream is `/livetv/sessions/<id>`.
    public var id: String
    public var channel: LiveChannel
    /// New for every tune; timeline reports carry it.
    public var ratingKey: String
    public var videoCodec: String?
    public var videoHeight: Int?
    public var isInterlaced: Bool
    public var audioCodec: String?
    public var audioChannels: Int?

    public init(
        id: String,
        channel: LiveChannel,
        ratingKey: String,
        videoCodec: String? = nil,
        videoHeight: Int? = nil,
        isInterlaced: Bool = false,
        audioCodec: String? = nil,
        audioChannels: Int? = nil
    ) {
        self.id = id
        self.channel = channel
        self.ratingKey = ratingKey
        self.videoCodec = videoCodec
        self.videoHeight = videoHeight
        self.isInterlaced = isInterlaced
        self.audioCodec = audioCodec
        self.audioChannels = audioChannels
    }

    public var path: String { "/livetv/sessions/\(id)" }

    /// H.264 and HEVC reach the phone as sent; anything else (MPEG-2) the server converts.
    public var phoneDecodesVideo: Bool {
        ["h264", "hevc", "h265"].contains(videoCodec?.lowercased() ?? "")
    }
}

/// One `/:/timeline` report for a live session.
public struct LiveTimelineUpdate: Sendable, Hashable {
    public var session: PlexLiveSession
    public var state: PlaybackState
    /// Milliseconds since the tune.
    public var time: Int
    /// The transcode session the stream belongs to.
    public var transcodeSession: String

    public init(session: PlexLiveSession, state: PlaybackState, time: Int, transcodeSession: String) {
        self.session = session
        self.state = state
        self.time = time
        self.transcodeSession = transcodeSession
    }

    var queryItems: [URLQueryItem] {
        [
            URLQueryItem(name: "key", value: session.path),
            URLQueryItem(name: "ratingKey", value: session.ratingKey),
            URLQueryItem(name: "state", value: state.rawValue),
            URLQueryItem(name: "time", value: String(time)),
            URLQueryItem(name: "duration", value: "0"),
            URLQueryItem(name: "playbackTime", value: String(time)),
            URLQueryItem(name: "context", value: "live-tv.guide"),
        ]
    }
}
