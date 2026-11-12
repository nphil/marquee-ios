import Foundation
import Testing
@testable import MarqueeCore

struct BazarrTests {
    static let config = BazarrConfig(address: URL(string: "https://bazarr.example.net/bazarr")!, apiKey: "0123456789abcdef0123456789abcdef")

    static func client(_ answer: @escaping @Sendable (PlexRequest) -> PlexHTTPResponse) -> (BazarrClient, FakeTransport) {
        let transport = FakeTransport { request, _ in answer(request) }
        return (BazarrClient(config: config, transport: transport), transport)
    }

    @Test func parseAcceptsHTTPSAnywhereAndHTTPOnlyAtHome() throws {
        let key = "0123456789abcdef0123456789abcdef"
        #expect(try BazarrConfig.parse(address: " https://bazarr.example.net/bazarr ", key: key).get().address.path == "/bazarr")
        #expect((try? BazarrConfig.parse(address: "http://192.168.1.71:6767", key: key).get()) != nil)
        #expect((try? BazarrConfig.parse(address: "http://100.101.5.2:6767", key: key).get()) != nil)
        #expect((try? BazarrConfig.parse(address: "http://nas.local:6767", key: key).get()) != nil)
        #expect(BazarrConfig.parse(address: "http://bazarr.example.net", key: key) == .failure(.plaintext))
        #expect(BazarrConfig.parse(address: "http://172.32.0.1", key: key) == .failure(.plaintext))
        #expect(BazarrConfig.parse(address: "bazarr.example.net", key: key) == .failure(.scheme))
        #expect(BazarrConfig.parse(address: "https://user@bazarr.example.net", key: key) == .failure(.host))
        #expect(BazarrConfig.parse(address: "https://bazarr.example.net", key: "short") == .failure(.key))
    }

    @Test func statusReadsVersionsAndLinkedApps() async throws {
        let (client, transport) = Self.client { _ in
            json(["data": ["bazarr_version": "1.5.3", "sonarr_version": "4.0.15", "radarr_version": "unknown"]])
        }
        let status = try await client.status()
        #expect(status == BazarrStatus(version: "1.5.3", sonarrVersion: "4.0.15", radarrVersion: nil))
        let request = try #require(await transport.requests(to: "/bazarr/api/system/status").first)
        #expect(request.headers["X-API-KEY"] == Self.config.apiKey)
    }

