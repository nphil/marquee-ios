import Foundation
import Testing
@testable import MarqueeCore

struct RewatchQueueTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let server = "machine-1"

    /// Episode `number` of season `season` of `show`, as Plex sends it: last viewed `hours` before `now`
    /// (never, without), `offset` milliseconds in, and with its show's guid unless `guid` is false.
    static func fields(
        _ season: Int, _ number: Int, show: String = "100", viewed hours: Double? = nil, offset: Int = 0, guid: Bool = true
    ) -> [String: Any] {
        var fields: [String: Any] = [
            "ratingKey": "\(show)-\(season)-\(number)", "type": "episode", "title": "Episode \(number)",
            "grandparentRatingKey": show, "grandparentTitle": "Show \(show)", "parentRatingKey": "\(show)-s\(season)",
            "parentIndex": season, "index": number, "duration": 1_320_000, "viewOffset": offset,
        ]
        if guid { fields["grandparentGuid"] = "plex://show/\(show)" }
        if let hours {
            fields["lastViewedAt"] = Int(now.timeIntervalSince1970 - hours * 3600)
            fields["viewCount"] = 1
        }
        return fields
    }

    static func episode(
        _ season: Int, _ number: Int, show: String = "100", viewed hours: Double? = nil, offset: Int = 0, guid: Bool = true
    ) throws -> PlexMetadata {
        try decode(PlexMetadata.self, fields(season, number, show: show, viewed: hours, offset: offset, guid: guid))
    }

    /// The card for episode `number` of season `season`, which follows `viewed`, as `merged` makes it.
    static func card(_ season: Int, _ number: Int, after viewed: PlexMetadata, guid: Bool = true) throws -> PlexMetadata {
        var card = try episode(season, number, show: viewed.grandparentRatingKey ?? "100", guid: guid)
        card.rewatchedAt = viewed.lastViewedAt
        return card
    }

    static func queue(_ views: [PlexMetadata], plex: [PlexMetadata] = [], dismissed: RewatchDismissals = RewatchDismissals()) -> RewatchQueue {
        RewatchQueue(views: views, plex: plex, dismissed: dismissed, server: server, now: now)
    }

    /// Show 100 as a server lists it: Specials, a season of two episodes, an empty one and a season of one.
    static func listings() -> [String: PlexHTTPResponse] {
        func season(_ number: Int) -> [String: Any] {
            ["ratingKey": "100-s\(number)", "type": "season", "index": number, "title": "Season \(number)", "parentRatingKey": "100"]
        }
        let lists: [String: [[String: Any]]] = [
            "/library/metadata/100/children": [season(0), season(1), season(2), season(3)],
            "/library/metadata/100-s1/children": [fields(1, 1), fields(1, 2)],
            "/library/metadata/100-s2/children": [],
            "/library/metadata/100-s3/children": [fields(3, 1)],
        ]
        return lists.mapValues { container(["Metadata": $0]) }
    }

    static func library(_ listings: [String: PlexHTTPResponse]) -> (PlexLibrary, FakeTransport) {
        PlexLibraryTests.library { request in
            listings[request.url.path] ?? json([:], status: 404)
        }
    }

    // MARK: The rule

    @Test func finishedEpisodeOfAShowPlexForgotGetsItsNextEpisodeBack() throws {
        let finished = try Self.episode(3, 1, viewed: 2)
        let next = try Self.episode(3, 2)
        let queue = Self.queue([finished])

        #expect(queue.lookups.map(\.ratingKey) == [finished.ratingKey])
        let row = queue.merged(next: ["100": next])

        #expect(row.map(\.ratingKey) == [next.ratingKey])
        #expect(row.first?.rewatchedAt == finished.lastViewedAt)
        #expect(row.first?.viewOffset == 0)
    }

    @Test func partWatchedLatestViewIsPlexsToShow() throws {
        let queue = Self.queue([try Self.episode(3, 2, viewed: 1, offset: 600_000), try Self.episode(3, 1, viewed: 2)])
        #expect(queue.lookups.isEmpty)
    }

    @Test func partWatchedCardViewedAfterTheLatestViewStays() throws {
        let card = try Self.episode(2, 5, viewed: 1, offset: 600_000)
        let queue = Self.queue([try Self.episode(3, 1, viewed: 2)], plex: [card])

        #expect(queue.lookups.isEmpty)
        #expect(queue.merged(next: [:]).map(\.ratingKey) == [card.ratingKey])
    }

    @Test func partWatchedCardViewedBeforeTheLatestViewGivesWay() throws {
        let card = try Self.episode(2, 5, viewed: 9, offset: 600_000)
        let finished = try Self.episode(3, 1, viewed: 2)
        let next = try Self.episode(3, 2)
        let queue = Self.queue([finished], plex: [card])

        #expect(queue.lookups.map(\.ratingKey) == [finished.ratingKey])
        #expect(queue.merged(next: ["100": next]).map(\.ratingKey) == [next.ratingKey])
    }

    @Test func unwatchedCardAfterTheLatestViewStays() throws {
        let card = try Self.episode(3, 2)
        let queue = Self.queue([try Self.episode(3, 1, viewed: 2)], plex: [card])
        #expect(queue.lookups.isEmpty)
    }

    @Test func unwatchedCardBeforeTheLatestViewGivesWay() throws {
        let card = try Self.episode(1, 1)
        let next = try Self.episode(3, 2)
        let queue = Self.queue([try Self.episode(3, 1, viewed: 2)], plex: [card])

        #expect(queue.merged(next: ["100": next]).map(\.ratingKey) == [next.ratingKey])
    }

    @Test func showWithoutANextEpisodeKeepsPlexsEntry() throws {
        let card = try Self.episode(1, 1)
        let queue = Self.queue([try Self.episode(3, 1, viewed: 2)], plex: [card])
        #expect(queue.merged(next: [:]).map(\.ratingKey) == [card.ratingKey])
    }

    @Test func latestViewIsTheNewestEvenASpecial() throws {
        let views = [try Self.episode(0, 2, viewed: 1), try Self.episode(1, 3, viewed: 5), try Self.episode(1, 4, viewed: 9)]
        let latest = RewatchQueue.latestViews(in: views, since: Self.now.addingTimeInterval(-86_400))
        #expect(latest["100"]?.ratingKey == "100-0-2")
    }

    @Test func specialSeenLastLeadsToTheFirstEpisode() throws {
        let queue = Self.queue([try Self.episode(0, 2, viewed: 1)])

        #expect(queue.lookups.map(\.ratingKey) == ["100-0-2"])
        #expect(queue.merged(next: ["100": try Self.episode(1, 1)]).map(\.ratingKey) == ["100-1-1"])
    }

    @Test func episodesMarkedWatchedTogetherEndOnTheLastOne() throws {
        let views = [try Self.episode(1, 10, viewed: 3), try Self.episode(2, 1, viewed: 3), try Self.episode(1, 2, viewed: 3)]
        #expect(RewatchQueue.latestViews(in: views, since: .distantPast)["100"]?.ratingKey == "100-2-1")
    }

    @Test func viewsOlderThanSixteenWeeksDoNotCount() throws {
        let queue = Self.queue([try Self.episode(3, 1, viewed: 16 * 7 * 24 + 1)])
        #expect(queue.lookups.isEmpty)
    }

    @Test func nextEpisodeIsTheFirstAfterAndNeverASpecial() throws {
        let episodes = [try Self.episode(0, 1), try Self.episode(1, 2), try Self.episode(1, 1)]
        #expect(RewatchQueue.next(after: nil, in: episodes)?.ratingKey == "100-1-1")
        #expect(RewatchQueue.next(after: EpisodePosition(season: 1, number: 1), in: episodes)?.ratingKey == "100-1-2")
        #expect(RewatchQueue.next(after: EpisodePosition(season: 1, number: 2), in: episodes) == nil)
        #expect(RewatchQueue.next(after: EpisodePosition(season: 0, number: 3), in: episodes)?.ratingKey == "100-1-1")
    }

    // MARK: Removal

    @Test func removedCardStaysOffUntilTheShowIsViewedAgain() throws {
        let finished = try Self.episode(3, 1, viewed: 2)
        let card = try Self.card(3, 2, after: finished)
        var dismissed = RewatchDismissals()
        dismissed.dismiss(card, on: Self.server, now: Self.now)

        #expect(Self.queue([finished], dismissed: dismissed).lookups.isEmpty)
        #expect(Self.queue([try Self.episode(3, 2, viewed: 1), finished], dismissed: dismissed).lookups.map(\.ratingKey) == ["100-3-2"])

        dismissed.restore(card, on: Self.server)
        #expect(Self.queue([finished], dismissed: dismissed).lookups.count == 1)
    }

    @Test func removedCardIsKeptByTheShowsGuidOnAnyServer() throws {
        let finished = try Self.episode(3, 1, viewed: 2)
        var dismissed = RewatchDismissals()
        dismissed.dismiss(try Self.card(3, 2, after: finished), on: "machine-2", now: Self.now)

        #expect(dismissed.hides(finished, on: Self.server))
        #expect(!dismissed.hides(try Self.episode(3, 1, show: "200", viewed: 2), on: Self.server))
        let stored = try JSONDecoder().decode(RewatchDismissals.self, from: JSONEncoder().encode(dismissed))
        #expect(stored == dismissed)
    }

    @Test func removedCardOfAShowWithoutAGuidStaysOffForTheSessionOnly() throws {
        let finished = try Self.episode(3, 1, viewed: 2, guid: false)
        var dismissed = RewatchDismissals()
        dismissed.dismiss(try Self.card(3, 2, after: finished, guid: false), on: Self.server, now: Self.now)

        #expect(dismissed.hides(finished, on: Self.server))
        #expect(!dismissed.hides(finished, on: "machine-2"))
        let stored = try JSONDecoder().decode(RewatchDismissals.self, from: JSONEncoder().encode(dismissed))
        #expect(!stored.hides(finished, on: Self.server))
    }

    @Test func dismissalsForgetViewsThatNoLongerCount() throws {
        let old = try Self.episode(3, 1, viewed: (RewatchQueue.window + 1) / 3600)
        let recent = try Self.episode(3, 1, show: "200", viewed: 1)
        var dismissed = RewatchDismissals()
        dismissed.dismiss(try Self.card(3, 2, after: old), on: Self.server, now: try #require(old.lastViewedAt))
        dismissed.dismiss(try Self.card(3, 2, after: recent), on: Self.server, now: Self.now)

        #expect(!dismissed.hides(old, on: Self.server))
        #expect(dismissed.hides(recent, on: Self.server))
    }

    @Test func removingTheCardThatReplacedPlexsEntryRemovesThatEntryToo() throws {
        let stale = try Self.episode(2, 5, viewed: 9, offset: 600_000)
        let finished = try Self.episode(3, 1, viewed: 2)
        var dismissed = RewatchDismissals()
        dismissed.dismiss(try Self.card(3, 2, after: finished), on: Self.server, now: Self.now)
        let queue = Self.queue([finished], plex: [stale], dismissed: dismissed)

        #expect(queue.lookups.isEmpty)
        #expect(queue.merged(next: [:]).isEmpty)
    }

    @Test func removalLeavesPlexsEntryThatWasToStay() throws {
        let current = try Self.episode(2, 5, viewed: 1, offset: 600_000)
        let finished = try Self.episode(3, 1, viewed: 2)
        var dismissed = RewatchDismissals()
        dismissed.dismiss(try Self.card(3, 2, after: finished), on: Self.server, now: Self.now)
        let queue = Self.queue([finished], plex: [current], dismissed: dismissed)

        #expect(queue.merged(next: [:]).map(\.ratingKey) == [current.ratingKey])
    }

    // MARK: The row

    @Test func cardsSitAmongPlexsByWhenTheirShowWasLastViewed() throws {
        let newest = try Self.episode(4, 4, show: "1", viewed: 1, offset: 100_000)
        let oldest = try Self.episode(4, 4, show: "2", viewed: 5, offset: 100_000)
        let queue = Self.queue(
            [try Self.episode(2, 1, show: "3", viewed: 3), try Self.episode(2, 1, show: "4", viewed: 9)],
            plex: [newest, oldest]
        )
        let nexts = ["3": try Self.episode(2, 2, show: "3"), "4": try Self.episode(2, 2, show: "4")]

        #expect(queue.merged(next: nexts).map(\.ratingKey) == ["1-4-4", "3-2-2", "2-4-4", "4-2-2"])
    }

    @Test func unlistedPlexCardsAreNeverJumped() throws {
        let movie = try decode(PlexMetadata.self, ["ratingKey": "m", "type": "movie", "viewOffset": 1000])
        let queue = Self.queue([try Self.episode(3, 1, viewed: 2)], plex: [movie])
        #expect(queue.merged(next: ["100": try Self.episode(3, 2)]).map(\.ratingKey) == ["m", "100-3-2"])
    }

    @Test func atMostTenShowsAreLookedUpNewestFirst() throws {
        let views = try (1...12).map { try Self.episode(1, 1, show: "\($0)", viewed: Double($0)) }
        let lookups = Self.queue(views).lookups
        #expect(lookups.map(\.grandparentRatingKey) == (1...10).map { "\($0)" })
    }

    @Test func rowKeepsItsSizeWhenCardsAreAdded() throws {
        let plex = try (1...12).map { try Self.episode(1, 4, show: "p\($0)", viewed: Double($0) + 10, offset: 100_000) }
        let queue = Self.queue([try Self.episode(1, 1, show: "x", viewed: 2)], plex: plex)
        let row = queue.merged(next: ["x": try Self.episode(1, 2, show: "x")])

        #expect(row.count == 12)
        #expect(row.first?.ratingKey == "x-1-2")
        #expect(row.last?.ratingKey == "p11-1-4")
    }

    // MARK: Reading the server

    @Test func nextEpisodeInTheSameSeasonCostsOneRead() async throws {
        let (library, transport) = Self.library(Self.listings())
        let next = try await library.episode(after: try Self.episode(1, 1, viewed: 1))

        #expect(next?.ratingKey == "100-1-2")
        #expect(await transport.requests.map(\.url.path).filter { $0.hasPrefix("/library/metadata") } == ["/library/metadata/100-s1/children"])
    }

    @Test func nextEpisodeCrossesIntoTheNextSeasonWithEpisodes() async throws {
        let (library, transport) = Self.library(Self.listings())
        let next = try await library.episode(after: try Self.episode(1, 2, viewed: 1))

        #expect(next?.ratingKey == "100-3-1")
        #expect(await transport.requests.map(\.url.path).filter { $0.hasPrefix("/library/metadata") } == [
            "/library/metadata/100-s1/children", "/library/metadata/100/children",
            "/library/metadata/100-s2/children", "/library/metadata/100-s3/children",
        ])
    }

    @Test func seriesFinaleHasNoNextEpisode() async throws {
        let (library, _) = Self.library(Self.listings())
        #expect(try await library.episode(after: try Self.episode(3, 1, viewed: 1)) == nil)
    }

    @Test func nextEpisodeAfterASpecialIsTheFirstOfTheShow() async throws {
        let (library, transport) = Self.library(Self.listings())
        let next = try await library.episode(after: try Self.episode(0, 3, viewed: 1))

        #expect(next?.ratingKey == "100-1-1")
        // No special is next, so the Specials season is not read.
        #expect(await transport.requests.map(\.url.path).filter { $0.hasPrefix("/library/metadata") } == [
            "/library/metadata/100/children", "/library/metadata/100-s1/children",
        ])
    }

    @Test func failedReadIsNotTheEndOfTheSeries() async throws {
        var listings = Self.listings()
        listings["/library/metadata/100/children"] = nil
        let (library, _) = Self.library(listings)

        await #expect(throws: PlexError.self) { _ = try await library.episode(after: try Self.episode(1, 2, viewed: 1)) }
    }

    @Test func viewsAreAskedPerShowLibraryWithTheProfilesOwnWindow() async throws {
        let (library, transport) = PlexLibraryTests.library { request in
            switch request.url.path {
            case "/library/sections":
                container(["Directory": [
                    ["key": "1", "title": "Movies", "type": "movie"],
                    ["key": "2", "title": "Shows", "type": "show", "uuid": "tv"],
                    ["key": "3", "title": "Kids", "type": "show", "uuid": "kids"],
                ]])
            default:
                container(["totalSize": 1, "Metadata": [Self.fields(3, 1, viewed: 2)]])
            }
        }

        let views = await library.recentViews(hidden: ["kids"], since: Self.now.addingTimeInterval(-RewatchQueue.window))

        #expect(views.map(\.ratingKey) == ["100-3-1"])
        let asked = await transport.requests.filter { $0.url.path.hasSuffix("/all") }
        #expect(asked.map(\.url.path) == ["/library/sections/2/all"])
        let request = try #require(asked.first)
        #expect(request.url.query("type") == "4")
        #expect(request.url.query("sort") == "lastViewedAt:desc,season.index:desc,episode.index:desc")
        #expect(request.url.query("lastViewedAt>>") == String(Int(Self.now.timeIntervalSince1970) - 16 * 7 * 86_400))
        #expect(request.headers[PlexHeader.containerStart] == "0")
        #expect(request.headers[PlexHeader.containerSize] == "50")
    }

    @Test func aBingeOfOneShowDoesNotHideTheOthers() async throws {
        let (library, transport) = PlexLibraryTests.library { request in
            switch request.url.path {
            case "/library/sections":
                return container(["Directory": [["key": "2", "title": "Shows", "type": "show"]]])
            default:
                // The first page is all one show; with that show left out, another show's view is next.
                let page = request.url.query("show.id!") == "100"
                    ? [Self.fields(1, 1, show: "200", viewed: 2)]
                    : (1...50).map { Self.fields(1, $0, viewed: 1) }
                return container(["totalSize": 51, "Metadata": page])
            }
        }

        let views = await library.recentViews(hidden: [], since: .distantPast)

        #expect(views.count == 51 && views.last?.grandparentRatingKey == "200")
        #expect(await transport.requests.filter { $0.url.path.hasSuffix("/all") }.map { $0.url.query("show.id!") } == [nil, "100"])
    }

    @Test func viewsStopWhenAServerIgnoresTheShowsLeftOut() async throws {
        let (library, transport) = PlexLibraryTests.library { request in
            request.url.path == "/library/sections"
                ? container(["Directory": [["key": "2", "title": "Shows", "type": "show"]]])
                : container(["totalSize": 500, "Metadata": (1...50).map { Self.fields(1, $0, viewed: 1) }])
        }

        let views = await library.recentViews(hidden: [], since: .distantPast)

        #expect(views.count == 50)
        #expect(await transport.requests.filter { $0.url.path.hasSuffix("/all") }.count == 2)
    }

    @Test func recordedViewsReplayWhateverTheClockSays() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "rewatch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SnapshotStore(directory: folder)
        let scope = SnapshotScope(server: Self.server, profile: "alex")
        let (library, _) = PlexLibraryTests.library { _ in container(["totalSize": 1, "Metadata": [Self.fields(3, 1, viewed: 2)]]) }
        let recording = library.snapshotting(ResponseSnapshot(store: store, scope: scope, mode: .record))
        _ = try await recording.viewedEpisodes(in: "2", since: Self.now.addingTimeInterval(-86_400))

        var replayed: PlexPage<PlexMetadata>?
        for _ in 0..<200 where replayed == nil {
            // The write runs in the background.
            replayed = try? await library.snapshotting(ResponseSnapshot(store: store, scope: scope, mode: .replay)).viewedEpisodes(in: "2", since: Self.now)
            if replayed == nil { try await Task.sleep(for: .milliseconds(5)) }
        }

        #expect(replayed?.items.map(\.ratingKey) == ["100-3-1"])
    }

    // MARK: A run

    @Test func runPutsAShowWatchedAgainBeneathNewerCards() async throws {
        let (library, _) = PlexLibraryTests.library { request in
            switch request.url.path {
            case "/library/sections":
                container(["Directory": [["key": "2", "title": "Shows", "type": "show"]]])
            case "/library/sections/2/all":
                container(["totalSize": 1, "Metadata": [Self.fields(3, 1, viewed: 2)]])
            case "/library/metadata/100-s3/children":
                container(["Metadata": [Self.fields(3, 1), Self.fields(3, 2)]])
            default:
                container([:])
            }
        }
        let movie = try decode(PlexMetadata.self, [
            "ratingKey": "m", "type": "movie", "viewOffset": 1000, "lastViewedAt": Int(Self.now.timeIntervalSince1970) - 3600,
        ])
        let run = RewatchRun(library: library, hidden: [], now: Self.now)

        let row = try #require(await run.continuing([movie], dismissed: RewatchDismissals()))

        #expect(row.map(\.ratingKey) == ["m", "100-3-2"])
    }

    @Test func runWhoseLookupFailsLeavesPlexsRowAlone() async throws {
        let (library, _) = PlexLibraryTests.library { request in
            switch request.url.path {
            case "/library/sections":
                container(["Directory": [["key": "2", "title": "Shows", "type": "show"]]])
            case "/library/sections/2/all":
                container(["totalSize": 1, "Metadata": [Self.fields(3, 1, viewed: 2)]])
            default:
                json([:], status: 500)
            }
        }
        let card = try Self.episode(1, 1, show: "200")

        let row = await RewatchRun(library: library, hidden: [], now: Self.now).continuing([card], dismissed: RewatchDismissals())

        #expect(row?.map(\.ratingKey) == [card.ratingKey])
    }

    @Test func nextEpisodesOfSeveralShowsAreReadAtOnce() async throws {
        let meeting = Meeting(parties: 2)
        let transport = FakeTransport { request, _ in
            let parts = request.url.path.split(separator: "/").map(String.init)
            switch request.url.path {
            case "/identity":
                return container(["machineIdentifier": "machine-1"])
            case "/library/sections":
                return container(["Directory": [["key": "2", "title": "Shows", "type": "show"]]])
            case "/library/sections/2/all":
                return container(["totalSize": 2, "Metadata": [Self.fields(1, 1, show: "100", viewed: 2), Self.fields(1, 1, show: "200", viewed: 1)]])
            default:
                // A season's episodes come only once both shows have asked.
                await meeting.join()
                let show = parts[2].prefix { $0 != "-" }
                return container(["Metadata": [Self.fields(1, 1, show: String(show)), Self.fields(1, 2, show: String(show))]])
            }
        }
        let server = PlexServer(name: "Home", clientIdentifier: "machine-1", accessToken: "t", connections: [PlexLibraryTests.address])
        let run = RewatchRun(library: PlexLibrary(server: server, identity: testIdentity, transport: transport), hidden: [], now: Self.now)

        let row = try #require(await run.continuing([], dismissed: RewatchDismissals(), within: .seconds(5)))

        #expect(row.map(\.ratingKey) == ["200-1-2", "100-1-2"])
    }

    @Test func runStopsWaitingAfterItsLimit() async throws {
        let gate = Gate()
        let transport = FakeTransport { request, _ in
            if request.url.path == "/identity" { return container(["machineIdentifier": "machine-1"]) }
            await gate.wait()
            return container([:])
        }
        let server = PlexServer(name: "Home", clientIdentifier: "machine-1", accessToken: "t", connections: [PlexLibraryTests.address])
        let library = PlexLibrary(server: server, identity: testIdentity, transport: transport)
        let run = RewatchRun(library: library, hidden: [], now: Self.now)

        #expect(await run.continuing([], dismissed: RewatchDismissals(), within: .milliseconds(50)) == nil)

        await gate.open()
        #expect(await run.continuing([], dismissed: RewatchDismissals()) == [])
    }

    // MARK: A show's page

    /// Show 100, last viewed at episode 3·1 two hours ago, with a season 3 of two episodes.
    static func showPageLibrary() -> (PlexLibrary, FakeTransport) {
        PlexLibraryTests.library { request in
            switch request.url.path {
            case "/library/all":
                container(["totalSize": 2, "Metadata": [Self.fields(3, 1, viewed: 2), Self.fields(2, 4, viewed: 30)]])
            case "/library/metadata/100-s3/children":
                container(["Metadata": [Self.fields(3, 1), Self.fields(3, 2)]])
            default:
                container([:])
            }
        }
    }

    @Test func showWatchedThroughOffersTheEpisodeAfterItsLatestView() async throws {
        let (library, transport) = Self.showPageLibrary()
        let show = try decode(PlexMetadata.self, ["ratingKey": "100", "type": "show", "leafCount": 2, "viewedLeafCount": 2])

        let offered = await library.offeringRewatch(of: show)

        #expect(offered.onDeck?.ratingKey == "100-3-2")
        #expect(offered.onDeck?.rewatchedAt != nil)
        let request = try #require(await transport.requests(to: "/library/all").first)
        #expect(request.url.query("show.id") == "100")
    }

    @Test func plexsUpNextAfterTheLatestViewStaysOnAShowsPage() async throws {
        let (library, transport) = Self.showPageLibrary()
        let upNext = try Self.episode(3, 2)
        let show = try decode(PlexMetadata.self, ["ratingKey": "100", "type": "show", "viewedLeafCount": 1]).settingOnDeck(upNext)

        #expect(await library.offeringRewatch(of: show).onDeck == upNext)
        #expect(await transport.requests(to: "/library/metadata/100-s3/children").isEmpty)
    }

    @Test func plexsStaleUpNextGivesWayOnAShowsPage() async throws {
        let (library, _) = Self.showPageLibrary()
        // Part watched two months before the latest view.
        let stale = try Self.episode(1, 2, viewed: 24 * 60, offset: 100_000)
        let show = try decode(PlexMetadata.self, ["ratingKey": "100", "type": "show", "viewedLeafCount": 2]).settingOnDeck(stale)

        #expect(await library.offeringRewatch(of: show).onDeck?.ratingKey == "100-3-2")
    }

    @Test func showNobodyHasViewedIsNotAsked() async throws {
        let (library, transport) = Self.showPageLibrary()
        let show = try decode(PlexMetadata.self, ["ratingKey": "100", "type": "show", "viewedLeafCount": 0])

        #expect(await library.offeringRewatch(of: show) == show)
        #expect(await transport.requests(to: "/library/all").isEmpty)
    }

    @Test func showEndedByItsLatestViewIsLeftAsItIs() async throws {
        let (library, _) = PlexLibraryTests.library { request in
            request.url.path == "/library/all"
                ? container(["totalSize": 1, "Metadata": [Self.fields(3, 1, viewed: 2)]])
                : container(["Metadata": [Self.fields(3, 1)]])
        }
        let show = try decode(PlexMetadata.self, ["ratingKey": "100", "type": "show", "viewedLeafCount": 1])

        #expect(await library.offeringRewatch(of: show).onDeck == nil)
    }

    @Test func showLastViewedAtASpecialOffersItsFirstEpisode() async throws {
        var listings = Self.listings()
        listings["/library/all"] = container(["totalSize": 1, "Metadata": [Self.fields(0, 1, viewed: 1)]])
        let (library, _) = Self.library(listings)
        let show = try decode(PlexMetadata.self, ["ratingKey": "100", "type": "show", "viewedLeafCount": 1])

        #expect(await library.offeringRewatch(of: show).onDeck?.ratingKey == "100-1-1")
    }
}

/// Lets each caller of `join()` go on only once `parties` of them have called it.
private actor Meeting {
    private let parties: Int
    private var arrived = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(parties: Int) {
        self.parties = parties
    }

    func join() async {
        arrived += 1
        if arrived >= parties {
            waiting.forEach { $0.resume() }
            waiting = []
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }
}
