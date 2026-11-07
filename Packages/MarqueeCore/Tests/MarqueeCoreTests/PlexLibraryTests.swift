import Foundation
import Testing
@testable import MarqueeCore

struct PlexLibraryTests {
    static let address = PlexConnection(uri: URL(string: "https://10-0-0-2.abc.plex.direct:32400")!, isLocal: true)

    /// A library on one address; `/identity` answers as the server and everything else from `answer`.
    static func library(_ answer: @escaping @Sendable (PlexRequest) -> PlexHTTPResponse) -> (PlexLibrary, FakeTransport) {
        let transport = FakeTransport { request, _ in
            request.url.path == "/identity" ? container(["machineIdentifier": "machine-1"]) : answer(request)
        }
        let server = PlexServer(name: "Home", clientIdentifier: "machine-1", accessToken: "server-token", connections: [address])
        return (PlexLibrary(server: server, identity: testIdentity, transport: transport), transport)
    }

    @Test func gridPageAsksForOneWindowOfTheFilteredList() async throws {
        let (library, transport) = Self.library { _ in
            container(["size": 2, "totalSize": 130, "Metadata": [["ratingKey": "1"], ["ratingKey": "2"]]])
        }
        let query = SectionQuery(type: .show, sort: .recentlyAdded, unwatchedOnly: true)

        let page = try await library.items(in: "3", query: query, start: 60)

        #expect(page.totalSize == 130 && page.items.map(\.ratingKey) == ["1", "2"])
        let request = try #require(await transport.requests(to: "/library/sections/3/all").first)
        #expect(request.headers[PlexHeader.containerStart] == "60")
        #expect(request.headers[PlexHeader.containerSize] == "60")
        #expect(request.headers[PlexHeader.token] == "server-token")
        #expect(request.url.query(PlexHeader.token) == nil)
        #expect(request.url.query("type") == "2")
        #expect(request.url.query("sort") == "addedAt:desc")
        #expect(request.url.query("unwatchedLeaves") == "1")
    }

    @Test func jumpBarLettersStartWhereEarlierLettersEnd() async throws {
        let (library, transport) = Self.library { _ in
            container(["Directory": [
                ["key": "%23", "title": "#", "size": 3],
                ["key": "A", "title": "A", "size": "5"],
                ["key": "C", "title": "C", "size": 2],
            ]])
        }

        let letters = try await library.alphabetIndex(in: "1", query: SectionQuery(type: .movie, unwatchedOnly: true))

        #expect(letters.map(\.character) == ["#", "A", "C"])
        #expect(letters.map(\.offset) == [0, 3, 8])
        let request = try #require(await transport.requests(to: "/library/sections/1/firstCharacter").first)
        #expect(request.url.query("unwatched") == "1" && request.url.query("type") == "1")
    }

    @Test func genreFilterIsSentAsTheGenreKey() throws {
        let comedy = try decode(PlexDirectory.self, ["key": "27", "title": "Comedy"])

        let items = SectionQuery(type: .movie, genre: comedy).queryItems

        #expect(items.contains(URLQueryItem(name: "genre", value: "27")))
    }

    @Test func sortRunsEitherWayFromItsFirstOrderAndRandomHasNone() {
        #expect(SectionQuery(type: .movie).sortKey == "titleSort")
        #expect(SectionQuery(type: .movie, reversed: true).sortKey == "titleSort:desc")
        #expect(SectionQuery(type: .movie, sort: .audienceRating).sortKey == "audienceRating:desc")
        #expect(SectionQuery(type: .movie, sort: .recentlyWatched, reversed: true).sortKey == "lastViewedAt")
        #expect(SectionQuery(type: .movie, sort: .random, reversed: true).sortKey == "random")
        #expect(SectionQuery(type: .movie).isAlphabetical && !SectionQuery(type: .movie, reversed: true).isAlphabetical)
    }

    @Test func personTitlesComeFromEveryLibraryInOneRequest() async throws {
        let (library, transport) = Self.library { _ in
            container(["Metadata": [["ratingKey": "1", "type": "movie"], ["ratingKey": "2", "type": "show"]]])
        }

        let titles = try await library.titles(ofPerson: "161")

        #expect(titles.map(\.type) == [.movie, .show])
        #expect(await transport.requests(to: "/library/people/161/media").count == 1)
    }

    @Test func extrasCarryTheirKind() async throws {
        let (library, transport) = Self.library { _ in
            container(["Metadata": [["ratingKey": "70", "type": "clip", "subtype": "trailer", "extraType": 1]]])
        }

        let extras = try await library.extras(of: "12")

        #expect(extras.first?.type == .clip && extras.first?.extraType == 1 && extras.first?.subtype == "trailer")
        #expect(await transport.requests(to: "/library/metadata/12/extras").count == 1)
    }

