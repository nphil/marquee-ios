import Foundation

/// Where Seerr answers and how Marquee signs in to it.
public struct SeerrConfig: Sendable, Hashable, Codable {
    public enum Auth: Sendable, Hashable, Codable {
        /// The signed-in Plex profile's token, as Seerr's own "Sign in with Plex" uses.
        case plex
        /// An API key from Seerr's settings; Seerr acts as its owner, usually the admin.
        case apiKey(String)
    }

    public var address: URL
    public var auth: Auth

    public init(address: URL, auth: Auth) {
        self.address = address
        self.auth = auth
    }

    /// Checks what was typed into the settings page. A nil key signs in with Plex.
    public static func parse(address text: String, apiKey: String?) -> Result<SeerrConfig, Problem> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return .failure(.scheme) }
        guard let host = components.host, !host.isEmpty, !host.contains(" "), components.user == nil,
              components.query == nil, components.fragment == nil, let url = components.url else { return .failure(.host) }
        if scheme == "http", !HomeNetwork.contains(host) { return .failure(.plaintext) }
        guard let apiKey else { return .success(SeerrConfig(address: url, auth: .plex)) }
        // Seerr's keys are base64 text of about 68 characters.
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (16...128).contains(key.count), key.allSatisfy({ $0.isASCII && !$0.isWhitespace }) else {
            return .failure(.key)
        }
        return .success(SeerrConfig(address: url, auth: .apiKey(key)))
    }

    public enum Problem: Error, Sendable, Equatable {
        /// Neither https:// nor http://.
        case scheme
        case host
        /// Plain http:// to a host outside the home network.
        case plaintext
        case key
    }
}

public enum SeerrError: Error, Sendable, Equatable {
    case unreachable
    case timedOut
    /// The address answered, but not like Seerr.
    case notSeerr
    /// Seerr refused the API key.
    case badKey
    /// No Plex sign-in to pass on.
    case notSignedIn
    /// Seerr would not let this Plex account in: it has no access to Seerr's Plex server, or new Plex
    /// sign-ins are off in Seerr.
    case plexAccountNotAllowed
    /// Seerr could not check the account with Plex, or Plex sign-in is off in Seerr.
    case plexSignInFailed
    /// The account may not do this.
    case notAllowed
    /// The account has used its request quota.
    case quotaReached
    /// Everything asked for is already requested or available.
    case alreadyRequested
    /// Seerr has no such title.
    case notFound
    /// Seerr answered with an error of its own, such as one from Radarr or Sonarr.
    case failed(message: String?)
}

public enum SeerrMediaKind: String, Sendable, Hashable, Codable {
    case movie, tv
}

/// Seerr's media status: how far a title has got, from requested to in the library.
public enum SeerrMediaStatus: Int, Sendable, Hashable {
    case unknown = 1, pending, processing, partiallyAvailable, available, blocklisted, deleted
}

/// One request's own status, apart from the media it asks for.
public enum SeerrRequestStatus: Int, Sendable, Hashable {
    case pending = 1, approved, declined, failed, completed
}

/// Seerr's permission bits.
public struct SeerrPermissions: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let admin = SeerrPermissions(rawValue: 2)
    public static let request = SeerrPermissions(rawValue: 32)
    public static let request4K = SeerrPermissions(rawValue: 1024)
    public static let request4KMovie = SeerrPermissions(rawValue: 2048)
    public static let request4KTV = SeerrPermissions(rawValue: 4096)
    public static let requestMovie = SeerrPermissions(rawValue: 262_144)
    public static let requestTV = SeerrPermissions(rawValue: 524_288)
    public static let autoRequest = SeerrPermissions(rawValue: 8_388_608)
    public static let autoRequestMovie = SeerrPermissions(rawValue: 16_777_216)
    public static let autoRequestTV = SeerrPermissions(rawValue: 33_554_432)

    /// Seerr's own check: admin passes everything, otherwise any one of `any`.
    func allows(_ any: SeerrPermissions) -> Bool {
        contains(.admin) || !intersection(any).isEmpty
    }

    public func canRequest(_ kind: SeerrMediaKind) -> Bool {
        allows([.request, kind == .movie ? .requestMovie : .requestTV])
    }

    public func canRequest4K(_ kind: SeerrMediaKind) -> Bool {
        allows([.request4K, kind == .movie ? .request4KMovie : .request4KTV])
    }

    /// Seerr requests what this account adds to its Plex Watchlist.
    public func autoRequestsWatchlist(_ kind: SeerrMediaKind) -> Bool {
        allows([.autoRequest, kind == .movie ? .autoRequestMovie : .autoRequestTV])
    }
}

