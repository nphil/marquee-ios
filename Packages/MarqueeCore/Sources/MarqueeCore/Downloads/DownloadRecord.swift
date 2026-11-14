import Foundation

/// Downloads belong to one server and one profile, as resume points and watched states do.
public struct DownloadScope: Hashable, Sendable, Codable {
    public var server: String
    /// The Home profile's uuid; empty for an account without a Home.
    public var profile: String

    public init(server: String, profile: String) {
        self.server = server
        self.profile = profile
    }
}

/// One movie or episode kept on the iPhone, or on its way there.
public struct DownloadRecord: Hashable, Sendable, Codable, Identifiable {
    public enum Phase: Hashable, Sendable, Codable {
        /// Waiting for its turn, the network or Wi-Fi.
        case waiting
        /// The server converts it before the copy can start.
        case converting
        case downloading
        case paused
        case failed(String)
        case done

        /// Still to finish without anyone acting: what the Downloads badge counts.
        public var isActive: Bool {
            switch self {
            case .waiting, .converting, .downloading: true
            case .paused, .failed, .done: false
            }
        }
    }

    /// The server's conversion, from its download queue.
    public struct Conversion: Hashable, Sendable, Codable {
        public var queue: Int
        public var item: Int
        public var target: DownloadTarget
        public var status: PlexDownloadQueueItem.Status
        /// The share converted, 0…1, while the server reports one.
        public var progress: Double?
        /// As a multiple of real time.
        public var speed: Double?

        public init(queue: Int, item: Int, target: DownloadTarget, status: PlexDownloadQueueItem.Status = .deciding) {
            self.queue = queue
            self.item = item
            self.target = target
            self.status = status
        }
    }

    /// A conversion the server streams while it converts, saved one segment at a time into the part
    /// file (`StreamedFile`).
    public struct Stream: Hashable, Sendable, Codable {
        /// The server's transcode session; a new one replaces it once the server has dropped it.
        public var session: String
        /// Seconds of the title saved, from its start.
        public var saved: Double = 0
        /// Segments appended, and the part file's length after them.
        public var pieces = 0
        public var bytes: Int64 = 0
        /// The latest frame times saved, which a new session's segments must follow.
        public var timestamps = TransportStream.Timestamps()
        /// A new session began: its segments are trimmed until video and audio follow on.
        public var joining = false
        /// Sessions begun in a row without a segment saved.
        public var restarts = 0
        /// Where the session's playlist ends, seconds from the title's start.
        public var end: Double?

        public init(session: String) {
            self.session = session
        }

        /// Every segment is saved; the hundredth of a second matches `HLSPlaylist.next(after:in:)`.
        public var isComplete: Bool {
            end.map { saved + 0.01 >= $0 } ?? false
        }
    }

    /// A separate subtitle file of the title, saved beside the video.
    public struct Subtitle: Hashable, Sendable, Codable {
        public var streamID: Int
        public var fileName: String

        public init(streamID: Int, fileName: String) {
            self.streamID = streamID
            self.fileName = fileName
        }
    }

    /// The picture's size in pixels: the conversion's target, or the version's own.
    public struct Frame: Hashable, Sendable, Codable {
        public var width: Int
        public var height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }

