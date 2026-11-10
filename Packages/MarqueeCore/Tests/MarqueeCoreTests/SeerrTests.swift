import Foundation
import Synchronization
import Testing
@testable import MarqueeCore

struct SeerrTests {
    static let address = URL(string: "https://seerr.example.net")!
    static var me: [String: Any] { ["id": 7, "displayName": "Nitin", "permissions": 32] }

    static func client(
        _ auth: SeerrConfig.Auth = .plex, token: String? = "plex-token", session: String? = nil,
        onSession: @escaping @Sendable (String) -> Void = { _ in },
        _ answer: @escaping @Sendable (PlexRequest, [PlexRequest]) -> PlexHTTPResponse
    ) -> (SeerrClient, FakeTransport) {
        let transport = FakeTransport { request, earlier in answer(request, earlier) }
        let config = SeerrConfig(address: address, auth: auth)
        return (SeerrClient(config: config, transport: transport, plexToken: token, session: session, onSession: onSession), transport)
    }

    static func signedIn(_ response: PlexHTTPResponse = json(me)) -> PlexHTTPResponse {
        var response = response
        response.headers = ["Set-Cookie": "connect.sid=s%3Aabc.def; Path=/; Expires=Thu, 10 Dec 2026 10:00:00 GMT; HttpOnly"]
        return response
    }