/// The signed-in Seerr account.
public struct SeerrUser: Sendable, Hashable {
    public var id: Int
    public var name: String
    public var permissions: SeerrPermissions

    public init(id: Int, name: String, permissions: SeerrPermissions) {
        self.id = id
        self.name = name
        self.permissions = permissions
    }
}

/// What every Seerr account may read about the server's request options.
public struct SeerrServerSettings: Sendable, Hashable {
    public var movie4KEnabled: Bool
    public var series4KEnabled: Bool
    /// Seasons of a series can be requested one by one; otherwise a request takes every season.
    public var partialRequestsEnabled: Bool
    /// Season 0 (specials) can be requested.
    public var specialEpisodesEnabled: Bool

    public init(movie4KEnabled: Bool = false, series4KEnabled: Bool = false, partialRequestsEnabled: Bool = true,
                specialEpisodesEnabled: Bool = false) {
        self.movie4KEnabled = movie4KEnabled
        self.series4KEnabled = series4KEnabled
        self.partialRequestsEnabled = partialRequestsEnabled
        self.specialEpisodesEnabled = specialEpisodesEnabled
    }

    public func allows4K(_ kind: SeerrMediaKind) -> Bool {
        kind == .movie ? movie4KEnabled : series4KEnabled
    }
}

/// A movie or series as Seerr lists it, with what Seerr knows of it.
public struct SeerrTitle: Sendable, Hashable, Identifiable {
    public var kind: SeerrMediaKind
    public var tmdbID: Int
    public var name: String
    public var year: Int?
    /// TMDB image paths such as `/abc.jpg`.
    public var posterPath: String?
    public var backdropPath: String?
    public var overview: String
    public var media: SeerrMedia?

    public init(kind: SeerrMediaKind, tmdbID: Int, name: String, year: Int? = nil, posterPath: String? = nil,
                backdropPath: String? = nil, overview: String = "", media: SeerrMedia? = nil) {
        self.kind = kind
        self.tmdbID = tmdbID
        self.name = name
        self.year = year
        self.posterPath = posterPath
        self.backdropPath = backdropPath
        self.overview = overview
        self.media = media
    }

    public var id: String { "\(kind.rawValue)/\(tmdbID)" }

    /// The title's badge: in the library, on its way, or refused.
    public var badge: SeerrBadge? { media?.badge(is4K: false) }
}

/// Seerr's record of a title once anyone requested it or Seerr found it in Plex.
public struct SeerrMedia: Sendable, Hashable {
    public struct Season: Sendable, Hashable {
        public var number: Int
        public var status: SeerrMediaStatus
        public var status4K: SeerrMediaStatus

        public init(number: Int, status: SeerrMediaStatus, status4K: SeerrMediaStatus = .unknown) {
            self.number = number
            self.status = status
            self.status4K = status4K
        }
    }

    public var status: SeerrMediaStatus
    public var status4K: SeerrMediaStatus
    /// Radarr or Sonarr is downloading it now.
    public var isDownloading: Bool
    public var isDownloading4K: Bool
    /// The Plex item and the Plex server it is on, as Seerr links them.
    public var ratingKey: String?
    public var ratingKey4K: String?
    public var plexServerID: String?
    public var plexServerID4K: String?
    public var seasons: [Season]
    public var requests: [SeerrRequest]

    public init(status: SeerrMediaStatus, status4K: SeerrMediaStatus = .unknown, isDownloading: Bool = false,
                isDownloading4K: Bool = false, ratingKey: String? = nil, ratingKey4K: String? = nil,
                plexServerID: String? = nil, plexServerID4K: String? = nil, seasons: [Season] = [],
                requests: [SeerrRequest] = []) {
        self.status = status
        self.status4K = status4K
        self.isDownloading = isDownloading
        self.isDownloading4K = isDownloading4K
        self.ratingKey = ratingKey
        self.ratingKey4K = ratingKey4K
        self.plexServerID = plexServerID
        self.plexServerID4K = plexServerID4K
        self.seasons = seasons
        self.requests = requests
    }

