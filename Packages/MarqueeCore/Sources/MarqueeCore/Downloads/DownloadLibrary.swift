import Foundation

/// What the Downloads screen lists: what is still on its way, then what is kept, with episodes grouped
/// under their shows.
public struct DownloadLibrary: Sendable, Equatable {
    /// Every download not yet finished, in the order added, which is the order the queue runs them.
    public let unfinished: [DownloadRecord]
    /// Shows with at least one finished episode, the most recently finished first.
    public let shows: [DownloadShow]
    /// Finished movies, and finished episodes that name no show, the most recently finished first.
    public let movies: [DownloadRecord]
    private let groups: [String: DownloadShow]

    public init(_ records: [DownloadRecord]) {
        unfinished = records.filter { $0.phase != .done }
        var byShow: [String: [DownloadRecord]] = [:]
        var loose: [DownloadRecord] = []
        for record in records {
            if let id = record.showID {
                byShow[id, default: []].append(record)
            } else if record.phase == .done {
                loose.append(record)
            }
        }
        groups = byShow.reduce(into: [:]) { $0[$1.key] = DownloadShow(id: $1.key, records: $1.value) }
        shows = groups.values.filter { !$0.finished.isEmpty }.sorted {
            Self.newerFirst(($0.finishedAt, $0.title), ($1.finishedAt, $1.title))
        }
        movies = loose.sorted { Self.newerFirst(($0.finishedAt ?? $0.addedAt, $0.title), ($1.finishedAt ?? $1.addedAt, $1.title)) }
    }

    /// A show's downloads, finished or not; nil once none is left.
    public func show(_ id: String) -> DownloadShow? {
        groups[id]
    }

    private static func newerFirst(_ lhs: (Date, String), _ rhs: (Date, String)) -> Bool {
        lhs.0 != rhs.0 ? lhs.0 > rhs.0 : lhs.1 < rhs.1
    }
}

/// The downloads of one show.
public struct DownloadShow: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    /// Every download of the show, finished or not, by season and episode.
    public let records: [DownloadRecord]

    fileprivate init(id: String, records: [DownloadRecord]) {
        self.id = id
        title = records.lazy.compactMap(\.showTitle).first ?? "Show"
        self.records = records.sorted {
            ($0.seasonIndex ?? .max, $0.episodeIndex ?? .max, $0.title) < ($1.seasonIndex ?? .max, $1.episodeIndex ?? .max, $1.title)
        }
    }

    public var finished: [DownloadRecord] {
        records.filter { $0.phase == .done }
    }

    /// What the finished episodes take.
    public var bytes: Int64 {
        finished.reduce(0) { $0 + ($1.totalBytes ?? 0) }
    }

    /// The record whose folder holds the poster to draw: a finished episode's, else any.
    public var poster: DownloadRecord {
        finished.first ?? records[0]
    }

    /// When the latest episode finished.
    fileprivate var finishedAt: Date {
        finished.map { $0.finishedAt ?? $0.addedAt }.max() ?? .distantPast
    }
}

/// The iPhone's storage in the three parts of the Downloads screen's bar: what downloads take, what
/// everything else takes, and what is free.
public struct StorageUsage: Sendable, Equatable {
    public let total: Int64
    public let free: Int64
    public let downloads: Int64

    public init(total: Int64, free: Int64, downloads: Int64) {
        self.total = max(0, total)
        self.free = min(max(0, free), self.total)
        self.downloads = max(0, downloads)
    }

    /// False when the system did not say how large the storage is.
    public var isKnown: Bool {
        total > 0
    }

    /// What the system and every other app take.
    public var other: Int64 {
        max(0, total - free - downloads)
    }

    /// The bar's segments as shares of the whole, 0…1. Downloads are never drawn larger than the space
    /// in use, which the system's free figure may understate.
    public var downloadsShare: Double {
        isKnown ? Double(min(downloads, total - free)) / Double(total) : 0
    }

    public var otherShare: Double {
        isKnown ? Double(other) / Double(total) : 0
    }

    public var freeShare: Double {
        isKnown ? Double(free) / Double(total) : 0
    }
}
