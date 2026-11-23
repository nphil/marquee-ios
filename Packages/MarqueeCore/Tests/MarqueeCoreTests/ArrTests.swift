import Foundation
import Testing
@testable import MarqueeCore

struct ArrTests {
    static let address = URL(string: "https://arr.example.net/base")!
    static let key = "0123456789abcdef0123456789abcdef"

    static func client(
        _ kind: ArrKind, _ answer: @escaping @Sendable (PlexRequest) throws -> PlexHTTPResponse
    ) -> (ArrClient, FakeTransport) {
        let transport = FakeTransport { request, _ in try answer(request) }
        return (ArrClient(kind: kind, config: ArrConfig(address: address, apiKey: key), transport: transport), transport)
    }

    static func body(_ request: PlexRequest?) -> [String: Any] {
        request?.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    static let dune = ArrTitle.movie(tmdbID: 438_631, title: "Dune", year: 2021)
    static let prophecy = ArrTitle.series(tvdbID: 121_361, title: "Dune: Prophecy")

    @Test func theAddressAndKeyFollowBazarrsRules() {
        #expect((try? ArrConfig.parse(address: " https://radarr.example.net/radarr ", key: " \(Self.key) ").get()) != nil)
        #expect((try? ArrConfig.parse(address: "http://192.168.1.50:7878", key: Self.key).get()) != nil)
        #expect(ArrConfig.parse(address: "http://radarr.example.net", key: Self.key) == .failure(.plaintext))
        #expect(ArrConfig.parse(address: "radarr.example.net", key: Self.key) == .failure(.scheme))
        #expect(ArrConfig.parse(address: "https://radarr.example.net", key: "short") == .failure(.key))
    }

    @Test func theVersionNeedsTheKeyAndTheRightService() async throws {
        let (radarr, transport) = Self.client(.radarr) { _ in json(["appName": "Radarr", "version": "5.14.0.9383"]) }
        #expect(try await radarr.version() == "5.14.0.9383")
        let request = try #require(await transport.requests(to: "/base/api/v3/system/status").first)
        #expect(request.headers["X-Api-Key"] == Self.key)
        #expect(request.restrictToOrigin)

        await #expect(throws: ArrError.notArr) {
            try await Self.client(.sonarr) { _ in json(["appName": "Radarr", "version": "5.14.0.9383"]) }.0.version()
        }
        await #expect(throws: ArrError.badKey) {
            try await Self.client(.radarr) { _ in json([:], status: 401) }.0.version()
        }
        await #expect(throws: ArrError.unreachable) {
            try await Self.client(.radarr) { _ in throw NetworkFailure.cannotConnect }.0.version()
        }
        await #expect(throws: ArrError.timedOut) {
            try await Self.client(.radarr) { _ in throw NetworkFailure.timedOut }.0.version()
        }
    }

    @Test func aMovieInRadarrIsRemovedWithItsFilesAndExcluded() async throws {
        let (client, transport) = Self.client(.radarr) { request in
            switch (request.method, request.url.path) {
            case (.get, "/base/api/v3/movie"): json([["id": 5, "tmdbId": 438_631]])
            case (.delete, "/base/api/v3/movie/5"): json([:])
            default: json([:], status: 500)
            }
        }

        #expect(try await client.remove(Self.dune))

        let lookup = try #require(await transport.requests(to: "/base/api/v3/movie").first)
        #expect(lookup.url.query("tmdbId") == "438631")
        #expect(lookup.headers["X-Api-Key"] == Self.key)
        let delete = try #require(await transport.requests(to: "/base/api/v3/movie/5").first)
        #expect(delete.method == .delete)
        #expect(delete.url.query("deleteFiles") == "true")
        #expect(delete.url.query("addImportExclusion") == "true")
        #expect(delete.timeout == ArrClient.removeTimeout)
        #expect(await transport.requests(to: "/base/api/v3/exclusions").isEmpty)
    }

    @Test func aMovieRadarrNoLongerHoldsIsOnlyExcluded() async throws {
        let (client, transport) = Self.client(.radarr) { request in
            switch (request.method, request.url.path) {
            case (.get, "/base/api/v3/movie"): json([[String: Any]]())
            case (.post, "/base/api/v3/exclusions"): json([:], status: 201)
            default: json([:], status: 500)
            }
        }

        #expect(try await client.remove(Self.dune) == false)

        let post = try #require(await transport.requests(to: "/base/api/v3/exclusions").first)
        let body = Self.body(post)
        #expect(body["tmdbId"] as? Int == 438_631)
        #expect(body["movieTitle"] as? String == "Dune")
        #expect(body["movieYear"] as? Int == 2021)
        #expect(post.headers["Content-Type"] == "application/json")
        #expect(await transport.requests.filter { $0.method == .delete }.isEmpty)
    }

    @Test func anExclusionThatIsThereAlreadyIsWhatWasWanted() async throws {
        let already = json([["propertyName": "TmdbId", "errorMessage": "This exclusion has already been added."]], status: 400)
        let (client, _) = Self.client(.radarr) { request in request.method == .get ? json([[String: Any]]()) : already }
        #expect(try await client.remove(Self.dune) == false)

        let other = json([["errorMessage": "Movie title is required"]], status: 400)
        let (strict, _) = Self.client(.radarr) { request in request.method == .get ? json([[String: Any]]()) : other }
        await #expect(throws: ArrError.failed(status: 400, message: "Movie title is required")) {
            try await strict.remove(Self.dune)
        }
    }

    @Test func aSeriesInSonarrIsRemovedWithItsFilesAndExcluded() async throws {
        let (client, transport) = Self.client(.sonarr) { request in
            switch (request.method, request.url.path) {
            case (.get, "/base/api/v3/series"): json([["id": 9, "tvdbId": 121_361]])
            case (.delete, "/base/api/v3/series/9"): json([:])
            default: json([:], status: 500)
            }
        }

        #expect(try await client.remove(Self.prophecy))

        let lookup = try #require(await transport.requests(to: "/base/api/v3/series").first)
        #expect(lookup.url.query("tvdbId") == "121361")
        let delete = try #require(await transport.requests(to: "/base/api/v3/series/9").first)
        #expect(delete.method == .delete)
        #expect(delete.url.query("deleteFiles") == "true")
        #expect(delete.url.query("addImportListExclusion") == "true")
        #expect(await transport.requests(to: "/base/api/v3/importlistexclusion").isEmpty)
    }

    @Test func aSeriesSonarrNoLongerHoldsIsOnlyExcluded() async throws {
        let (client, transport) = Self.client(.sonarr) { request in
            switch (request.method, request.url.path) {
            case (.get, "/base/api/v3/series"): json([[String: Any]]())
            case (.post, "/base/api/v3/importlistexclusion"): json([:], status: 201)
            default: json([:], status: 500)
            }
        }

        #expect(try await client.remove(Self.prophecy) == false)

        let post = try #require(await transport.requests(to: "/base/api/v3/importlistexclusion").first)
        #expect(Self.body(post)["tvdbId"] as? Int == 121_361)
        #expect(Self.body(post)["title"] as? String == "Dune: Prophecy")
    }

    @Test func aMovieGoneBetweenTheLookupAndTheDeleteIsExcludedAnyway() async throws {
        let (client, transport) = Self.client(.radarr) { request in
            switch (request.method, request.url.path) {
            case (.get, "/base/api/v3/movie"): json([["id": 5]])
            case (.delete, "/base/api/v3/movie/5"): json([:], status: 404)
            case (.post, "/base/api/v3/exclusions"): json([:], status: 201)
            default: json([:], status: 500)
            }
        }

        #expect(try await client.remove(Self.dune) == false)
        #expect(await transport.requests(to: "/base/api/v3/exclusions").count == 1)
    }

    @Test func refusalsAndWrongServicesAreNamed() async {
        await #expect(throws: ArrError.badKey) {
            try await Self.client(.radarr) { _ in json([:], status: 401) }.0.remove(Self.dune)
        }
        await #expect(throws: ArrError.notArr) {
            try await Self.client(.radarr) { _ in json([:], status: 404) }.0.remove(Self.dune)
        }
        await #expect(throws: ArrError.notArr) {
            try await Self.client(.radarr) { _ in json([:]) }.0.remove(Self.prophecy)
        }
        await #expect(throws: ArrError.failed(status: 500, message: "Disk is busy")) {
            try await Self.client(.radarr) { request in
                request.method == .get ? json([["id": 5]]) : json(["message": "Disk is busy"], status: 500)
            }.0.remove(Self.dune)
        }
    }

    @Test func servicesRouteATitleToTheClientOfItsKind() async throws {
        let (radarr, radarrTransport) = Self.client(.radarr) { request in
            request.method == .get ? json([["id": 5]]) : json([:])
        }
        let services = ArrServices(radarr: radarr)

        #expect(services.isConnected(.radarr) && !services.isConnected(.sonarr))
        #expect(try await services.remove(Self.dune))
        #expect(await radarrTransport.requests.count == 2)
        await #expect(throws: ArrError.unreachable) { try await services.remove(Self.prophecy) }
    }
}
