import Foundation

// Plex JSON shapes. Every attribute is optional on the wire; counts and offsets default to 0 and lists to
// empty, while values whose absence means something (season 0 is Specials) stay optional.

/// `{"MediaContainer": {...}}`, the envelope of every Plex server answer.
struct PlexEnvelope: Decodable {
    let container: PlexMediaContainer

    enum CodingKeys: String, CodingKey { case container = "MediaContainer" }
}

public struct PlexMediaContainer: Sendable, Decodable {
    public var size: Int
    /// Total items behind a paged request.
    public var totalSize: Int?
    public var offset: Int?
    public var machineIdentifier: String?
    /// On the server root (`/`): the owner lets media be deleted from the apps.
    public var allowMediaDeletion: Bool
    /// On the server root (`/`): the owner has Plex Pass.
    public var myPlexSubscription: Bool
    public var metadata: [PlexMetadata]
    public var hubs: [PlexHub]
    public var directories: [PlexDirectory]
    public var playQueueID: Int?
    public var playQueueSelectedItemID: Int?
    public var playQueueSelectedItemOffset: Int?
    public var playQueueTotalCount: Int?
    public var playQueueVersion: Int?

    enum CodingKeys: String, CodingKey {
        case size, totalSize, offset, machineIdentifier, allowMediaDeletion, myPlexSubscription
        case metadata = "Metadata", hubs = "Hub", directories = "Directory"
        case playQueueID, playQueueSelectedItemID, playQueueSelectedItemOffset, playQueueTotalCount, playQueueVersion
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        size = c.int(.size) ?? 0
        totalSize = c.int(.totalSize)
        offset = c.int(.offset)
        machineIdentifier = c.string(.machineIdentifier)
        allowMediaDeletion = c.bool(.allowMediaDeletion) ?? false
        myPlexSubscription = c.bool(.myPlexSubscription) ?? false
        metadata = c.list(.metadata)
        hubs = c.list(.hubs)
        directories = c.list(.directories)
        playQueueID = c.int(.playQueueID)
        playQueueSelectedItemID = c.int(.playQueueSelectedItemID)
        playQueueSelectedItemOffset = c.int(.playQueueSelectedItemOffset)
        playQueueTotalCount = c.int(.playQueueTotalCount)
        playQueueVersion = c.int(.playQueueVersion)
    }
}

public enum PlexMediaType: String, Sendable, Hashable, Codable {
    case movie, show, season, episode, collection, clip, playlist, unknown

    /// Plex's numeric type code, used by `type=` filters.
    public var code: Int? {
        switch self {
        case .movie: 1
        case .show: 2
        case .season: 3
        case .episode: 4
        case .collection: 18
        case .clip, .playlist, .unknown: nil
        }
    }

    init(plex value: String?) {
        self = value.flatMap(PlexMediaType.init(rawValue:)) ?? .unknown
    }
}

