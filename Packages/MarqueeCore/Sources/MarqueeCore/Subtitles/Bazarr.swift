import Foundation

/// Where Bazarr answers and the API key it accepts.
public struct BazarrConfig: Sendable, Hashable, Codable {
    public var address: URL
    public var apiKey: String

    public init(address: URL, apiKey: String) {
        self.address = address
        self.apiKey = apiKey
    }

    /// Checks what was typed into the settings page. The address keeps any base path (`/bazarr`).
    public static func parse(address text: String, key: String) -> Result<BazarrConfig, Problem> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return .failure(.scheme) }
        guard let host = components.host, !host.isEmpty, !host.contains(" "), components.user == nil,
              components.query == nil, components.fragment == nil, let url = components.url else { return .failure(.host) }
        if scheme == "http", !isHomeNetwork(host) { return .failure(.plaintext) }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (16...64).contains(key.count), key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            return .failure(.key)
        }
        return .success(BazarrConfig(address: url, apiKey: key))
    }

    public enum Problem: Error, Sendable, Equatable {
        /// Neither https:// nor http://.
        case scheme
        case host
        /// Plain http:// to a host outside the home network.
        case plaintext
        case key
    }

    /// Plain http is allowed to private, link-local and tailnet addresses, `.local` names and single-label
    /// names: the hosts the app's transport security lets through without TLS.
    static func isHomeNetwork(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.contains(":") {
            return host == "::1" || host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd")
        }
        if !host.contains(".") || host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = parts.compactMap { UInt8($0) }
        guard parts.count == 4, octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (10, _), (127, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        // Carrier-grade NAT, which Tailscale uses for its addresses.
        case (100, 64...127): return true
        default: return false
        }
    }
}

/// What Bazarr reports about itself.
public struct BazarrStatus: Sendable, Equatable {
    public var version: String
    /// Versions of the linked Sonarr and Radarr, when Bazarr reaches them.
    public var sonarrVersion: String?
    public var radarrVersion: String?
}

/// The item Bazarr searches for: a Radarr movie or a Sonarr episode.
public enum BazarrTarget: Sendable, Hashable {
    case movie(radarrID: Int)
    case episode(seriesID: Int, episodeID: Int)
}

/// What the app knows about the playing item, to find it in Bazarr.
public struct BazarrLookup: Sendable, Equatable {
    /// The movie's title, or the show's for an episode.
    public var title: String
    public var year: Int?
    /// The movie's or the show's ids, as Plex lists them: `imdb://tt0133093`, `tmdb://603`, `tvdb://121361`.
    public var externalIDs: [String]
    /// Season and episode numbers; nil for a movie.
    public var season: Int?
    public var episode: Int?
    /// The playing file's path as Plex knows it; only its name is compared, since Sonarr and Radarr
    /// often mount the library elsewhere.
    public var file: String?

    public init(title: String, year: Int?, externalIDs: [String], season: Int? = nil, episode: Int? = nil, file: String?) {
        self.title = title
        self.year = year
        self.externalIDs = externalIDs
        self.season = season
        self.episode = episode
        self.file = file
    }

    public var isEpisode: Bool { season != nil && episode != nil }
}

/// One subtitle a provider offers, as Bazarr's manual search lists it.
public struct BazarrSubtitle: Sendable, Hashable, Identifiable {
    public var provider: String
    /// Bazarr's handle for the result, sent back to download it.
    public var subtitle: String
    /// Two-letter code, such as "en".
    public var language: String
    public var isHearingImpaired: Bool
    public var isForced: Bool
    /// Percent of the best possible match.
    public var score: Double
    /// Release names the subtitle was made for.
    public var releases: [String]
    public var uploader: String?
    public var usesOriginalFormat: Bool

    public var id: String { provider + "/" + subtitle }

    public var trackLanguage: TrackLanguage { TrackLanguage(tag: language) }

    /// What the track it becomes holds.
    public var kind: SubtitleTrack.Kind { isForced ? .onScreenText : isHearingImpaired ? .captions : .full }

    /// The release it was made for, else the provider.
    public var name: String { releases.first { !$0.isEmpty } ?? providerName }

    /// The provider as its site names itself; Bazarr sends its own lower-case id.
    public var providerName: String {
        Self.providerNames[provider] ?? provider.prefix(1).uppercased() + provider.dropFirst()
    }

    private static let providerNames = [
        "addic7ed": "Addic7ed", "animetosho": "Animetosho", "embeddedsubtitles": "Embedded Subtitles",
        "gestdown": "Gestdown", "opensubtitles": "OpenSubtitles.org", "opensubtitlescom": "OpenSubtitles.com",
        "podnapisi": "Podnapisi", "subdl": "SubDL", "subf2m": "Subf2m", "supersubtitles": "SuperSubtitles",
        "tvsubtitles": "TVsubtitles", "whisperai": "Whisper", "yifysubtitles": "YIFY Subtitles",
    ]
}

