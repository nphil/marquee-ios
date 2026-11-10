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

    /// A separate subtitle file of the title, saved beside the video.
    public struct Subtitle: Hashable, Sendable, Codable {
        public var streamID: Int
        public var fileName: String

        public init(streamID: Int, fileName: String) {
            self.streamID = streamID
            self.fileName = fileName
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
    /// The video's name in the download's folder once complete, such as `media.mkv`.
    public var fileName: String?
    public var subtitles: [Subtitle] = []
    /// Identifies this copy's partial file; absent on downloads saved by older versions.
    public let partialID: UUID?
    public var addedAt: Date
    public var finishedAt: Date?
    public var watch: OfflineWatch

    public init(item: PlexMetadata, scope: DownloadScope, quality: DownloadQuality, mediaIndex: Int, addedAt: Date, expectedLength: Int64? = nil) {
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
        self.mediaIndex = mediaIndex
        phase = .waiting
        self.expectedLength = expectedLength
        partialID = UUID()
        self.addedAt = addedAt
        watch = OfflineWatch(offset: item.viewOffset, watched: item.viewCount > 0)
    }

    /// The share on the iPhone, 0…1; nil before the length is known in any way.
    public var fraction: Double? {
        if phase == .done { return 1 }
        guard let total = length ?? expectedLength, total > 0 else { return nil }
        return min(1, Double(received.byteCount) / Double(total))
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