    @Test func serverRootSaysWhetherDeletingIsAllowedAndPlexPass() async throws {
        let (library, _) = Self.library { _ in container(["allowMediaDeletion": true, "myPlexSubscription": "1"]) }
        let (bare, _) = Self.library { _ in container([:]) }

        #expect(try await library.serverInfo() == PlexServerInfo(allowsMediaDeletion: true, hasPlexPass: true))
        #expect(try await bare.serverInfo() == PlexServerInfo())
    }

    @Test func deleteRemovesATitleOrOneVersionAndSurfacesARefusal() async throws {
        let (library, transport) = Self.library { _ in json([String: Any]()) }
        let (refusing, _) = Self.library { _ in json([String: Any](), status: 403) }

        try await library.delete("12")
        try await library.deleteVersion(5, of: "12")

        #expect(await transport.requests(to: "/library/metadata/12").map(\.method) == [.delete])
        #expect(await transport.requests(to: "/library/metadata/12/media/5").map(\.method) == [.delete])
        await #expect(throws: PlexError.server(status: 403, message: nil)) { try await refusing.delete("12") }
    }

    @Test func listOfAServerKeyKeepsItsQueryAndPages() async throws {
        let (library, transport) = Self.library { _ in
            container(["size": 1, "totalSize": 75, "Metadata": [["ratingKey": "9"]]])
        }

        let page = try await library.list("/hubs/home/recentlyAdded?type=2&personal=1", start: 60)

        #expect(page.totalSize == 75 && page.items.map(\.ratingKey) == ["9"])
        let request = try #require(await transport.requests(to: "/hubs/home/recentlyAdded").first)
        #expect(request.url.query("type") == "2" && request.url.query("personal") == "1")
        #expect(request.headers[PlexHeader.containerStart] == "60")
    }

    @Test func showDetailCarriesTheEpisodeToPlayNext() async throws {
        let (library, transport) = Self.library { _ in
            container(["Metadata": [[
                "ratingKey": "5", "type": "show", "subtype": "show",
                "OnDeck": ["Metadata": ["ratingKey": "51", "type": "episode", "viewOffset": 1000]],
            ]]])
        }

        let show = try await library.metadata("5")

        #expect(show.onDeck?.ratingKey == "51" && show.onDeck?.viewOffset == 1000)
        let request = try #require(await transport.requests(to: "/library/metadata/5").first)
        #expect(request.url.query("includeOnDeck") == "1")
        let movie = try decode(PlexMetadata.self, ["ratingKey": "6", "type": "movie"])
        #expect(movie.onDeck == nil)
    }

    @Test func episodeQueueContinuesThroughTheShow() async throws {
        let (library, transport) = Self.library { _ in
            container([
                "playQueueID": 88, "playQueueSelectedItemID": 502, "playQueueTotalCount": 24,
                "Metadata": [
                    ["ratingKey": "11", "type": "episode", "playQueueItemID": 501],
                    ["ratingKey": "12", "type": "episode", "playQueueItemID": 502],
                    ["ratingKey": "13", "type": "episode", "playQueueItemID": 503],
                ],
            ])
        }
        let episode = try decode(PlexMetadata.self, ["ratingKey": "12", "type": "episode"])

        let queue = try await library.createPlayQueue(for: episode)

        let request = try #require(await transport.requests(to: "/playQueues").first)
        #expect(request.method == .post)
        #expect(request.url.query("continuous") == "1")
        #expect(request.url.query("uri") == "server://machine-1/com.plexapp.plugins.library/library/metadata/12")
        let current = try #require(queue.selectedItem)
        #expect(current.ratingKey == "12" && queue.totalCount == 24)
        #expect(queue.item(after: current)?.ratingKey == "13")
        #expect(queue.item(before: current)?.ratingKey == "11")
        #expect(queue.item(after: queue.items[2]) == nil)
    }

    @Test func timelineReportCarriesPositionQueueItemAndSession() async throws {
        let (library, transport) = Self.library { _ in container([:]) }
        let item = try decode(PlexMetadata.self, ["ratingKey": "12", "key": "/library/metadata/12", "playQueueItemID": 502])

        try await library.reportTimeline(
            TimelineUpdate(item: item, state: .paused, time: 61_000, duration: 1_450_000, sessionIdentifier: "s-1")
        )

        let request = try #require(await transport.requests(to: "/:/timeline").first)
        #expect(request.url.query("state") == "paused")
        #expect(request.url.query("time") == "61000" && request.url.query("duration") == "1450000")
        #expect(request.url.query("key") == "/library/metadata/12")
        #expect(request.url.query("playQueueItemID") == "502")
        #expect(request.headers[PlexHeader.sessionIdentifier] == "s-1")
    }