public enum BazarrError: Error, Sendable, Equatable {
    case unreachable
    case timedOut
    /// The address answered but refused the key.
    case badKey
    /// The address answered, but not like Bazarr.
    case notBazarr
    /// Bazarr lists no such movie or episode.
    case notFound
    /// Bazarr could not search its providers.
    case searchFailed
    /// Bazarr no longer has the result (its cache expired) or will not take it.
    case badCandidate
    /// Bazarr could not fetch the subtitle from its provider.
    case downloadFailed
}

/// Bazarr's own HTTP API, authorized with its `X-API-KEY` header.
public struct BazarrClient: Sendable {
    public let config: BazarrConfig
    private let transport: any PlexTransport

    public init(config: BazarrConfig, transport: any PlexTransport = URLSessionTransport()) {
        self.config = config
        self.transport = transport
    }

    public func status() async throws -> BazarrStatus {
        struct Body: Decodable {
            struct Status: Decodable {
                let bazarrVersion: String
                let sonarrVersion: String?
                let radarrVersion: String?

                enum CodingKeys: String, CodingKey {
                    case bazarrVersion = "bazarr_version", sonarrVersion = "sonarr_version", radarrVersion = "radarr_version"
                }
            }
            let data: Status
        }
        let status = try await get(Body.self, "/api/system/status", timeout: 10).data
        func linked(_ version: String?) -> String? {
            guard let version, !version.isEmpty, version.lowercased() != "unknown" else { return nil }
            return version
        }
        return BazarrStatus(
            version: status.bazarrVersion, sonarrVersion: linked(status.sonarrVersion), radarrVersion: linked(status.radarrVersion)
        )
    }

    /// The Radarr movie or Sonarr episode for the playing item: by IMDb, TMDB or TVDB id, then by file
    /// name, then by title and year.
    public func find(_ lookup: BazarrLookup) async throws -> BazarrTarget {
        if lookup.isEpisode {
            let shows = try await get(DataList<Series>.self, "/api/series", ["start": "0", "length": "-1"]).data
            guard let show = Self.best(shows, for: lookup) else { throw BazarrError.notFound }
            let episodes = try await get(DataList<Episode>.self, "/api/episodes", ["seriesid[]": String(show.id)]).data
            let name = lookup.file.map(Self.fileName)
            guard let episode = episodes.first(where: { $0.season == lookup.season && $0.episode == lookup.episode })
                ?? episodes.first(where: { name != nil && $0.path.map(Self.fileName) == name }) else { throw BazarrError.notFound }
            return .episode(seriesID: show.id, episodeID: episode.id)
        }
        let movies = try await get(DataList<Movie>.self, "/api/movies", ["start": "0", "length": "-1"]).data
        guard let movie = Self.best(movies, for: lookup) else { throw BazarrError.notFound }
        return .movie(radarrID: movie.id)
    }

    /// Every subtitle Bazarr's providers offer for the target, in the languages of its profile, best
    /// first. Providers can take a minute to answer.
    public func search(_ target: BazarrTarget) async throws -> [BazarrSubtitle] {
        let (path, query) = Self.providers(target)
        do {
            let offers = try await get(DataList<Offer>.self, path, query, timeout: 120).data
            return offers.compactMap(\.subtitle).sorted { $0.score > $1.score }
        } catch BazarrError.notBazarr {
            throw BazarrError.searchFailed
        }
    }

    /// Asks Bazarr to download a search result next to the video file.
    public func download(_ subtitle: BazarrSubtitle, for target: BazarrTarget) async throws {
        let (path, ids) = Self.providers(target)
        let fields = ids.merging([
            "hi": subtitle.isHearingImpaired ? "True" : "False",
            "forced": subtitle.isForced ? "True" : "False",
            "original_format": subtitle.usesOriginalFormat ? "True" : "False",
            "provider": subtitle.provider,
            "subtitle": subtitle.subtitle,
        ]) { a, _ in a }
        let body = fields.sorted { $0.key < $1.key }
            .map { PlexURL.encode($0.key) + "=" + PlexURL.encode($0.value) }
            .joined(separator: "&")
        let response = try await send(
            .post, path, [:], body: Data(body.utf8), contentType: "application/x-www-form-urlencoded", timeout: 120
        )
        switch response.status {
        case 200..<300: return
        case 401, 403: throw BazarrError.badKey
        case 400..<500: throw BazarrError.badCandidate
        default: throw BazarrError.downloadFailed
        }
    }

    // MARK: Matching

    private static func providers(_ target: BazarrTarget) -> (String, [String: String]) {
        switch target {
        case .movie(let radarrID):
            ("/api/providers/movies", ["radarrid": String(radarrID)])
        case .episode(let seriesID, let episodeID):
            ("/api/providers/episodes", ["seriesid": String(seriesID), "episodeid": String(episodeID)])
        }
    }

    private static func best<Title: BazarrTitle>(_ titles: [Title], for lookup: BazarrLookup) -> Title? {
        let ids = Set(lookup.externalIDs.map { $0.lowercased() })
        if let match = titles.first(where: { !ids.isDisjoint(with: $0.externalIDs) }) { return match }
        if !lookup.isEpisode, let name = lookup.file.map(fileName),
           let match = titles.first(where: { $0.path.map(fileName) == name }) {
            return match
        }
        let title = folded(lookup.title)
        let named = titles.filter { folded($0.title) == title }
        return named.first { lookup.year != nil && $0.year == lookup.year } ?? (named.count == 1 ? named.first : nil)
    }

