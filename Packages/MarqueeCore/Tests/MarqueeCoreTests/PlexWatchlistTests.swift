import Foundation
import Testing
@testable import MarqueeCore

struct PlexWatchlistTests {
    func watchlist(_ transport: FakeTransport) -> PlexWatchlist {
        PlexWatchlist(http: PlexHTTPClient(identity: testIdentity, token: "account-token", transport: transport, retryDelay: .zero))
    }

    @Test func pageComesFromDiscoverWithTheAccountToken() async throws {
        let transport = FakeTransport { _, _ in
            container(["size": 1, "totalSize": 61, "Metadata": [["ratingKey": "5d776b59", "guid": "plex://movie/5d776b59"]]])
        }

        let page = try await watchlist(transport).items(start: 60)

        #expect(page.totalSize == 61 && page.items.first?.ratingKey == "5d776b59")
        let request = try #require(await transport.requests(to: "/library/sections/watchlist/all").first)
        #expect(request.url.host() == "discover.provider.plex.tv")
        #expect(request.headers[PlexHeader.token] == "account-token")
        #expect(request.headers[PlexHeader.containerStart] == "60")
    }

    @Test func titleIsOnTheListOnlyWithAWatchlistDate() async throws {
        let transport = FakeTransport { request, _ in
            request.url.path.contains("/on-list/")
                ? container(["UserState": [["ratingKey": "on-list", "watchlistedAt": 1_730_000_000]]])
                : container(["UserState": [["ratingKey": "off-list", "viewCount": 1]]])
        }
        let list = watchlist(transport)

        #expect(try await list.contains(guid: "plex://movie/on-list"))
        #expect(try await !list.contains(guid: "plex://show/off-list"))
        #expect(try await !list.contains(guid: "com.plexapp.agents.imdb://tt0118799"))
        #expect(await transport.requests.count == 2)
    }

    @Test func addingSendsTheCatalogueKey() async throws {
        let transport = FakeTransport { _, _ in json([:]) }

        try await watchlist(transport).add(guid: "plex://movie/5d776b59")

        let request = try #require(await transport.requests(to: "/actions/addToWatchlist").first)
        #expect(request.method == .put && request.url.query("ratingKey") == "5d776b59")
    }
}