    @Test func statusNamesTheFailure() async {
        await #expect(throws: BazarrError.badKey) { try await Self.client { _ in json([:], status: 401) }.0.status() }
        await #expect(throws: BazarrError.notBazarr) {
            try await Self.client { _ in PlexHTTPResponse(status: 200, body: Data("<html>".utf8)) }.0.status()
        }
        let offline = BazarrClient(config: Self.config, transport: FakeTransport { _, _ in throw NetworkFailure.offline })
        await #expect(throws: BazarrError.unreachable) { try await offline.status() }
    }

    /// The ids a request names under `name`, as `radarrid[]=2&radarrid[]=3`.
    static func ids(_ request: PlexRequest, _ name: String) -> [Int] {
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.filter { $0.name == name }.compactMap { $0.value.flatMap(Int.init) }
    }

    @Test func findsAMovieThroughTheTitleSearchThenTheWholeList() async throws {
        let movies = try JSONSerialization.data(withJSONObject: [
            ["radarrId": 1, "title": "The Matrix", "year": 1999, "imdbId": "tt0133093", "path": "/movies/The Matrix (1999)/matrix.mkv"],
            ["radarrId": 2, "title": "Dune", "year": 1984, "tmdbId": 841],
            ["radarrId": 3, "title": "Dune", "year": 2021, "tmdbId": 438631],
        ])
        let (client, transport) = Self.client { request in
            if request.url.path.hasSuffix("/api/system/searches") {
                return request.url.query("query") == "DUNE" ? json([["sonarrSeriesId": 9], ["radarrId": 2], ["radarrId": 3]]) : json([])
            }
            let all = try! JSONSerialization.jsonObject(with: movies) as! [[String: Any]]
            let named = Self.ids(request, "radarrid[]")
            return json(["data": named.isEmpty ? all : all.filter { named.contains($0["radarrId"] as! Int) }])
        }

        let byTitle = BazarrLookup(title: "DUNE", year: 2021, externalIDs: [], file: nil)
        #expect(try await client.find(byTitle) == .movie(radarrID: 3))
        #expect(await transport.requests(to: "/bazarr/api/movies").map { Self.ids($0, "radarrid[]") } == [[2, 3]])
        let byID = BazarrLookup(title: "Matrix", year: nil, externalIDs: ["imdb://tt0133093"], file: nil)
        #expect(try await client.find(byID) == .movie(radarrID: 1))
        await #expect(throws: BazarrError.notFound) {
            try await client.find(BazarrLookup(title: "Dune", year: nil, externalIDs: [], file: nil))
        }
    }

    @Test func findsAnEpisodeInTheShow() async throws {
        let (client, transport) = Self.client { request in
            if request.url.path.hasSuffix("/api/system/searches") {
                return json([["sonarrSeriesId": 7, "title": "Severance"]])
            }
            if request.url.path.hasSuffix("/api/series") {
                return json(["data": [["sonarrSeriesId": 7, "title": "Severance", "year": 2022, "tvdbId": 371980]]])
            }
            return json(["data": [
                ["sonarrEpisodeId": 70, "season": 1, "episode": 1],
                ["sonarrEpisodeId": 71, "season": 1, "episode": 2],
            ]])
        }
        let lookup = BazarrLookup(title: "Severance", year: 2022, externalIDs: ["tvdb://371980"], season: 1, episode: 2, file: nil)
        #expect(try await client.find(lookup) == .episode(seriesID: 7, episodeID: 71))
        let series = try #require(await transport.requests(to: "/bazarr/api/series").first)
        #expect(Self.ids(series, "seriesid[]") == [7])
        let episodes = try #require(await transport.requests(to: "/bazarr/api/episodes").first)
        #expect(episodes.url.query("seriesid[]") == "7")
    }

    @Test func searchListsOffersBestFirst() async throws {
        let (client, transport) = Self.client { _ in
            json(["data": [
                ["provider": "podnapisi", "subtitle": "b", "language": "en", "score": 61.5, "hearing_impaired": "False",
                 "forced": "False", "original_format": false, "release_info": ["Show.S01E02.WEB"], "uploader": ""],
                ["provider": "opensubtitlescom", "subtitle": "a", "language": "en", "score": 93.33, "hearing_impaired": "True",
                 "forced": "False", "original_format": false, "release_info": [], "uploader": "kim"],
                ["provider": "broken"],
            ]])
        }
        let offers = try await client.search(.episode(seriesID: 7, episodeID: 71))
        #expect(offers.map(\.provider) == ["opensubtitlescom", "podnapisi"])
        #expect(offers[0].isHearingImpaired && offers[0].uploader == "kim")
        #expect(offers[1].releases == ["Show.S01E02.WEB"] && offers[1].uploader == nil)
        #expect(offers.map(\.name) == ["OpenSubtitles.com", "Show.S01E02.WEB"])
        #expect(offers.map(\.providerName) == ["OpenSubtitles.com", "Podnapisi"])
        let request = try #require(await transport.requests(to: "/bazarr/api/providers/episodes").first)
        #expect(request.url.query("episodeid") == "71" && request.url.query("seriesid") == "7")
    }

    @Test func downloadPostsTheChosenOffer() async throws {
        let (client, transport) = Self.client { _ in PlexHTTPResponse(status: 204, body: Data()) }
        let offer = BazarrSubtitle(
            provider: "opensubtitlescom", subtitle: "a+b/c=", language: "en", isHearingImpaired: true, isForced: false,
            score: 93, releases: [], uploader: nil, usesOriginalFormat: false
        )
        try await client.download(offer, for: .movie(radarrID: 3))
        let request = try #require(await transport.requests(to: "/bazarr/api/providers/movies").first)
        #expect(request.method == .post)
        let body = String(decoding: request.body ?? Data(), as: UTF8.self)
        #expect(body == "forced=False&hi=True&original_format=False&provider=opensubtitlescom&radarrid=3&subtitle=a%2Bb%2Fc%3D")

        await #expect(throws: BazarrError.badCandidate) {
            try await Self.client { _ in json([:], status: 404) }.0.download(offer, for: .movie(radarrID: 3))
        }
        await #expect(throws: BazarrError.downloadFailed) {
            try await Self.client { _ in json([:], status: 500) }.0.download(offer, for: .movie(radarrID: 3))
        }
    }
}