    static func fileName(_ path: String) -> String {
        String(path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last ?? "").lowercased()
    }

    private static func folded(_ title: String) -> String {
        title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    // MARK: Transport

    private func get<T: Decodable>(_ type: T.Type, _ path: String, _ query: [String: String] = [:], timeout: TimeInterval = 30) async throws -> T {
        let response = try await send(.get, path, query, timeout: timeout)
        switch response.status {
        case 200..<300:
            guard let value = try? JSONDecoder().decode(T.self, from: response.body) else { throw BazarrError.notBazarr }
            return value
        case 401, 403: throw BazarrError.badKey
        default: throw BazarrError.notBazarr
        }
    }

    private func send(
        _ method: HTTPMethod, _ path: String, _ query: [String: String],
        body: Data? = nil, contentType: String? = nil, timeout: TimeInterval
    ) async throws -> PlexHTTPResponse {
        let items = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = PlexURL.make(base: config.address, path: path, query: items) else { throw BazarrError.notBazarr }
        var headers = ["X-API-KEY": config.apiKey, "Accept": "application/json"]
        if let contentType { headers["Content-Type"] = contentType }
        do {
            return try await transport.send(PlexRequest(method: method, url: url, headers: headers, body: body, timeout: timeout))
        } catch let failure as NetworkFailure {
            throw failure == .timedOut ? BazarrError.timedOut : BazarrError.unreachable
        }
    }

    // MARK: Wire

    private struct DataList<Item: Decodable>: Decodable {
        let data: [Item]

        enum CodingKeys: CodingKey { case data }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            data = c.list(.data)
        }
    }

    private struct Movie: BazarrTitle {
        let id: Int
        let title: String
        let year: Int?
        let path: String?
        let externalIDs: Set<String>

        enum CodingKeys: String, CodingKey { case radarrId, title, year, path, imdbId, tmdbId }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard let id = c.int(.radarrId) else { throw BazarrError.notBazarr }
            self.id = id
            title = c.string(.title) ?? ""
            year = c.int(.year)
            path = c.string(.path)
            externalIDs = Self.ids(imdb: c.string(.imdbId), tmdb: c.string(.tmdbId), tvdb: nil)
        }
    }

    private struct Series: BazarrTitle {
        let id: Int
        let title: String
        let year: Int?
        let path: String?
        let externalIDs: Set<String>

        enum CodingKeys: String, CodingKey { case sonarrSeriesId, title, year, path, imdbId, tvdbId }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard let id = c.int(.sonarrSeriesId) else { throw BazarrError.notBazarr }
            self.id = id
            title = c.string(.title) ?? ""
            year = c.int(.year)
            path = c.string(.path)
            externalIDs = Self.ids(imdb: c.string(.imdbId), tmdb: nil, tvdb: c.string(.tvdbId))
        }
    }

    private struct Episode: Decodable {
        let id: Int
        let season: Int?
        let episode: Int?
        let path: String?

        enum CodingKeys: String, CodingKey { case sonarrEpisodeId, season, episode, path }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard let id = c.int(.sonarrEpisodeId) else { throw BazarrError.notBazarr }
            self.id = id
            season = c.int(.season)
            episode = c.int(.episode)
            path = c.string(.path)
        }
    }

    private struct Offer: Decodable {
        let subtitle: BazarrSubtitle?

        enum CodingKeys: String, CodingKey {
            case provider, subtitle, language, score, uploader
            case hearingImpaired = "hearing_impaired", forced, originalFormat = "original_format", releaseInfo = "release_info"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard let provider = c.string(.provider), let handle = c.string(.subtitle), let language = c.string(.language) else {
                subtitle = nil
                return
            }
            let uploader = c.string(.uploader).flatMap { $0.isEmpty ? nil : $0 }
            subtitle = BazarrSubtitle(
                provider: provider, subtitle: handle, language: language,
                isHearingImpaired: c.bool(.hearingImpaired) ?? false, isForced: c.bool(.forced) ?? false,
                score: c.double(.score) ?? 0, releases: c.list(.releaseInfo), uploader: uploader,
                usesOriginalFormat: c.bool(.originalFormat) ?? false
            )
        }
    }
}

private protocol BazarrTitle: Decodable {
    var title: String { get }
    var year: Int? { get }
    var path: String? { get }
    /// `imdb://tt0133093`, `tmdb://603`, `tvdb://121361`, as Plex writes them.
    var externalIDs: Set<String> { get }
}

extension BazarrTitle {
    static func ids(imdb: String?, tmdb: String?, tvdb: String?) -> Set<String> {
        var ids: Set<String> = []
        for (scheme, value) in [("imdb", imdb), ("tmdb", tmdb), ("tvdb", tvdb)] {
            guard let value, !value.isEmpty, value != "0" else { continue }
            ids.insert("\(scheme)://\(value.lowercased())")
        }
        return ids
    }
}