/// A movie, show, season, episode or collection.
public struct PlexMetadata: Sendable, Hashable, Identifiable, Decodable {
    public var id: String { ratingKey }
    public var ratingKey: String
    /// Path of the item, or of its children for shows and seasons.
    public var key: String
    public var guid: String?
    public var type: PlexMediaType
    /// What a collection holds (`movie` or `show`), or an extra's kind (`trailer`).
    public var subtype: String?
    /// An extra's kind as a number: 1 trailer, 2 deleted scene, 3 interview, 5 behind the scenes, 6 scene,
    /// 10 featurette, 11 short.
    public var extraType: Int?
    /// The main trailer's key, "/library/metadata/1073", on a title that has one.
    public var primaryExtraKey: String?
    public var title: String
    public var titleSort: String?
    public var originalTitle: String?
    public var summary: String
    public var tagline: String?
    public var year: Int?
    /// Episode number, or season number for a season.
    public var index: Int?
    /// Season number of an episode; 0 is Specials.
    public var parentIndex: Int?
    public var parentRatingKey: String?
    /// The catalogue guid of an episode's season or a season's show, on a server that sends it.
    public var parentGuid: String?
    public var parentTitle: String?
    public var grandparentRatingKey: String?
    /// The catalogue guid of an episode's show, on a server that sends it.
    public var grandparentGuid: String?
    public var grandparentTitle: String?
    public var thumb: String?
    public var art: String?
    public var parentThumb: String?
    public var grandparentThumb: String?
    public var grandparentArt: String?
    /// Milliseconds; 0 when unknown.
    public var duration: Int
    /// Resume point in milliseconds; 0 when not started.
    public var viewOffset: Int
    /// 0 when unwatched.
    public var viewCount: Int
    /// Episodes in a show or season.
    public var leafCount: Int?
    public var viewedLeafCount: Int?
    public var childCount: Int?
    public var addedAt: Date?
    public var lastViewedAt: Date?
    /// Release date as Plex writes it, `yyyy-MM-dd`.
    public var originallyAvailableAt: String?
    public var contentRating: String?
    public var studio: String?
    public var rating: Double?
    public var audienceRating: Double?
    public var librarySectionID: Int?
    public var librarySectionTitle: String?
    /// Set on items inside a play queue.
    public var playQueueItemID: Int?
    public var media: [PlexMedia]
    public var markers: [PlexMarker]
    public var chapters: [PlexChapter]
    public var roles: [PlexRole]
    public var genres: [String]
    public var directors: [String]
    public var writers: [String]
    public var images: [PlexImage]
    /// The episode to play next, on a show read with `PlexLibrary.metadata(_:)`.
    public var onDeck: PlexMetadata? { onDeckItems.first }
    /// An array, because a struct cannot hold an optional of itself.
    private var onDeckItems: [PlexMetadata]

    enum CodingKeys: String, CodingKey {
        case ratingKey, key, guid, type, subtype, extraType, primaryExtraKey, title, titleSort, originalTitle, summary, tagline, year
        case index, parentIndex
        case parentRatingKey, parentGuid, parentTitle, grandparentRatingKey, grandparentGuid, grandparentTitle
        case thumb, art, parentThumb, grandparentThumb, grandparentArt
        case duration, viewOffset, viewCount, leafCount, viewedLeafCount, childCount
        case addedAt, lastViewedAt, originallyAvailableAt, contentRating, studio, rating, audienceRating
        case librarySectionID, librarySectionTitle, playQueueItemID
        case media = "Media", markers = "Marker", chapters = "Chapter", roles = "Role"
        case genres = "Genre", directors = "Director", writers = "Writer", images = "Image", onDeck = "OnDeck"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ratingKey = c.string(.ratingKey) ?? ""
        key = c.string(.key) ?? ""
        guid = c.string(.guid)
        type = PlexMediaType(plex: c.string(.type))
        subtype = c.string(.subtype)
        extraType = c.int(.extraType)
        primaryExtraKey = c.string(.primaryExtraKey)
        title = c.string(.title) ?? ""
        titleSort = c.string(.titleSort)
        originalTitle = c.string(.originalTitle)
        summary = c.string(.summary) ?? ""
        tagline = c.string(.tagline)
        year = c.int(.year)
        index = c.int(.index)
        parentIndex = c.int(.parentIndex)
        parentRatingKey = c.string(.parentRatingKey)
        parentGuid = c.string(.parentGuid)
        parentTitle = c.string(.parentTitle)
        grandparentRatingKey = c.string(.grandparentRatingKey)
        grandparentGuid = c.string(.grandparentGuid)
        grandparentTitle = c.string(.grandparentTitle)
        thumb = c.string(.thumb)
        art = c.string(.art)
        parentThumb = c.string(.parentThumb)
        grandparentThumb = c.string(.grandparentThumb)
        grandparentArt = c.string(.grandparentArt)
        duration = c.int(.duration) ?? 0
        viewOffset = c.int(.viewOffset) ?? 0
        viewCount = c.int(.viewCount) ?? 0
        leafCount = c.int(.leafCount)
        viewedLeafCount = c.int(.viewedLeafCount)
        childCount = c.int(.childCount)
        addedAt = c.date(.addedAt)
        lastViewedAt = c.date(.lastViewedAt)
        originallyAvailableAt = c.string(.originallyAvailableAt)
        contentRating = c.string(.contentRating)
        studio = c.string(.studio)
        rating = c.double(.rating)
        audienceRating = c.double(.audienceRating)
        librarySectionID = c.int(.librarySectionID)
        librarySectionTitle = c.string(.librarySectionTitle)
        playQueueItemID = c.int(.playQueueItemID)
        media = c.list(.media)
        markers = c.list(.markers)
        chapters = c.list(.chapters)
        roles = c.list(.roles)
        genres = c.tags(.genres)
        directors = c.tags(.directors)
        writers = c.tags(.writers)
        images = c.list(.images)
        onDeckItems = (try? c.decodeIfPresent(OnDeck.self, forKey: .onDeck))?.items ?? []
    }

