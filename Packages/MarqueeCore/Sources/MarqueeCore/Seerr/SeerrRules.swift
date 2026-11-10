import Foundation

/// Where a title or request stands, from refused to in the library.
public enum SeerrBadge: Sendable, Hashable {
    case available, partiallyAvailable, processing, approved, pending, declined, failed, blocklisted

    public var title: String {
        switch self {
        case .available: "Available"
        case .partiallyAvailable: "Partially Available"
        case .processing: "Processing"
        case .approved: "Approved"
        case .pending: "Pending"
        case .declined: "Declined"
        case .failed: "Failed"
        case .blocklisted: "Blocklisted"
        }
    }
}

extension SeerrMedia {
    /// Media status first; a title Seerr holds no status for shows how its latest request ended.
    /// Processing means approved and handed to Radarr or Sonarr; it reads Processing only while one
    /// of them is downloading.
    public func badge(is4K: Bool) -> SeerrBadge? {
        switch status(is4K: is4K) {
        case .available: return .available
        case .partiallyAvailable: return .partiallyAvailable
        case .processing: return (is4K ? isDownloading4K : isDownloading) ? .processing : .approved
        case .pending: return .pending
        case .blocklisted: return .blocklisted
        case .unknown, .deleted:
            switch requests.filter({ $0.is4K == is4K }).max(by: { $0.id < $1.id })?.status {
            case .declined: return .declined
            case .failed: return .failed
            default: return nil
            }
        }
    }

    /// The Plex item to play: one Seerr links on the signed-in server, or else one whose link names no
    /// server, to be checked against its TMDB id. Nil when the title is not in Plex.
    public func plexLink(serverID: String?) -> SeerrPlexLink? {
        let links = [(status, ratingKey, plexServerID), (status4K, ratingKey4K, plexServerID4K)]
            .filter { $0.0 == .available || $0.0 == .partiallyAvailable }
            .compactMap { _, key, server in key.map { (key: $0, server: server) } }
        if let serverID, let link = links.first(where: { $0.server == serverID }) { return .item(ratingKey: link.key) }
        if let link = links.first(where: { $0.server == nil }) { return .unconfirmed(ratingKey: link.key) }
        return nil
    }

    /// The Plex server's machine id from Seerr's links: `server=` in the app link
    /// (`plex://preplay/?metadataKey=…&server=<id>`), or `/server/<id>/` in the web link.
    static func plexServerID(app: String?, web: String?) -> String? {
        if let app, let id = URLComponents(string: app)?.queryItems?.first(where: { $0.name == "server" })?.value, !id.isEmpty {
            return id
        }
        if let web, let range = web.range(of: "/server/") {
            let id = web[range.upperBound...].prefix { $0 != "/" && $0 != "?" && $0 != "#" }
            if !id.isEmpty { return String(id) }
        }
        return nil
    }
}

/// The Plex item a Seerr title is.
public enum SeerrPlexLink: Sendable, Hashable {
    /// Seerr links it on the signed-in server.
    case item(ratingKey: String)
    /// Seerr's link names no server; play it only once the item's TMDB id matches.
    case unconfirmed(ratingKey: String)
}

extension SeerrRequest {
    /// Pending, declined and failed are the request's own; once approved, the media shows how far it
    /// got. Nil when its media has since been removed.
    public var badge: SeerrBadge? {
        switch status {
        case .pending: return .pending
        case .declined: return .declined
        case .failed: return .failed
        case .approved, .completed:
            switch media?.badge(is4K: is4K) {
            case let badge? where badge != .pending && badge != .declined && badge != .failed: return badge
            default: return status == .approved ? .approved : (media?.status(is4K: is4K) == .deleted ? nil : .available)
            }
        }
    }
}

/// A season on a series' title page: requestable, or the badge that says why not.
public struct SeerrSeasonChoice: Sendable, Hashable, Identifiable {
    public var season: SeerrSeason
    public var badge: SeerrBadge?

    public init(season: SeerrSeason, badge: SeerrBadge?) {
        self.season = season
        self.badge = badge
    }

    public var id: Int { season.number }
    public var isRequestable: Bool { badge == nil }
}

extension SeerrDetails {
    /// The seasons a request could include, specials only when Seerr allows them. A season is taken
    /// once it is available, on its way, or in an open request of the same quality.
    public func seasonChoices(is4K: Bool, settings: SeerrServerSettings) -> [SeerrSeasonChoice] {
        let media = title.media
        let open = media?.requests.filter { $0.isActive && $0.is4K == is4K } ?? []
        return seasons.filter { $0.number > 0 || settings.specialEpisodesEnabled }.map { season in
            let status = media?.seasons.first { $0.number == season.number }.map { is4K ? $0.status4K : $0.status }
            let badge: SeerrBadge? = switch status {
            case .available: .available
            case .partiallyAvailable: .partiallyAvailable
            case .processing: .approved
            case .pending: .pending
            default: open.first { $0.seasons.contains(season.number) }.map { $0.status == .pending ? .pending : .approved }
            }
            return SeerrSeasonChoice(season: season, badge: badge)
        }
    }

    /// Whether this account can request the title now, in 4K or not.
    public func canRequest(is4K: Bool, user: SeerrUser, settings: SeerrServerSettings) -> Bool {
        let kind = title.kind
        guard user.permissions.canRequest(kind) else { return false }
        if is4K, !(settings.allows4K(kind) && user.permissions.canRequest4K(kind)) { return false }
        let status = title.media?.status(is4K: is4K) ?? .unknown
        switch kind {
        case .movie:
            return status == .unknown || status == .deleted
        case .tv:
            guard status != .available, status != .blocklisted else { return false }
            return seasonChoices(is4K: is4K, settings: settings).contains(where: \.isRequestable)
        }
    }

    /// The request to send. Without partial requests Seerr takes every open season, so the choice is
    /// ignored.
    public func order(seasons chosen: Set<Int>, is4K: Bool, settings: SeerrServerSettings) -> SeerrOrder {
        guard title.kind == .tv else { return SeerrOrder(kind: .movie, tmdbID: title.tmdbID, is4K: is4K) }
        let open = seasonChoices(is4K: is4K, settings: settings).filter(\.isRequestable).map(\.season.number)
        let seasons = settings.partialRequestsEnabled ? open.filter(chosen.contains) : open
        return SeerrOrder(kind: .tv, tmdbID: title.tmdbID, tvdbID: tvdbID, seasons: seasons, is4K: is4K)
    }

    /// Adding the title to the Plex Watchlist would request it too: Seerr's own watchlist sync for this
    /// account, or Pulsarr when the settings say it runs. Only while nothing has requested it yet.
    public func watchlistAddRequests(user: SeerrUser, pulsarr: Bool) -> Bool {
        guard pulsarr || user.permissions.autoRequestsWatchlist(title.kind) else { return false }
        let status = title.media?.status ?? .unknown
        return status == .unknown || status == .deleted
    }
}

/// TMDB's image server, which Seerr's own pages load from.
public enum TMDBImage {
    private static let widths = [92, 154, 185, 342, 500, 780]

    /// The smallest size at least `pixels` wide, else the original.
    public static func url(_ path: String?, pixels: Double) -> URL? {
        guard let path, path.hasPrefix("/") else { return nil }
        let size = widths.first { Double($0) >= pixels }.map { "w\($0)" } ?? "original"
        return URL(string: "https://image.tmdb.org/t/p/\(size)\(path)")
    }
}