    static func body(_ request: PlexRequest) -> [String: Any] {
        request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    @Test func parseAcceptsHTTPSAnywhereAndHTTPOnlyAtHome() throws {
        #expect(try SeerrConfig.parse(address: " https://seerr.example.net ", apiKey: nil).get().auth == .plex)
        #expect((try? SeerrConfig.parse(address: "http://192.168.1.71:5055", apiKey: nil).get()) != nil)
        #expect(SeerrConfig.parse(address: "http://seerr.example.net", apiKey: nil) == .failure(.plaintext))
        #expect(SeerrConfig.parse(address: "seerr.example.net", apiKey: nil) == .failure(.scheme))
        let key = "MTczMDAwMDAwMDAwMGQ0ZjI5YjM0LTAwMDAtNDAwMC04MDAwLTAwMDAwMDAwMDAwMA=="
        #expect(try SeerrConfig.parse(address: "https://seerr.example.net", apiKey: " \(key) ").get().auth == .apiKey(key))
        #expect(SeerrConfig.parse(address: "https://seerr.example.net", apiKey: "short") == .failure(.key))
    }

    @Test func plexSignInPostsTheTokenAndSendsSeerrsCookieAfter() async throws {
        let kept = Mutex<String?>(nil)
        let (client, transport) = Self.client(onSession: { header in kept.withLock { $0 = header } }) { request, _ in
            request.url.path == "/api/v1/auth/plex" ? Self.signedIn() : json(["results": []])
        }
        #expect(try await client.me() == SeerrUser(id: 7, name: "Nitin", permissions: .request))
        _ = try await client.discover(.trending)
        let signIn = try #require(await transport.requests(to: "/api/v1/auth/plex").first)
        #expect(signIn.method == .post && Self.body(signIn)["authToken"] as? String == "plex-token")
        let discover = try #require(await transport.requests(to: "/api/v1/discover/trending").first)
        #expect(discover.headers["Cookie"] == "connect.sid=s%3Aabc.def")
        #expect(kept.withLock { $0 } == "connect.sid=s%3Aabc.def")
    }

    @Test func plexSignInNamesTheRefusal() async {
        await #expect(throws: SeerrError.plexAccountNotAllowed) {
            try await Self.client { _, _ in json(["message": "Access denied."], status: 403) }.0.signIn()
        }
        await #expect(throws: SeerrError.plexSignInFailed) {
            try await Self.client { _, _ in json(["message": "Unable to authenticate."], status: 500) }.0.signIn()
        }
        await #expect(throws: SeerrError.notSignedIn) { try await Self.client(token: nil) { _, _ in json(Self.me) }.0.signIn() }
        // A 200 without a session cookie leaves nothing to sign the next request with.
        await #expect(throws: SeerrError.notSeerr) { try await Self.client { _, _ in json(Self.me) }.0.signIn() }
    }

    @Test func aLapsedSessionSignsInAgainOnce() async throws {
        let (client, transport) = Self.client(session: "connect.sid=old") { request, earlier in
            if request.url.path == "/api/v1/auth/plex" { return Self.signedIn() }
            return earlier.contains { $0.url.path == "/api/v1/auth/plex" } ? json(["results": []]) : json([:], status: 403)
        }
        #expect(try await client.discover(.popularMovies).isEmpty)
        #expect(await transport.requests(to: "/api/v1/auth/plex").count == 1)
        #expect(await transport.requests(to: "/api/v1/discover/movies").last?.headers["Cookie"] == "connect.sid=s%3Aabc.def")

        let (refused, _) = Self.client(session: "connect.sid=old") { request, _ in
            request.url.path == "/api/v1/auth/plex" ? Self.signedIn() : json([:], status: 403)
        }
        await #expect(throws: SeerrError.notAllowed) { try await refused.discover(.trending) }
    }

    @Test func apiKeyGoesInItsHeader() async throws {
        let (client, transport) = Self.client(.apiKey("key-0123456789abcdef")) { _, _ in json(Self.me) }
        _ = try await client.signIn()
        #expect(await transport.requests(to: "/api/v1/auth/me").first?.headers["X-Api-Key"] == "key-0123456789abcdef")
        await #expect(throws: SeerrError.badKey) {
            try await Self.client(.apiKey("key-0123456789abcdef")) { _, _ in json([:], status: 403) }.0.signIn()
        }
    }

    @Test func csrfCookiesComeBackWithTheTokenHeaderButAreNotKept() async throws {
        let kept = Mutex<String?>(nil)
        let (client, transport) = Self.client(onSession: { header in kept.withLock { $0 = header } }) { request, _ in
            switch request.url.path {
            case "/api/v1/status":
                var response = json(["version": "3.0.1"])
                response.headers = ["set-cookie": "_csrf=sec; Path=/; HttpOnly, XSRF-TOKEN=tok%2B1; Path=/"]
                return response
            case "/api/v1/auth/plex": return Self.signedIn()
            default: return json([:], status: 404)
            }
        }
        #expect(try await client.version() == "3.0.1")
        _ = try await client.signIn()
        let signIn = try #require(await transport.requests(to: "/api/v1/auth/plex").first)
        #expect(signIn.headers["Cookie"] == "XSRF-TOKEN=tok%2B1; _csrf=sec")
        #expect(signIn.headers["X-XSRF-TOKEN"] == "tok+1")
        #expect(kept.withLock { $0 } == "connect.sid=s%3Aabc.def")
    }

    @Test func versionTellsSeerrFromAnotherServer() async {
        await #expect(throws: SeerrError.notSeerr) { try await Self.client { _, _ in json([:], status: 404) }.0.version() }
        await #expect(throws: SeerrError.notSeerr) {
            try await Self.client { _, _ in PlexHTTPResponse(status: 200, body: Data("<html>".utf8)) }.0.version()
        }
        await #expect(throws: SeerrError.unreachable) {
            try await SeerrClient(config: SeerrConfig(address: Self.address, auth: .plex), transport: FakeTransport { _, _ in
                throw NetworkFailure.cannotConnect
            }).version()
        }
    }

    @Test func discoverReadsTitlesAndLeavesPeopleOut() async throws {
        let (client, transport) = Self.client(session: "connect.sid=x") { _, _ in
            json(["page": 1, "results": [
                ["id": 603, "mediaType": "movie", "title": "The Matrix", "releaseDate": "1999-03-30", "posterPath": "/m.jpg",
                 "mediaInfo": ["status": 3, "downloadStatus": [["title": "x"]]]],
                ["id": 1399, "mediaType": "tv", "name": "Game of Thrones", "firstAirDate": "2011-04-17"],
                ["id": 287, "mediaType": "person", "name": "Brad Pitt"],
            ]])
        }
        let titles = try await client.search("the matrix")
        #expect(titles.map(\.id) == ["movie/603", "tv/1399"])
        #expect(titles[0].year == 1999 && titles[0].posterPath == "/m.jpg" && titles[0].badge == .processing)
        #expect(titles[1].name == "Game of Thrones" && titles[1].badge == nil)
        #expect(await transport.requests.first?.url.query == "query=the%20matrix&page=1")
    }

    @Test func detailsReadSeasonsPlexLinkAndTVDBID() async throws {
        let (client, _) = Self.client(session: "connect.sid=x") { _, _ in
            json([
                "id": 1399, "name": "Game of Thrones", "firstAirDate": "2011-04-17", "tagline": "", "genres": [["name": "Drama"]],
                "externalIds": ["tvdbId": 121_361],
                "seasons": [["seasonNumber": 1, "name": "Season 1", "episodeCount": 10], ["seasonNumber": 0, "name": "Specials"]],
                "mediaInfo": [
                    "status": 4, "ratingKey": "5512",
                    "iOSPlexUrl": "plex://preplay/?metadataKey=%2Flibrary%2Fmetadata%2F5512&server=abc123",
                    "seasons": [["seasonNumber": 1, "status": 5]],
                    "requests": [["id": 4, "status": 1, "is4k": false, "seasons": [["seasonNumber": 2]]]],
                ],
            ])
        }
        let details = try await client.details(.tv, tmdbID: 1399)
        #expect(details.title.kind == .tv && details.tagline == nil && details.genres == ["Drama"] && details.tvdbID == 121_361)
        #expect(details.seasons.map(\.number) == [0, 1])
        let media = try #require(details.title.media)
        #expect(media.status == .partiallyAvailable && media.seasons == [SeerrMedia.Season(number: 1, status: .available)])
        #expect(media.requests.map(\.seasons) == [[2]])
        #expect(media.plexLink(serverID: "abc123") == .item(ratingKey: "5512"))
    }

    @Test func requestPostsTheOrderAndNamesRefusals() async throws {
        let (client, transport) = Self.client(session: "connect.sid=x") { _, _ in
            json(["id": 31, "status": 1, "type": "tv", "is4k": false, "media": ["tmdbId": 1399, "status": 2]], status: 201)
        }
        try await client.request(SeerrOrder(kind: .tv, tmdbID: 1399, tvdbID: 121_361, seasons: [2, 3]))
        let sent = try #require(await transport.requests(to: "/api/v1/request").first)
        let body = Self.body(sent)
        #expect(body["mediaType"] as? String == "tv" && body["mediaId"] as? Int == 1399 && body["tvdbId"] as? Int == 121_361)
        #expect(body["seasons"] as? [Int] == [2, 3] && body["is4k"] as? Bool == false)
        #expect(sent.headers["Content-Type"] == "application/json")

        let movie = SeerrOrder(kind: .movie, tmdbID: 603)
        await #expect(throws: SeerrError.alreadyRequested) {
            try await Self.client(session: "connect.sid=x") { _, _ in json(["message": "Request exists"], status: 409) }.0.request(movie)
        }
        await #expect(throws: SeerrError.alreadyRequested) {
            try await Self.client(session: "connect.sid=x") { _, _ in json(["message": "No seasons"], status: 202) }.0.request(movie)
        }
        await #expect(throws: SeerrError.quotaReached) {
            try await Self.client(.apiKey("key-0123456789abcdef")) { _, _ in
                json(["message": "Movie Quota exceeded."], status: 403)
            }.0.request(movie)
        }
    }

    @Test func myRequestsAskForTheAccountsOwnAndLoadTitles() async throws {
        let (client, transport) = Self.client(session: "connect.sid=x") { request, _ in
            switch request.url.path {
            case "/api/v1/request":
                json(["results": [
                    ["id": 2, "status": 2, "type": "movie", "media": ["tmdbId": 603, "status": 5]],
                    ["id": 1, "status": 3, "type": "tv", "media": ["tmdbId": 1399, "status": 1]],
                ]])
            case "/api/v1/movie/603": json(["id": 603, "title": "The Matrix"])
            default: json([:], status: 500)
            }
        }
        let items = try await client.requests(of: SeerrUser(id: 7, name: "Nitin", permissions: .request))
        #expect(items.map(\.title?.name) == ["The Matrix", nil])
        #expect(items.map(\.request.badge) == [.available, .declined])
        #expect(await transport.requests(to: "/api/v1/request").first?.url.query("requestedBy") == "7")
    }

    // MARK: Rules

    @Test func mediaBadgeFollowsStatusThenTheLatestRequest() {
        #expect(SeerrMedia(status: .available).badge(is4K: false) == .available)
        #expect(SeerrMedia(status: .processing).badge(is4K: false) == .approved)
        #expect(SeerrMedia(status: .processing, isDownloading: true).badge(is4K: false) == .processing)
        #expect(SeerrMedia(status: .pending).badge(is4K: false) == .pending)
        let declined = SeerrMedia(status: .unknown, requests: [
            SeerrRequest(id: 1, status: .failed, kind: .movie), SeerrRequest(id: 2, status: .declined, kind: .movie),
        ])
        #expect(declined.badge(is4K: false) == .declined)
        #expect(declined.badge(is4K: true) == nil)
        #expect(SeerrMedia(status: .available, status4K: .pending).badge(is4K: true) == .pending)
    }

    @Test func requestBadgeShowsHowFarAnApprovedRequestGot() {
        let approved = SeerrRequest(id: 1, status: .approved, kind: .movie, media: SeerrMedia(status: .processing, isDownloading: true))
        #expect(approved.badge == .processing)
        #expect(SeerrRequest(id: 1, status: .approved, kind: .movie, media: SeerrMedia(status: .pending)).badge == .approved)
        #expect(SeerrRequest(id: 1, status: .completed, kind: .movie, media: SeerrMedia(status: .deleted)).badge == nil)
        #expect(SeerrRequest(id: 1, status: .failed, kind: .movie).badge == .failed)
    }

    static let series = SeerrDetails(
        title: SeerrTitle(kind: .tv, tmdbID: 1399, name: "Game of Thrones", media: SeerrMedia(
            status: .partiallyAvailable,
            seasons: [SeerrMedia.Season(number: 1, status: .available)],
            requests: [
                SeerrRequest(id: 4, status: .pending, kind: .tv, seasons: [2]),
                SeerrRequest(id: 5, status: .declined, kind: .tv, seasons: [3]),
                SeerrRequest(id: 6, status: .approved, kind: .tv, is4K: true, seasons: [3]),
            ]
        )),
        seasons: (0...3).map { SeerrSeason(number: $0, name: "Season \($0)", episodeCount: 10) },
        tvdbID: 121_361
    )
    static let requester = SeerrUser(id: 7, name: "Nitin", permissions: .request)

    @Test func seasonChoicesSkipSpecialsAndTakenSeasons() {
        let settings = SeerrServerSettings()
        let choices = Self.series.seasonChoices(is4K: false, settings: settings)
        #expect(choices.map(\.season.number) == [1, 2, 3])
        #expect(choices.map(\.badge) == [.available, .pending, nil])
        #expect(Self.series.seasonChoices(is4K: true, settings: settings).map(\.badge) == [nil, nil, .approved])
        #expect(Self.series.seasonChoices(is4K: false, settings: SeerrServerSettings(specialEpisodesEnabled: true)).count == 4)
    }

    @Test func ordersTakeChosenOpenSeasonsOrAllWithoutPartialRequests() {
        let partial = Self.series.order(seasons: [1, 3], is4K: false, settings: SeerrServerSettings())
        #expect(partial == SeerrOrder(kind: .tv, tmdbID: 1399, tvdbID: 121_361, seasons: [3]))
        let whole = Self.series.order(seasons: [], is4K: true, settings: SeerrServerSettings(partialRequestsEnabled: false))
        #expect(whole.seasons == [1, 2] && whole.is4K)
    }

    @Test func canRequestNeedsPermissionOpenSeasonsAnd4KSettings() {
        let movie = SeerrDetails(title: SeerrTitle(kind: .movie, tmdbID: 603, name: "The Matrix"))
        let fourK = SeerrServerSettings(movie4KEnabled: true)
        #expect(movie.canRequest(is4K: false, user: Self.requester, settings: fourK))
        #expect(!movie.canRequest(is4K: false, user: SeerrUser(id: 8, name: "Guest", permissions: .requestTV), settings: fourK))
        #expect(!movie.canRequest(is4K: true, user: Self.requester, settings: fourK))
        let admin = SeerrUser(id: 1, name: "Admin", permissions: .admin)
        #expect(movie.canRequest(is4K: true, user: admin, settings: fourK))
        #expect(!movie.canRequest(is4K: true, user: admin, settings: SeerrServerSettings()))
        var pending = movie
        pending.title.media = SeerrMedia(status: .pending)
        #expect(!pending.canRequest(is4K: false, user: admin, settings: fourK))
        #expect(Self.series.canRequest(is4K: false, user: Self.requester, settings: SeerrServerSettings()))
    }

    @Test func plexLinkPrefersTheSignedInServer() {
        let media = SeerrMedia(status: .available, status4K: .available, ratingKey: "1", ratingKey4K: "2", plexServerID: "other", plexServerID4K: "mine")
        #expect(media.plexLink(serverID: "mine") == .item(ratingKey: "2"))
        #expect(media.plexLink(serverID: "third") == nil)
        #expect(SeerrMedia(status: .available, ratingKey: "1").plexLink(serverID: "mine") == .unconfirmed(ratingKey: "1"))
        #expect(SeerrMedia(status: .processing, ratingKey: "1", plexServerID: "mine").plexLink(serverID: "mine") == nil)
        #expect(SeerrMedia.plexServerID(app: nil, web: "https://app.plex.tv/desktop#!/server/abc/details?key=x") == "abc")
    }

    @Test func watchlistAddRequestsWithPulsarrOrAutoRequestUntilRequested() {
        let movie = SeerrDetails(title: SeerrTitle(kind: .movie, tmdbID: 603, name: "The Matrix"))
        #expect(!movie.watchlistAddRequests(user: Self.requester, pulsarr: false))
        #expect(movie.watchlistAddRequests(user: Self.requester, pulsarr: true))
        #expect(movie.watchlistAddRequests(user: SeerrUser(id: 7, name: "N", permissions: .autoRequestMovie), pulsarr: false))
        #expect(!movie.watchlistAddRequests(user: SeerrUser(id: 7, name: "N", permissions: .autoRequestTV), pulsarr: false))
        var requested = movie
        requested.title.media = SeerrMedia(status: .pending)
        #expect(!requested.watchlistAddRequests(user: Self.requester, pulsarr: true))
    }

    @Test func tmdbImagePicksTheSmallestSizeThatCovers() {
        #expect(TMDBImage.url("/p.jpg", pixels: 312)?.absoluteString == "https://image.tmdb.org/t/p/w342/p.jpg")
        #expect(TMDBImage.url("/p.jpg", pixels: 1200)?.absoluteString == "https://image.tmdb.org/t/p/original/p.jpg")
        #expect(TMDBImage.url(nil, pixels: 100) == nil)
    }
}