    /// Watched: a played movie or episode, or a show or season with no episode left to watch.
    public var isWatched: Bool {
        if let leafCount, leafCount > 0 { return (viewedLeafCount ?? 0) >= leafCount }
        return viewCount > 0
    }

    /// Episodes left to watch in a show or season.
    public var unwatchedLeafCount: Int? {
        leafCount.map { max(0, $0 - (viewedLeafCount ?? 0)) }
    }

    /// The show this item belongs to: itself for a show, the parent for a season, the grandparent for an episode.
    public var showRatingKey: String? {
        switch type {
        case .show: ratingKey
        case .season: parentRatingKey
        case .episode: grandparentRatingKey
        default: nil
        }
    }

    /// Markers of one kind in playback order; Plex sends them unsorted.
    public func markers(_ kind: PlexMarker.Kind) -> [PlexMarker] {
        markers.filter { $0.kind == kind }.sorted { $0.start < $1.start }
    }
}

/// `"OnDeck": {"Metadata": {...}}`: one episode, sent as an object rather than a list.
private struct OnDeck: Decodable {
    let items: [PlexMetadata]

    enum CodingKeys: String, CodingKey { case metadata = "Metadata" }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let item = try? c.decode(PlexMetadata.self, forKey: .metadata) {
            items = [item]
        } else {
            items = c.list(.metadata)
        }
    }
}

/// One version of an item: a file with its container and codecs.
public struct PlexMedia: Sendable, Hashable, Identifiable, Decodable {
    public var id: Int
    public var duration: Int
    /// Kilobits per second.
    public var bitrate: Int?
    public var width: Int?
    public var height: Int?
    public var aspectRatio: Double?
    public var audioChannels: Int?
    public var audioCodec: String?
    public var videoCodec: String?
    /// `"1080"`, `"4k"`, `"sd"`.
    public var videoResolution: String?
    public var container: String?
    public var videoFrameRate: String?
    public var videoProfile: String?
    public var parts: [PlexPart]

    enum CodingKeys: String, CodingKey {
        case id, duration, bitrate, width, height, aspectRatio, audioChannels, audioCodec, videoCodec
        case videoResolution, container, videoFrameRate, videoProfile
        case parts = "Part"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.int(.id) ?? 0
        duration = c.int(.duration) ?? 0
        bitrate = c.int(.bitrate)
        width = c.int(.width)
        height = c.int(.height)
        aspectRatio = c.double(.aspectRatio)
        audioChannels = c.int(.audioChannels)
        audioCodec = c.string(.audioCodec)
        videoCodec = c.string(.videoCodec)
        videoResolution = c.string(.videoResolution)
        container = c.string(.container)
        videoFrameRate = c.string(.videoFrameRate)
        videoProfile = c.string(.videoProfile)
        parts = c.list(.parts)
    }
}