        /// The target's frame for a conversion; for the original, nil when the server did not say how
        /// large it is.
        public init?(media: PlexMedia, target: DownloadTarget?) {
            if let target {
                self.init(width: target.width, height: target.height)
                return
            }
            let video = media.parts.first?.videoStream
            guard let width = media.width ?? video?.width, let height = media.height ?? video?.height, width > 0, height > 0 else {
                return nil
            }
            self.init(width: width, height: height)
        }
    }

    public var id: String { ratingKey }
    public var scope: DownloadScope
    public var ratingKey: String
    public var type: PlexMediaType
    public var title: String
    public var showTitle: String?
    public var showRatingKey: String?
    public var seasonRatingKey: String?
    public var seasonIndex: Int?
    public var episodeIndex: Int?
    public var year: Int?
    /// The poster: the movie's, or for an episode its show's.
    public var thumb: String?
    /// Milliseconds.
    public var duration: Int
    public var quality: DownloadQuality
    public var mediaIndex: Int
    public var phase: Phase
    /// The file's length once the server has said it.
    public var length: Int64?
    /// What the file should come to before the server says: the version's size, or the estimate of a
    /// conversion.
    public var expectedLength: Int64?
    public var received = ByteSpans()
    public var conversion: Conversion?
    /// What a converted download asks the server for; absent on conversions saved by older versions,
    /// which kept it in `conversion`.
    public var target: DownloadTarget?
    /// Set while the server streams the conversion; the download queue's `conversion` is the fallback.
    public var stream: Stream?
    /// The server would not stream the conversion, so the download queue makes it.
    public var streamFailed: Bool?
    /// The video's name in the download's folder once complete, such as `media.mkv`.
    public var fileName: String?
    public var subtitles: [Subtitle] = []
    /// Identifies this copy's partial file; absent on downloads saved by older versions.
    public let partialID: UUID?
    public var addedAt: Date
    public var finishedAt: Date?
    public var watch: OfflineWatch
    /// The picture's size; absent on downloads saved by older versions until the screen reads it from
    /// the saved description.
    public var frame: Frame?

    public init(
        item: PlexMetadata, scope: DownloadScope, quality: DownloadQuality, target: DownloadTarget? = nil, mediaIndex: Int,
        addedAt: Date, expectedLength: Int64? = nil
    ) {
        self.scope = scope
        ratingKey = item.ratingKey
        type = item.type
        title = item.title
        showTitle = item.grandparentTitle
        showRatingKey = item.grandparentRatingKey
        seasonRatingKey = item.parentRatingKey
        seasonIndex = item.parentIndex
        episodeIndex = item.index
        year = item.year
        thumb = item.type == .episode ? item.grandparentThumb ?? item.thumb : item.thumb
        duration = item.duration
        self.quality = quality
        self.target = target
        self.mediaIndex = mediaIndex
        phase = .waiting
        self.expectedLength = expectedLength
        partialID = UUID()
        self.addedAt = addedAt
        watch = OfflineWatch(offset: item.viewOffset, watched: item.viewCount > 0)
        frame = item.media.indices.contains(mediaIndex) ? Frame(media: item.media[mediaIndex], target: target) : nil
    }

    /// The share on the iPhone, 0…1; nil before the length is known in any way. A streamed conversion
    /// counts the running time saved, which is its conversion and its download at once.
    public var fraction: Double? {
        if phase == .done { return 1 }
        if let stream, duration > 0 { return min(1, stream.saved * 1000 / Double(duration)) }
        guard let total = length ?? expectedLength, total > 0 else { return nil }
        return min(1, Double(received.byteCount) / Double(total))
    }

    /// "1080p", "4K": the picture's size as a person names it; nil until it is known.
    public var resolution: String? {
        frame.map { FormatBadge.resolution(width: $0.width).rawValue }
    }

    /// What the download comes to: the file once it is finished, else the length the server gave or the
    /// estimate.
    public var totalBytes: Int64? {
        length ?? expectedLength
    }

    /// What groups an episode under its show: the show's rating key, else its name. Nil for a movie, and
    /// for an episode that names no show.
    public var showID: String? {
        type == .episode ? showRatingKey ?? showTitle : nil
    }

    /// "S1 E5", "E5" without a season; nil without an episode number.
    public var seasonEpisode: String? {
        guard let episodeIndex else { return nil }
        return seasonIndex.map { "S\($0) E\(episodeIndex)" } ?? "E\(episodeIndex)"
    }

    /// How far into the title the viewer left it, 0…1; nil without a resume point.
    public var watchedFraction: Double? {
        guard watch.offset > 0, duration > 0 else { return nil }
        return min(1, Double(watch.offset) / Double(duration))
    }

    /// The server artwork worth keeping as the title's still: an episode's own picture, else its show's
    /// backdrop; a movie's backdrop. A poster is no still, so a movie without a backdrop has none.
    public static func stillPath(of item: PlexMetadata) -> String? {
        let path = item.type == .episode ? item.thumb ?? item.grandparentArt : item.art
        return path?.isEmpty == false ? path : nil
    }

    /// A finished download Auto-delete takes away: finished on this iPhone, and not the one playing.
    /// `watch.watched` alone may be Plex's own count from before the download, which says nothing
    /// about this copy.
    public func isSpent(autoDeleteWatched: Bool, playing: String?) -> Bool {
        autoDeleteWatched && phase == .done && watch.finishedHere && playing != ratingKey
    }
}

/// Where a downloaded title was left and whether it was finished, kept on the iPhone until Plex has it.
public struct OfflineWatch: Hashable, Sendable, Codable {
    /// Milliseconds.
    public var offset: Int
    public var watched: Bool
    /// When the iPhone last changed it without Plex hearing; nil when Plex has it.
    public var unsynced: Date?
    /// Finished on the iPhone since Plex last heard. Kept apart from `watched`, which may be Plex's own:
    /// every scrobble counts one more viewing.
    public var finishedUnsynced = false
    /// Finished on this iPhone since the download began; absent in indexes saved by older versions.
    public var finishedHere = false

    private enum CodingKeys: String, CodingKey { case offset, watched, unsynced, finishedUnsynced, finishedHere }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        offset = try values.decode(Int.self, forKey: .offset)
        watched = try values.decode(Bool.self, forKey: .watched)
        unsynced = try values.decodeIfPresent(Date.self, forKey: .unsynced)
        finishedUnsynced = try values.decodeIfPresent(Bool.self, forKey: .finishedUnsynced) ?? false
        finishedHere = try values.decodeIfPresent(Bool.self, forKey: .finishedHere) ?? false
    }

    public init(offset: Int = 0, watched: Bool = false) {
        self.offset = offset
        self.watched = watched
    }

    public mutating func played(to offset: Int, at date: Date) {
        self.offset = offset
        unsynced = date
    }

    /// Finishing starts the next viewing from the beginning, as Plex does. `told`: Plex took the
    /// scrobble already.
    public mutating func finished(at date: Date, told: Bool) {
        watched = true
        finishedHere = true
        offset = 0
        if told {
            unsynced = nil
            finishedUnsynced = false
        } else {
            unsynced = date
            finishedUnsynced = true
        }
    }

    public mutating func synced() {
        unsynced = nil
        finishedUnsynced = false
    }

    /// What to tell Plex, in order, given when it last saw the title played anywhere: nothing when it
    /// has heard everything, or when a later viewing elsewhere has already moved it on.
    public func sync(serverLastViewed: Date?) -> [OfflineSync] {
        guard let unsynced else { return [] }
        if let serverLastViewed, serverLastViewed > unsynced { return [] }
        return (finishedUnsynced ? [.watched] : []) + (offset > 0 ? [.resume(at: offset)] : [])
    }
}

public enum OfflineSync: Hashable, Sendable {
    case watched
    /// Milliseconds.
    case resume(at: Int)
}