    @Test func timelineIsReportedOnStateChangesAndEveryInterval() {
        var cadence = TimelineCadence(interval: .seconds(10))
        let start = ContinuousClock.now

        let reports = [
            cadence.shouldReport(.playing, at: start),
            cadence.shouldReport(.playing, at: start + .seconds(9)),
            cadence.shouldReport(.playing, at: start + .seconds(10)),
            cadence.shouldReport(.paused, at: start + .seconds(11)),
            cadence.shouldReport(.stopped, at: start + .seconds(12)),
            cadence.shouldReport(.stopped, at: start + .seconds(40)),
        ]

        #expect(reports == [true, false, true, true, true, false])
    }

    @Test func artworkIsRequestedAtScreenPixelsWithoutToken() throws {
        let base = try #require(URL(string: "https://10-0-0-2.abc.plex.direct:32400/"))

        let url = try #require(PlexImageURL.transcoded("/library/metadata/12/thumb/1699", base: base, width: 100.4, height: 150, scale: 3))

        #expect(url.absoluteString == "https://10-0-0-2.abc.plex.direct:32400/photo/:/transcode"
            + "?width=302&height=450&minSize=1&upscale=1&url=%2Flibrary%2Fmetadata%2F12%2Fthumb%2F1699")
        #expect(PlexImageURL.transcoded("", base: base, width: 100, height: 150, scale: 3) == nil)
    }

    @Test func transcodeURLCarriesTokenAndClientIdentity() async throws {
        let (library, _) = Self.library { _ in container([:]) }
        let item = try decode(PlexMetadata.self, [
            "ratingKey": "12", "key": "/library/metadata/12",
            "Media": [["id": 1, "bitrate": 4000, "width": 1920, "height": 1080, "Part": [["id": 7]]]],
        ])
        let signs = try Fixture.tracks([Fixture.subtitle(3, "eng", title: "Signs", codec: "pgs")]).subtitles[0]
        let route = PlaybackRoute(
            kind: .serverTranscode, reasons: [.videoCodec("vc1")], audio: nil, audioIsStandIn: false,
            convertsAudio: false, reencodesVideo: true, subtitle: .burnedIn(signs)
        )
        let request = TranscodeRequest(item: item, route: route, offset: 90, session: "s-1")
        var slow = route
        slow.maxVideoBitrateKbps = 3_000
        slow.videoResolution = "1280x720"

        let url = try await library.transcodeURL(request)

        #expect(url.path == "/video/:/transcode/universal/start.m3u8")
        #expect(url.query(PlexHeader.token) == "server-token")
        #expect(url.query(PlexHeader.clientIdentifier) == "client-1")
        #expect(url.query("location") == "lan")
        #expect(url.query("path") == "/library/metadata/12")
        #expect(url.query("directStream") == "0" && url.query("subtitles") == "burn")
        #expect(url.query("maxVideoBitrate") == "8000" && url.query("videoResolution") == "1920x1080")
        #expect(url.query("offset") == "90.0")
        #expect(url.query("session") == "s-1")
        #expect(TranscodeRequest(item: item, route: slow).maxVideoBitrateKbps == 3_000)
        #expect(TranscodeRequest(item: item, route: slow).videoResolution == "1280x720")
    }

    @Test func audioEnhancementsAreSentOnlyWhenOnAndConvertTheAudio() throws {
        let item = try decode(PlexMetadata.self, ["ratingKey": "12", "Media": [["id": 1, "Part": [["id": 7]]]]])
        let route = PlaybackRoute(
            kind: .serverTranscode, reasons: [.audioEnhancement], audio: nil, audioIsStandIn: false,
            convertsAudio: false, reencodesVideo: false, subtitle: .none
        )
        var boostedRoute = route
        boostedRoute.audioEnhancements = .boostDialog
        let plain = Dictionary(uniqueKeysWithValues: TranscodeRequest(item: item, route: route).queryItems(location: "lan").map { ($0.name, $0.value) })
        let boosted = Dictionary(
            uniqueKeysWithValues: TranscodeRequest(item: item, route: boostedRoute).queryItems(location: "lan").map { ($0.name, $0.value) }
        )

        #expect(plain["boostDialog"] == nil && plain["normalizeLoudness"] == nil && plain["directStreamAudio"] == "1")
        #expect(boosted["boostDialog"] == "1" && boosted["normalizeLoudness"] == nil && boosted["directStreamAudio"] == "0")
        #expect(boosted["directStream"] == "1")
    }
}
