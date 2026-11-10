import Foundation

/// A TMDB genre as Seerr lists it. `backdropPath` is set only for the cards of Seerr's genre slider.
public struct SeerrGenre: Sendable, Hashable, Identifiable {
    public var id: Int
    public var name: String
    public var backdropPath: String?

    public init(id: Int, name: String, backdropPath: String? = nil) {
        self.id = id
        self.name = name
        self.backdropPath = backdropPath
    }
}

/// A language titles are made in, by ISO 639-1 code.
public struct SeerrLanguage: Sendable, Hashable, Identifiable {
    public var code: String
    public var name: String

    public init(code: String, name: String) {
        self.code = code
        self.name = name
    }

    public var id: String { code }
}

/// A country whose streaming services TMDB lists, by ISO 3166-1 code.
public struct SeerrRegion: Sendable, Hashable, Identifiable {
    public var code: String
    public var name: String

    public init(code: String, name: String) {
        self.code = code
        self.name = name
    }

    public var id: String { code }
}

/// A streaming service in one region.
public struct SeerrWatchProvider: Sendable, Hashable, Identifiable {
    public var id: Int
    public var name: String

    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }
}

/// One page of a Discover list, with how far the list goes.
public struct SeerrTitlePage: Sendable, Hashable {
    public var titles: [SeerrTitle]
    public var page: Int
    public var totalPages: Int

    public init(titles: [SeerrTitle], page: Int, totalPages: Int) {
        self.titles = titles
        self.page = page
        self.totalPages = totalPages
    }

    public var hasMore: Bool { page < totalPages }
}

/// What the browse screen sorts by. Each field starts in the order people want first; `reversed` flips it.
public enum SeerrSort: String, Sendable, Hashable, CaseIterable {
    case popularity, release, rating, title

    public var title: String {
        switch self {
        case .popularity: "Popularity"
        case .release: "Release Date"
        case .rating: "Rating"
        case .title: "Title"
        }
    }

    /// The names of the two orders, the one a new field starts in first.
    public var orders: (first: String, reversed: String) {
        switch self {
        case .popularity: ("Most Popular", "Least Popular")
        case .release: ("Newest First", "Oldest First")
        case .rating: ("Highest First", "Lowest First")
        case .title: ("A–Z", "Z–A")
        }
    }

    /// TMDB's `sortBy` value. Seerr accepts `original_title` and `original_name` for the title sort, so
    /// titles sort by their original-language names.
    func sortBy(for kind: SeerrMediaKind, reversed: Bool) -> String {
        let field: String
        switch self {
        case .popularity: field = "popularity"
        case .release: field = kind == .movie ? "primary_release_date" : "first_air_date"
        case .rating: field = "vote_average"
        case .title: field = kind == .movie ? "original_title" : "original_name"
        }
        let ascending = (self == .title) != reversed
        return "\(field).\(ascending ? "asc" : "desc")"
    }
}

/// A span of release years to browse.
public enum SeerrEra: Sendable, Hashable, CaseIterable {
    case y2020s, y2010s, y2000s, y1990s, y1980s, before1980

    public var title: String {
        switch self {
        case .y2020s: "2020s"
        case .y2010s: "2010s"
        case .y2000s: "2000s"
        case .y1990s: "1990s"
        case .y1980s: "1980s"
        case .before1980: "Before 1980"
        }
    }

    /// The first and last year, either open.
    public var years: (from: Int?, to: Int?) {
        switch self {
        case .y2020s: (2020, 2029)
        case .y2010s: (2010, 2019)
        case .y2000s: (2000, 2009)
        case .y1990s: (1990, 1999)
        case .y1980s: (1980, 1989)
        case .before1980: (nil, 1979)
        }
    }
}

/// How long a movie or an episode runs: one of three bands.
public enum SeerrRuntime: Sendable, Hashable, CaseIterable {
    case short, medium, long

    /// TMDB's runtime filter takes whole minutes of a movie or of one episode.
    public func title(for kind: SeerrMediaKind) -> String {
        switch (self, kind) {
        case (.short, .movie): "Under 90 min"
        case (.medium, .movie): "90–120 min"
        case (.long, .movie): "Over 120 min"
        case (.short, .tv): "Under 30 min"
        case (.medium, .tv): "30–60 min"
        case (.long, .tv): "Over 60 min"
        }
    }

    func minutes(for kind: SeerrMediaKind) -> (min: Int?, max: Int?) {
        switch (self, kind) {
        case (.short, .movie): (nil, 89)
        case (.medium, .movie): (90, 120)
        case (.long, .movie): (121, nil)
        case (.short, .tv): (nil, 29)
        case (.medium, .tv): (30, 60)
        case (.long, .tv): (61, nil)
        }
    }
}