/// One file of a media version. Streams are only listed on an item's detail request.
public struct PlexPart: Sendable, Hashable, Identifiable, Decodable {
    public var id: Int
    /// Download path, e.g. `/library/parts/12/1699999999/file.mkv`.
    public var key: String
    public var duration: Int
    /// Path on the server, for display only.
    public var file: String?
    public var size: Int?
    public var container: String?
    public var streams: [PlexStream]
    /// The server made scene thumbnails for the scrubber (`indexes` lists `sd`).
    public var hasSceneThumbnails: Bool

    enum CodingKeys: String, CodingKey {
        case id, key, duration, file, size, container, indexes
        case streams = "Stream"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.int(.id) ?? 0
        key = c.string(.key) ?? ""
        duration = c.int(.duration) ?? 0
        file = c.string(.file)
        size = c.int(.size)
        container = c.string(.container)
        streams = c.list(.streams)
        hasSceneThumbnails = c.string(.indexes)?.split(separator: ",").contains("sd") ?? false
    }

    public var videoStream: PlexStream? { streams.first { $0.kind == .video } }
}

/// A video, audio or subtitle stream of a part, embedded or (for subtitles) a separate file.
public struct PlexStream: Sendable, Hashable, Identifiable, Decodable {
    public enum Kind: Int, Sendable, Hashable {
        case unknown = 0, video = 1, audio = 2, subtitle = 3, lyrics = 4
    }

    public var id: Int
    public var kind: Kind
    /// Position inside the file; nil for a separate subtitle file.
    public var index: Int?
    /// Download path of a separate subtitle file, e.g. `/library/streams/389`.
    public var key: String?
    public var codec: String?
    /// Subtitle format: `srt`, `ass`, `pgs`.
    public var format: String?
    public var language: String?
    /// ISO 639-2, e.g. `eng`.
    public var languageCode: String?
    /// BCP 47, e.g. `en-GB`.
    public var languageTag: String?
    public var title: String?
    public var displayTitle: String?
    public var extendedDisplayTitle: String?
    public var isDefault: Bool
    /// The stream Plex selected for this user and item.
    public var isSelected: Bool
    public var isForced: Bool
    public var isHearingImpaired: Bool
    /// An audio-description track.
    public var isVisualImpaired: Bool
    /// Closed captions carried inside the video stream (CEA-608/708).
    public var isEmbeddedInVideo: Bool
    /// An audio track the server has analysed for loudness, so Boost dialog and Normalize loudness can
    /// work on it (PMS 1.43.4 and later).
    public var canNormalizeLoudness: Bool
    public var channels: Int?
    public var audioChannelLayout: String?
    public var samplingRate: Int?
    /// Kilobits per second.
    public var bitrate: Int?
    public var profile: String?
    /// H.264 writes 41 for level 4.1; HEVC writes general_level_idc, 153 for level 5.1.
    public var level: Int?
    public var bitDepth: Int?
    public var chromaSubsampling: String?
    public var colorPrimaries: String?
    public var colorTrc: String?
    public var colorSpace: String?
    public var frameRate: Double?
    public var width: Int?
    public var height: Int?
    public var dolbyVision: DolbyVision?

    public struct DolbyVision: Sendable, Hashable {
        public var profile: Int
        public var level: Int?
        /// Base-layer compatibility: 1 HDR10, 2 SDR, 4 HLG, 6 HDR10 (profile 7), 0 none.
        public var baseLayerCompatibility: Int?
        public var hasEnhancementLayer: Bool
    }

