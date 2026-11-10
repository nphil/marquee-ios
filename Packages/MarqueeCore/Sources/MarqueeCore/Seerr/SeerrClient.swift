import Foundation

/// Seerr's HTTP API. With Plex sign-in it posts the profile's Plex token to `/api/v1/auth/plex` and sends
/// back the session cookie Seerr sets; with an API key it sends the key. It keeps its own cookies, so
/// the app's URL session must not handle cookies for it.
public actor SeerrClient {
    public nonisolated let config: SeerrConfig
    private let transport: any PlexTransport
    private let plexToken: String?
    private let onSession: @Sendable (String) -> Void
    /// Every cookie Seerr set: its session, and its CSRF pair when CSRF protection is on.
    private var cookies: [String: String]
    private var signingIn: Task<SeerrUser, any Error>?

    /// `session` is a cookie header kept from an earlier sign-in; `onSession` receives each new one.
    public init(
        config: SeerrConfig, transport: any PlexTransport = URLSessionTransport(), plexToken: String? = nil,
        session: String? = nil, onSession: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.config = config
        self.transport = transport
        self.plexToken = plexToken
        self.onSession = onSession
        cookies = session.map(Self.cookies(inHeader:)) ?? [:]
    }

    /// Seerr's version. Answers without signing in, so it proves the address before any sign-in.
    public func version() async throws -> String {
        struct Body: Decodable { let version: String }
        do {
            return try await get(Body.self, "/api/v1/status", signsIn: false).version
        } catch SeerrError.notFound, SeerrError.failed {
            throw SeerrError.notSeerr
        }
    }

    /// Signs in afresh with Plex, or checks the API key, and returns the account.
    public func signIn() async throws -> SeerrUser {
        if case .plex = config.auth { return try await plexSignIn() }
        return try await get(UserWire.self, "/api/v1/auth/me").user
    }

    /// The signed-in account, signing in first when there is no session yet.
    public func me() async throws -> SeerrUser {
        if case .plex = config.auth, !hasSession { return try await plexSignIn() }
        return try await get(UserWire.self, "/api/v1/auth/me").user
    }

    /// The request options Seerr shows every account.
    public func serverSettings() async throws -> SeerrServerSettings {
        try await get(SettingsWire.self, "/api/v1/settings/public", signsIn: false).settings
    }

    /// One page of a Discover shelf; people in Trending are left out.
    public func discover(_ shelf: SeerrShelf, page: Int = 1) async throws -> [SeerrTitle] {
        try await get(Page.self, shelf.path, query: [URLQueryItem(name: "page", value: String(page))]).titles
    }

    public func search(_ text: String, page: Int = 1) async throws -> [SeerrTitle] {
        let query = [URLQueryItem(name: "query", value: text), URLQueryItem(name: "page", value: String(page))]
        return try await get(Page.self, "/api/v1/search", query: query).titles
    }

    public func details(_ kind: SeerrMediaKind, tmdbID: Int) async throws -> SeerrDetails {
        try await get(DetailsWire.self, "/api/v1/\(kind.rawValue)/\(tmdbID)", kind: kind).details
    }

    /// Sends a request. Seerr approves it at once when the account may auto-approve; the title's page
    /// reloads to show which.
    public func request(_ order: SeerrOrder) async throws {
        struct Body: Encodable {
            let mediaType: String
            let mediaId: Int
            let tvdbId: Int?
            let seasons: [Int]?
            let is4k: Bool
        }
        let body = Body(
            mediaType: order.kind.rawValue, mediaId: order.tmdbID, tvdbId: order.kind == .tv ? order.tvdbID : nil,
            seasons: order.kind == .tv ? order.seasons : nil, is4k: order.is4K
        )
        let response = try await send(.post, "/api/v1/request", body: try JSONEncoder().encode(body))
        switch response.status {
        // Seerr's answer when every season asked for is already requested or available.
        case 202: throw SeerrError.alreadyRequested
        case 200..<300: return
        default: throw failure(response)
        }
    }

    /// The account's latest requests, newest first, each with its title. A title that does not load
    /// leaves its request without one.
    public func requests(of user: SeerrUser, take: Int = 20) async throws -> [SeerrRequestItem] {
        let query = [
            URLQueryItem(name: "take", value: String(take)), URLQueryItem(name: "skip", value: "0"),
            URLQueryItem(name: "filter", value: "all"), URLQueryItem(name: "sort", value: "added"),
            URLQueryItem(name: "requestedBy", value: String(user.id)),
        ]
        let requests = try await get(RequestPage.self, "/api/v1/request", query: query).requests
        let titles = await withTaskGroup(of: (Int, SeerrTitle?).self) { group in
            for (index, request) in requests.enumerated() {
                guard let tmdbID = request.tmdbID else { continue }
                group.addTask { (index, try? await self.details(request.kind, tmdbID: tmdbID).title) }
            }
            var titles = [SeerrTitle?](repeating: nil, count: requests.count)
            for await (index, title) in group { titles[index] = title }
            return titles
        }
        return zip(requests, titles).map { SeerrRequestItem(request: $0, title: $1) }
    }

    // MARK: Sign-in

    /// One sign-in at a time; calls that find their session expired together share it.
    private func plexSignIn() async throws -> SeerrUser {
        if let signingIn { return try await signingIn.value }
        let task = Task { try await self.postPlexSignIn() }
        signingIn = task
        defer { signingIn = nil }
        return try await task.value
    }

    private func postPlexSignIn() async throws -> SeerrUser {
        guard let plexToken, !plexToken.isEmpty else { throw SeerrError.notSignedIn }
        cookies = cookies.filter { Self.csrfCookies.contains($0.key) }
        let body = try JSONEncoder().encode(["authToken": plexToken])
        let response = try await send(.post, "/api/v1/auth/plex", body: body, signsIn: false)
        switch response.status {
        case 200..<300:
            guard hasSession, let user = (try? JSONDecoder().decode(UserWire.self, from: response.body))?.user else {
                throw SeerrError.notSeerr
            }
            onSession(sessionHeader)
            return user
        case 401, 403: throw SeerrError.plexAccountNotAllowed
        case 404: throw SeerrError.notSeerr
        default: throw SeerrError.plexSignInFailed
        }
    }

    // MARK: Transport

    private func get<T: Decodable>(
        _ type: T.Type, _ path: String, query: [URLQueryItem] = [], kind: SeerrMediaKind? = nil, signsIn: Bool = true
    ) async throws -> T {
        let response = try await send(.get, path, query: query, signsIn: signsIn)
        guard (200..<300).contains(response.status) else { throw failure(response) }
        let decoder = JSONDecoder()
        if let kind { decoder.userInfo[Self.kindKey] = kind }
        guard let value = try? decoder.decode(T.self, from: response.body) else { throw SeerrError.notSeerr }
        return value
    }

    /// Sends one request with the key or the cookies. With Plex sign-in, a refusal signs in again and
    /// sends it once more: Seerr answers 403, not 401, once its 30-day session has lapsed.
    private func send(
        _ method: HTTPMethod, _ path: String, query: [URLQueryItem] = [], body: Data? = nil, signsIn: Bool = true
    ) async throws -> PlexHTTPResponse {
        guard let url = PlexURL.make(base: config.address, path: path, query: query) else { throw SeerrError.notSeerr }
        var headers = ["Accept": "application/json"]
        if body != nil { headers["Content-Type"] = "application/json" }
        if case .apiKey(let key) = config.auth { headers["X-Api-Key"] = key }
        if !cookies.isEmpty { headers["Cookie"] = Self.header(cookies) }
        if method != .get, let token = cookies["XSRF-TOKEN"] { headers["X-XSRF-TOKEN"] = token.removingPercentEncoding ?? token }
        let response: PlexHTTPResponse
        do {
            response = try await transport.send(PlexRequest(method: method, url: url, headers: headers, body: body, restrictToOrigin: true))
        } catch let failure as NetworkFailure {
            throw failure == .timedOut ? SeerrError.timedOut : SeerrError.unreachable
        }
        if let setCookie = response.header("Set-Cookie") {
            cookies.merge(Self.cookies(inSetCookie: setCookie)) { _, new in new }
        }
        if signsIn, case .plex = config.auth, response.status == 401 || response.status == 403 {
            _ = try await plexSignIn()
            return try await send(method, path, query: query, body: body, signsIn: false)
        }
        return response
    }

    private func failure(_ response: PlexHTTPResponse) -> SeerrError {
        let message = (try? JSONDecoder().decode(Message.self, from: response.body))?.message
        switch response.status {
        case 401, 403:
            if message?.localizedCaseInsensitiveContains("quota") == true { return .quotaReached }
            if case .apiKey = config.auth { return .badKey }
            return .notAllowed
        case 404: return .notFound
        case 409: return .alreadyRequested
        case 400..<600: return .failed(message: message)
        default: return .notSeerr
        }
    }

    // MARK: Cookies

    private static let csrfCookies: Set<String> = ["XSRF-TOKEN", "_csrf"]

    private var hasSession: Bool {
        cookies.keys.contains { !Self.csrfCookies.contains($0) }
    }

    /// The session cookies to keep across launches; the CSRF pair is fetched afresh.
    private var sessionHeader: String {
        Self.header(cookies.filter { !Self.csrfCookies.contains($0.key) })
    }

    private static func header(_ cookies: [String: String]) -> String {
        cookies.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    static func cookies(inHeader header: String) -> [String: String] {
        pairs(header.split(separator: ";"))
    }

    /// Foundation joins several Set-Cookie headers with commas. An `Expires` date has a comma of its
    /// own, but what follows it holds no `name=value` before the next semicolon, so it drops out.
    static func cookies(inSetCookie header: String) -> [String: String] {
        pairs(header.split(separator: ",").compactMap { $0.split(separator: ";").first })
    }

    private static func pairs(_ parts: [Substring]) -> [String: String] {
        var cookies: [String: String] = [:]
        for part in parts {
            let pair = part.trimmingCharacters(in: .whitespaces)
            guard let equals = pair.firstIndex(of: "=") else { continue }
            let name = String(pair[..<equals])
            guard !name.isEmpty, !name.contains(" ") else { continue }
            cookies[name] = String(pair[pair.index(after: equals)...])
        }
        return cookies
    }

    // MARK: Wire

    static let kindKey = CodingUserInfoKey(rawValue: "seerr.kind")!

    private struct Message: Decodable {
        let message: String?
    }

    private struct UserWire: Decodable {
        let user: SeerrUser

        enum CodingKeys: String, CodingKey { case id, displayName, username, plexUsername, email, permissions }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard let id = c.int(.id) else { throw SeerrError.notSeerr }
            let name = [c.string(.displayName), c.string(.username), c.string(.plexUsername), c.string(.email)]
                .compactMap { $0 }.first { !$0.isEmpty }
            user = SeerrUser(id: id, name: name ?? "Seerr user", permissions: SeerrPermissions(rawValue: c.int(.permissions) ?? 0))
        }
    }

    private struct SettingsWire: Decodable {
        let settings: SeerrServerSettings

        enum CodingKeys: String, CodingKey { case movie4kEnabled, series4kEnabled, partialRequestsEnabled, enableSpecialEpisodes }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            settings = SeerrServerSettings(
                movie4KEnabled: c.bool(.movie4kEnabled) ?? false, series4KEnabled: c.bool(.series4kEnabled) ?? false,
                partialRequestsEnabled: c.bool(.partialRequestsEnabled) ?? true,
                specialEpisodesEnabled: c.bool(.enableSpecialEpisodes) ?? false
            )
        }
    }

    private struct Page: Decodable {
        let titles: [SeerrTitle]

        enum CodingKeys: CodingKey { case results }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard c.contains(.results) else { throw SeerrError.notSeerr }
            let results: [TitleWire] = c.list(.results)
            titles = results.compactMap(\.title)
        }
    }

    private struct RequestPage: Decodable {
        let requests: [SeerrRequest]

        enum CodingKeys: CodingKey { case results }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard c.contains(.results) else { throw SeerrError.notSeerr }
            let results: [RequestWire] = c.list(.results)
            requests = results.compactMap(\.request)
        }
    }

    /// A movie or series in a list or on its own page; nil for people, collections and broken entries.
    private struct TitleWire: Decodable {
        let title: SeerrTitle?

        enum CodingKeys: String, CodingKey {
            case id, mediaType, title, name, releaseDate, firstAirDate, posterPath, backdropPath, overview, mediaInfo
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let kind = c.string(.mediaType).flatMap(SeerrMediaKind.init(rawValue:))
                ?? (c.contains(.mediaType) ? nil : decoder.userInfo[SeerrClient.kindKey] as? SeerrMediaKind)
            guard let kind, let id = c.int(.id) else {
                title = nil
                return
            }
            let date = kind == .movie ? c.string(.releaseDate) : c.string(.firstAirDate)
            title = SeerrTitle(
                kind: kind, tmdbID: id, name: (kind == .movie ? c.string(.title) : c.string(.name)) ?? "",
                year: date.flatMap { Int($0.prefix(4)) }, posterPath: c.string(.posterPath),
                backdropPath: c.string(.backdropPath), overview: c.string(.overview) ?? "",
                media: (try? c.decodeIfPresent(MediaWire.self, forKey: .mediaInfo))?.media
            )
        }
    }

    private struct DetailsWire: Decodable {
        let details: SeerrDetails

        enum CodingKeys: String, CodingKey { case tagline, genres, runtime, seasons, externalIds, mediaInfo }
        enum IDKeys: String, CodingKey { case tvdbId }

        struct Genre: Decodable { let name: String? }

        struct Season: Decodable {
            let season: SeerrSeason?

            enum CodingKeys: String, CodingKey { case seasonNumber, name, episodeCount }

            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                guard let number = c.int(.seasonNumber) else {
                    season = nil
                    return
                }
                season = SeerrSeason(number: number, name: c.string(.name) ?? "Season \(number)", episodeCount: c.int(.episodeCount) ?? 0)
            }
        }

        init(from decoder: any Decoder) throws {
            guard let title = try TitleWire(from: decoder).title else { throw SeerrError.notSeerr }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let genres: [Genre] = c.list(.genres)
            let seasons: [Season] = c.list(.seasons)
            let ids = try? c.nestedContainer(keyedBy: IDKeys.self, forKey: .externalIds)
            let media = try? c.nestedContainer(keyedBy: IDKeys.self, forKey: .mediaInfo)
            details = SeerrDetails(
                title: title, tagline: c.string(.tagline).flatMap { $0.isEmpty ? nil : $0 },
                genres: genres.compactMap(\.name), runtime: c.int(.runtime).flatMap { $0 > 0 ? $0 : nil },
                seasons: seasons.compactMap(\.season).sorted { $0.number < $1.number },
                tvdbID: ids?.int(.tvdbId) ?? media?.int(.tvdbId)
            )
        }
    }

    private struct MediaWire: Decodable {
        let media: SeerrMedia?

        enum CodingKeys: String, CodingKey {
            case status, status4k, downloadStatus, downloadStatus4k, ratingKey, ratingKey4k
            case plexUrl, plexUrl4k, mediaUrl, mediaUrl4k, iOSPlexUrl, iOSPlexUrl4k, seasons, requests
        }

        /// Any entry at all; only how many there are matters.
        struct Entry: Decodable {
            init(from decoder: any Decoder) throws {}
        }

        struct Season: Decodable {
            let season: SeerrMedia.Season?

            enum CodingKeys: String, CodingKey { case seasonNumber, status, status4k }

            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                guard let number = c.int(.seasonNumber) else {
                    season = nil
                    return
                }
                season = SeerrMedia.Season(
                    number: number, status: MediaWire.status(c.int(.status)), status4K: MediaWire.status(c.int(.status4k))
                )
            }
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard let status = c.int(.status).flatMap(SeerrMediaStatus.init(rawValue:)) else {
                media = nil
                return
            }
            let downloads: [Entry] = c.list(.downloadStatus)
            let downloads4K: [Entry] = c.list(.downloadStatus4k)
            let seasons: [Season] = c.list(.seasons)
            let requests: [RequestWire] = c.list(.requests)
            media = SeerrMedia(
                status: status, status4K: MediaWire.status(c.int(.status4k)), isDownloading: !downloads.isEmpty,
                isDownloading4K: !downloads4K.isEmpty, ratingKey: c.string(.ratingKey).flatMap { $0.isEmpty ? nil : $0 },
                ratingKey4K: c.string(.ratingKey4k).flatMap { $0.isEmpty ? nil : $0 },
                plexServerID: SeerrMedia.plexServerID(app: c.string(.iOSPlexUrl), web: c.string(.plexUrl) ?? c.string(.mediaUrl)),
                plexServerID4K: SeerrMedia.plexServerID(
                    app: c.string(.iOSPlexUrl4k), web: c.string(.plexUrl4k) ?? c.string(.mediaUrl4k)
                ),
                seasons: seasons.compactMap(\.season), requests: requests.compactMap(\.request)
            )
        }

        static func status(_ raw: Int?) -> SeerrMediaStatus {
            raw.flatMap(SeerrMediaStatus.init(rawValue:)) ?? .unknown
        }
    }

    private struct RequestWire: Decodable {
        let request: SeerrRequest?

        enum CodingKeys: String, CodingKey { case id, status, type, is4k, seasons, requestedBy, createdAt, media }
        enum MediaKeys: String, CodingKey { case tmdbId, mediaType }
        enum PersonKeys: String, CodingKey { case displayName, username, plexUsername }

        struct Season: Decodable {
            let number: Int?

            enum CodingKeys: String, CodingKey { case seasonNumber }

            init(from decoder: any Decoder) throws {
                number = try decoder.container(keyedBy: CodingKeys.self).int(.seasonNumber)
            }
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard let id = c.int(.id), let status = c.int(.status).flatMap(SeerrRequestStatus.init(rawValue:)) else {
                request = nil
                return
            }
            let media = try? c.nestedContainer(keyedBy: MediaKeys.self, forKey: .media)
            let person = try? c.nestedContainer(keyedBy: PersonKeys.self, forKey: .requestedBy)
            let seasons: [Season] = c.list(.seasons)
            let name = [person?.string(.displayName), person?.string(.username), person?.string(.plexUsername)]
                .compactMap { $0 }.first { !$0.isEmpty }
            request = SeerrRequest(
                id: id, status: status,
                kind: (c.string(.type) ?? media?.string(.mediaType)).flatMap(SeerrMediaKind.init(rawValue:)) ?? .movie,
                tmdbID: media?.int(.tmdbId), is4K: c.bool(.is4k) ?? false,
                seasons: seasons.compactMap(\.number).sorted(), requesterName: name, createdAt: c.date(.createdAt),
                media: (try? c.decodeIfPresent(MediaWire.self, forKey: .media))?.media
            )
        }
    }
}

/// A request with its title, for My Requests.
public struct SeerrRequestItem: Sendable, Hashable, Identifiable {
    public var request: SeerrRequest
    public var title: SeerrTitle?

    public init(request: SeerrRequest, title: SeerrTitle?) {
        self.request = request
        self.title = title
    }

    public var id: Int { request.id }
}