    public func status(is4K: Bool) -> SeerrMediaStatus { is4K ? status4K : status }
}

/// One request: what was asked for and how far it got.
public struct SeerrRequest: Sendable, Hashable, Identifiable {
    public var id: Int
    public var status: SeerrRequestStatus
    public var kind: SeerrMediaKind
    public var tmdbID: Int?
    public var is4K: Bool
    /// Requested season numbers; empty for a movie.
    public var seasons: [Int]
    public var requesterName: String?
    public var createdAt: Date?
    /// The requested title's media record, without its own request list.
    public var media: SeerrMedia?

    public init(id: Int, status: SeerrRequestStatus, kind: SeerrMediaKind, tmdbID: Int? = nil, is4K: Bool = false,
                seasons: [Int] = [], requesterName: String? = nil, createdAt: Date? = nil, media: SeerrMedia? = nil) {
        self.id = id
        self.status = status
        self.kind = kind
        self.tmdbID = tmdbID
        self.is4K = is4K
        self.seasons = seasons
        self.requesterName = requesterName
        self.createdAt = createdAt
        self.media = media
    }

    /// Still waiting for approval, or approved and not yet in the library.
    var isActive: Bool { status == .pending || status == .approved }
}

/// A season of a series, as TMDB lists it.
public struct SeerrSeason: Sendable, Hashable, Identifiable {
    public var number: Int
    public var name: String
    public var episodeCount: Int

    public init(number: Int, name: String, episodeCount: Int) {
        self.number = number
        self.name = name
        self.episodeCount = episodeCount
    }

    public var id: Int { number }
}

/// A title page's content.
public struct SeerrDetails: Sendable, Hashable {
    public var title: SeerrTitle
    public var tagline: String?
    public var genres: [String]
    /// Minutes, for a movie.
    public var runtime: Int?
    public var seasons: [SeerrSeason]
    public var tvdbID: Int?

    public init(title: SeerrTitle, tagline: String? = nil, genres: [String] = [], runtime: Int? = nil,
                seasons: [SeerrSeason] = [], tvdbID: Int? = nil) {
        self.title = title
        self.tagline = tagline
        self.genres = genres
        self.runtime = runtime
        self.seasons = seasons
        self.tvdbID = tvdbID
    }
}

/// What the Requests page's Discover shelves list.
public enum SeerrShelf: String, Sendable, Hashable, CaseIterable, Identifiable {
    case trending, popularMovies, popularSeries, upcomingMovies, upcomingSeries

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .trending: "Trending"
        case .popularMovies: "Popular Movies"
        case .popularSeries: "Popular Series"
        case .upcomingMovies: "Upcoming Movies"
        case .upcomingSeries: "Upcoming Series"
        }
    }

    var path: String {
        switch self {
        case .trending: "/api/v1/discover/trending"
        case .popularMovies: "/api/v1/discover/movies"
        case .popularSeries: "/api/v1/discover/tv"
        case .upcomingMovies: "/api/v1/discover/movies/upcoming"
        case .upcomingSeries: "/api/v1/discover/tv/upcoming"
        }
    }

    /// The list its "See all" opens: the same titles, with the browse screen's filters to narrow them.
    public var feed: SeerrFeed {
        switch self {
        case .trending: .trending
        case .popularMovies: .discover(SeerrBrowseQuery(kind: .movie))
        case .popularSeries: .discover(SeerrBrowseQuery(kind: .tv))
        case .upcomingMovies: .discover(SeerrBrowseQuery(kind: .movie, upcoming: true))
        case .upcomingSeries: .discover(SeerrBrowseQuery(kind: .tv, upcoming: true))
        }
    }
}

/// A request to send: a movie, or chosen seasons of a series.
public struct SeerrOrder: Sendable, Hashable {
    public var kind: SeerrMediaKind
    public var tmdbID: Int
    public var tvdbID: Int?
    public var seasons: [Int]
    public var is4K: Bool

    public init(kind: SeerrMediaKind, tmdbID: Int, tvdbID: Int? = nil, seasons: [Int] = [], is4K: Bool = false) {
        self.kind = kind
        self.tmdbID = tmdbID
        self.tvdbID = tvdbID
        self.seasons = seasons
        self.is4K = is4K
    }
}