    enum CodingKeys: String, CodingKey {
        case id, streamType, index, key, codec, format, language, languageCode, languageTag
        case title, displayTitle, extendedDisplayTitle
        case isDefault = "default", selected, forced, hearingImpaired, visualImpaired, embeddedInVideo, canNormalizeLoudness
        case channels, audioChannelLayout, samplingRate, bitrate, profile, level, bitDepth, chromaSubsampling
        case colorPrimaries, colorTrc, colorSpace, frameRate, width, height
        case doviPresent = "DOVIPresent", doviProfile = "DOVIProfile", doviLevel = "DOVILevel"
        case doviCompatibility = "DOVIBLCompatID", doviEnhancement = "DOVIELPresent"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.int(.id) ?? 0
        kind = Kind(rawValue: c.int(.streamType) ?? 0) ?? .unknown
        index = c.int(.index)
        key = c.string(.key).flatMap { $0.isEmpty ? nil : $0 }
        codec = c.string(.codec)?.lowercased()
        format = c.string(.format)?.lowercased()
        language = c.string(.language)
        languageCode = c.string(.languageCode)
        languageTag = c.string(.languageTag)
        title = c.string(.title)
        displayTitle = c.string(.displayTitle)
        extendedDisplayTitle = c.string(.extendedDisplayTitle)
        isDefault = c.bool(.isDefault) ?? false
        isSelected = c.bool(.selected) ?? false
        isForced = c.bool(.forced) ?? false
        isHearingImpaired = c.bool(.hearingImpaired) ?? false
        isVisualImpaired = c.bool(.visualImpaired) ?? false
        isEmbeddedInVideo = c.bool(.embeddedInVideo) ?? false
        canNormalizeLoudness = c.bool(.canNormalizeLoudness) ?? false
        channels = c.int(.channels)
        audioChannelLayout = c.string(.audioChannelLayout)
        samplingRate = c.int(.samplingRate)
        bitrate = c.int(.bitrate)
        profile = c.string(.profile)?.lowercased()
        level = c.int(.level)
        bitDepth = c.int(.bitDepth)
        chromaSubsampling = c.string(.chromaSubsampling)
        colorPrimaries = c.string(.colorPrimaries)
        colorTrc = c.string(.colorTrc)?.lowercased()
        colorSpace = c.string(.colorSpace)
        frameRate = c.double(.frameRate)
        width = c.int(.width)
        height = c.int(.height)
        if c.bool(.doviPresent) == true, let profile = c.int(.doviProfile) {
            dolbyVision = DolbyVision(
                profile: profile,
                level: c.int(.doviLevel),
                baseLayerCompatibility: c.int(.doviCompatibility),
                hasEnhancementLayer: c.bool(.doviEnhancement) ?? false
            )
        }
    }

    /// A subtitle in its own file next to the video.
    public var isExternal: Bool { key != nil }
}

public struct PlexMarker: Sendable, Hashable, Decodable {
    public enum Kind: Sendable, Hashable {
        case intro, credits, commercial, other(String)
    }

    public var kind: Kind
    /// Milliseconds.
    public var start: Int
    public var end: Int
    /// The last credits of the item. Its end is the container length, so it runs to the end of playback.
    public var isFinal: Bool

    enum CodingKeys: String, CodingKey {
        case type, startTimeOffset, endTimeOffset, final
    }

    public init(kind: Kind, start: Int, end: Int, isFinal: Bool = false) {
        self.kind = kind
        self.start = start
        self.end = end
        self.isFinal = isFinal
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = switch c.string(.type) ?? "" {
        case "intro": .intro
        case "credits": .credits
        case "commercial": .commercial
        case let other: .other(other)
        }
        start = c.int(.startTimeOffset) ?? 0
        end = c.int(.endTimeOffset) ?? 0
        isFinal = c.bool(.final) ?? false
    }

    /// Whether `time` (milliseconds) falls inside the marker; final credits are open-ended.
    public func contains(_ time: Int) -> Bool {
        time >= start && (isFinal || time < end)
    }
}

public struct PlexChapter: Sendable, Hashable, Decodable {
    public var title: String?
    public var index: Int?
    /// Milliseconds.
    public var start: Int
    public var end: Int
    public var thumb: String?

    enum CodingKeys: String, CodingKey {
        case tag, index, startTimeOffset, endTimeOffset, thumb
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.string(.tag)
        index = c.int(.index)
        start = c.int(.startTimeOffset) ?? 0
        end = c.int(.endTimeOffset) ?? 0
        thumb = c.string(.thumb)
    }
}