/// A streaming service in a region. TMDB's provider filter needs both.
public struct SeerrStreaming: Sendable, Hashable {
    public var provider: Int
    public var region: String

    public init(provider: Int, region: String) {
        self.provider = provider
        self.region = region
    }
}

/// What the browse screen asks Seerr's discover endpoint for, one page at a time.
public struct SeerrBrowseQuery: Sendable, Hashable {
    public var kind: SeerrMediaKind
    public var genre: Int?
    public var sort = SeerrSort.popularity
    public var reversed = false
    /// Only titles not out yet: released or first aired from today on.
    public var upcoming = false
    public var era: SeerrEra?
    /// An ISO 639-1 code: only titles made in that language.
    public var language: String?
    /// Whole points of TMDB's 10-point score, at least.
    public var minRating: Int?
    public var runtime: SeerrRuntime?
    public var streaming: SeerrStreaming?

    public init(
        kind: SeerrMediaKind, genre: Int? = nil, sort: SeerrSort = .popularity, reversed: Bool = false,
        upcoming: Bool = false, era: SeerrEra? = nil, language: String? = nil, minRating: Int? = nil,
        runtime: SeerrRuntime? = nil, streaming: SeerrStreaming? = nil
    ) {
        self.kind = kind
        self.genre = genre
        self.sort = sort
        self.reversed = reversed
        self.upcoming = upcoming
        self.era = era
        self.language = language
        self.minRating = minRating
        self.runtime = runtime
        self.streaming = streaming
    }

    /// Whether any filter is on; the sort and the genre chips are not filters of the View menu.
    public var hasMenuFilters: Bool {
        upcoming || era != nil || language != nil || minRating != nil || runtime != nil || streaming != nil
    }

    /// A score from a few votes says little, so rating sorts and rating floors ignore titles with fewer.
    static let voteFloor = 100

    var path: String {
        kind == .movie ? "/api/v1/discover/movies" : "/api/v1/discover/tv"
    }

    /// The discover endpoint's parameters for one page. `today` anchors Upcoming.
    func queryItems(page: Int, today: Date = Date()) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "sortBy", value: sort.sortBy(for: kind, reversed: reversed)),
        ]
        func add(_ name: String, _ value: (some CustomStringConvertible)?) {
            if let value { items.append(URLQueryItem(name: name, value: value.description)) }
        }
        add("genre", genre)
        add("language", language)
        // TMDB wants both ends of a date range or none; Seerr fills in the missing one.
        let years = era?.years
        let from = [upcoming ? Self.isoDate(today) : nil, years?.from.map { "\($0)-01-01" }].compactMap { $0 }.max()
        let to = years?.to.map { "\($0)-12-31" }
        let dates = kind == .movie ? ("primaryReleaseDateGte", "primaryReleaseDateLte") : ("firstAirDateGte", "firstAirDateLte")
        add(dates.0, from)
        add(dates.1, to)
        add("voteAverageGte", minRating)
        add("voteCountGte", sort == .rating || minRating != nil ? Self.voteFloor : nil)
        let minutes = runtime?.minutes(for: kind)
        add("withRuntimeGte", minutes?.min)
        add("withRuntimeLte", minutes?.max)
        add("watchRegion", streaming?.region)
        add("watchProviders", streaming?.provider)
        return items
    }

    /// `YYYY-MM-DD` in the device's calendar, which is where "today" is meant.
    static func isoDate(_ date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }
}

/// A list the browse screen can page through.
public enum SeerrFeed: Sendable, Hashable {
    case trending
    case discover(SeerrBrowseQuery)
}

/// A row of the Discover page: a poster shelf, or the genre cards of movies or series.
public enum SeerrDiscoverRow: Sendable, Hashable, Identifiable {
    case shelf(SeerrShelf)
    case genres(SeerrMediaKind)

    /// Seerr's own order: trending, then each kind's popular shelf, genre cards and upcoming shelf.
    public static let all: [SeerrDiscoverRow] = [
        .shelf(.trending),
        .shelf(.popularMovies), .genres(.movie), .shelf(.upcomingMovies),
        .shelf(.popularSeries), .genres(.tv), .shelf(.upcomingSeries),
    ]

    public var id: String {
        switch self {
        case .shelf(let shelf): shelf.id
        case .genres(let kind): "genres.\(kind.rawValue)"
        }
    }

    public var title: String {
        switch self {
        case .shelf(let shelf): shelf.title
        case .genres(let kind): kind == .movie ? "Movie Genres" : "Series Genres"
        }
    }
}