/// A cast member.
public struct PlexRole: Sendable, Hashable, Decodable {
    /// The person's id, for `PlexLibrary.titles(ofPerson:)`; nil on trimmed lists such as search rows.
    public var id: String?
    public var name: String
    public var character: String?
    public var thumb: String?

    enum CodingKeys: String, CodingKey {
        case id, tag, role, thumb
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.string(.id)
        name = c.string(.tag) ?? ""
        character = c.string(.role)
        thumb = c.string(.thumb)
    }
}

/// Artwork beyond `thumb` and `art`, e.g. the clear logo.
public struct PlexImage: Sendable, Hashable, Decodable {
    /// `coverPoster`, `background`, `snapshot`, `clearLogo`.
    public var type: String
    public var url: String

    enum CodingKeys: String, CodingKey {
        case type, url
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = c.string(.type) ?? ""
        url = c.string(.url) ?? ""
    }
}

/// A row of items: Continue Watching, Recently Added, a search group.
public struct PlexHub: Sendable, Hashable, Identifiable, Decodable {
    public var id: String { identifier.isEmpty ? key ?? title : identifier }
    public var identifier: String
    public var key: String?
    public var title: String
    /// Item type of the row: `movie`, `show`, `episode`, `mixed`, `actor`.
    public var type: String?
    /// `hero` marks the Continue Watching row.
    public var style: String?
    public var size: Int
    /// More items exist behind `key`.
    public var more: Bool
    public var items: [PlexMetadata]
    /// People in a search group.
    public var directories: [PlexDirectory]

    enum CodingKeys: String, CodingKey {
        case hubIdentifier, key, title, type, style, size, more
        case items = "Metadata", directories = "Directory"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        identifier = c.string(.hubIdentifier) ?? ""
        key = c.string(.key)
        title = c.string(.title) ?? ""
        type = c.string(.type)
        style = c.string(.style)
        size = c.int(.size) ?? 0
        more = c.bool(.more) ?? false
        items = c.list(.items)
        directories = c.list(.directories)
    }
}

/// A directory entry: a library section, a first-character bucket, a person in search.
public struct PlexDirectory: Sendable, Hashable, Decodable {
    public var key: String
    public var title: String
    /// Name of a person or tag.
    public var tag: String?
    /// A person's or tag's id, e.g. for `PlexLibrary.titles(ofPerson:)`.
    public var id: String?
    /// `movie`, `show`.
    public var type: String?
    /// Items behind the entry, e.g. titles starting with the letter.
    public var size: Int
    public var thumb: String?
    public var art: String?
    public var uuid: String?

    enum CodingKeys: String, CodingKey {
        case key, title, tag, id, type, size, thumb, art, uuid
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = c.string(.key) ?? ""
        title = c.string(.title) ?? ""
        tag = c.string(.tag)
        id = c.string(.id)
        type = c.string(.type)
        size = c.int(.size) ?? 0
        thumb = c.string(.thumb)
        art = c.string(.art)
        uuid = c.string(.uuid)
    }
}

/// A movie or TV library on the server.
public struct PlexLibrarySection: Sendable, Hashable, Identifiable {
    public var id: String { key }
    public var key: String
    public var title: String
    public var type: PlexMediaType
    public var uuid: String?
    public var thumb: String?
    public var art: String?

    public init(key: String, title: String, type: PlexMediaType, uuid: String? = nil, thumb: String? = nil, art: String? = nil) {
        self.key = key
        self.title = title
        self.type = type
        self.uuid = uuid
        self.thumb = thumb
        self.art = art
    }

    init(_ directory: PlexDirectory) {
        self.init(
            key: directory.key,
            title: directory.title,
            type: PlexMediaType(plex: directory.type),
            uuid: directory.uuid,
            thumb: directory.thumb,
            art: directory.art
        )
    }
}
