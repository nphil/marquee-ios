import Foundation
import Testing
@testable import MarqueeCore

/// Scripted server and account: every call is logged in order, in `events`.
private actor Script: DeletionServer, WatchlistAccount, ArrAccount, RequestsAccount {
    struct Config {
        var deleteError: PlexError?
        /// The item answers 404 from the Nth metadata read on (1-based), as after a delete that timed out.
        var goneAfterReads: Int?
        var leavesError: PlexError?
        var watchlisted = true
        var containsFailures = 0
        var removeError: PlexError?
        var removeFailures = 0
        /// What `externalIDs` lists, by rating key.
        var ids: [String: [String]] = [:]
        var idsFailures = 0
        var arrError: ArrError?
        var arrFailures = 0
        var requestsError: SeerrError?
        var requestsFailures = 0
    }

    private(set) var events: [String] = []
    private let items: [String: PlexMetadata]
    private let leaves: [PlexMetadata]
    private let arrKinds: Set<ArrKind>
    private var config: Config
    private var reads = 0

    init(
        items: [PlexMetadata] = [], leaves: [PlexMetadata] = [], arrKinds: Set<ArrKind> = [.radarr, .sonarr],
        _ config: Config = Config()
    ) {
        self.items = Dictionary(uniqueKeysWithValues: items.map { ($0.ratingKey, $0) })
        self.leaves = leaves
        self.arrKinds = arrKinds
        self.config = config
    }

    func note(_ event: String) {
        events.append(event)
    }

    func metadata(_ ratingKey: String) async throws -> PlexMetadata {
        reads += 1
        events.append("read \(ratingKey)")
        if let after = config.goneAfterReads, reads >= after { throw PlexError.server(status: 404, message: nil) }
        guard let item = items[ratingKey] else { throw PlexError.server(status: 404, message: nil) }
        return item
    }

    func deleteItem(_ ratingKey: String) async throws {
        events.append("delete \(ratingKey)")
        if let error = config.deleteError { throw error }
    }

    func allLeaves(of ratingKey: String) async throws -> [PlexMetadata] {
        events.append("leaves \(ratingKey)")
        if let error = config.leavesError { throw error }
        return leaves
    }

    func contains(guid: String) async throws -> Bool {
        events.append("contains \(guid)")
        if config.containsFailures > 0 {
            config.containsFailures -= 1
            throw PlexError.unreachable(.timedOut)
        }
        return config.watchlisted
    }

    func remove(guid: String) async throws {
        events.append("remove \(guid)")
        if config.removeFailures > 0 {
            config.removeFailures -= 1
            throw PlexError.unreachable(.connectionLost)
        }
        if let error = config.removeError { throw error }
    }

    func externalIDs(_ ratingKey: String) async throws -> [String] {
        events.append("ids \(ratingKey)")
        if config.idsFailures > 0 {
            config.idsFailures -= 1
            throw PlexError.unreachable(.timedOut)
        }
        return config.ids[ratingKey] ?? []
    }

    nonisolated func isConnected(_ kind: ArrKind) -> Bool {
        arrKinds.contains(kind)
    }

    func remove(_ title: ArrTitle) async throws -> Bool {
        switch title {
        case .movie(let tmdbID, let name, let year): events.append("radarr \(tmdbID) \(name) \(year.map(String.init) ?? "-")")
        case .series(let tvdbID, let name): events.append("sonarr \(tvdbID) \(name)")
        }
        if config.arrFailures > 0 {
            config.arrFailures -= 1
            throw ArrError.unreachable
        }
        if let error = config.arrError { throw error }
        return true
    }

    func removeMedia(_ kind: SeerrMediaKind, tmdbID: Int) async throws -> Bool {
        events.append("seerr \(kind.rawValue) \(tmdbID)")
        if config.requestsFailures > 0 {
            config.requestsFailures -= 1
            throw SeerrError.unreachable
        }
        if let error = config.requestsError { throw error }
        return true
    }
}

/// Records each wait and returns at once.
private actor Waits {
    private(set) var all: [Duration] = []
    func add(_ duration: Duration) { all.append(duration) }
}

struct MediaDeletionTests {
    private static let movieIDs = ["imdb://tt13433812", "tmdb://438631", "tvdb://77"]
    private static let showIDs = ["imdb://tt10872600", "tmdb://90", "tvdb://121361"]

    private static func movie(_ key: String = "10", guid: String? = "plex://movie/abc", year: Int? = nil) throws -> PlexMetadata {
        try decode(PlexMetadata.self, ["ratingKey": key, "type": "movie", "guid": guid as Any, "title": "Charge", "year": year as Any])
    }

    private static func show(_ key: String = "30") throws -> PlexMetadata {
        try decode(PlexMetadata.self, ["ratingKey": key, "type": "show", "guid": "plex://show/xyz", "title": "Dune Prophecy"])
    }

    private static func episode(_ key: String = "22", show: String? = "plex://show/xyz", showKey: String? = "20") throws -> PlexMetadata {
        try decode(PlexMetadata.self, [
            "ratingKey": key, "type": "episode", "parentRatingKey": "21", "grandparentRatingKey": showKey as Any,
            "grandparentGuid": show as Any, "guid": "plex://episode/e1", "grandparentTitle": "Dune Prophecy",
        ])
    }

    private static func run(
        _ item: PlexMetadata,
        on script: Script,
        watchlist: Bool = true,
        arr: Bool = false,
        requests: Bool = false,
        alreadyDeleted: DeletedTitles = DeletedTitles()
    ) async -> (MediaDeletionResult, [Duration]) {
        let waits = Waits()
        let deletion = MediaDeletion(
            server: script, watchlist: watchlist ? script : nil, arr: arr ? script : nil, requests: requests ? script : nil
        ) { await waits.add($0) }
        let result = await deletion.delete(item, alreadyDeleted: alreadyDeleted)
        return (result, await waits.all)
    }

    @Test func identityIsReadBeforeTheDeleteAndAWatchlistedMovieLeavesTheList() async throws {
        let script = Script(items: [try Self.movie()])

        let (result, waits) = await Self.run(try Self.movie(guid: nil), on: script)

        #expect(result == MediaDeletionResult(outcome: .deleted, watchlist: .removed(guid: "plex://movie/abc")))
        #expect(await script.events == ["read 10", "delete 10", "contains plex://movie/abc", "remove plex://movie/abc"])
        #expect(waits.isEmpty)
    }

    @Test func aMovieNotOnTheWatchlistIsLeftAloneAndStillCounts() async throws {
        let script = Script(items: [try Self.movie()], .init(watchlisted: false))

        let (result, _) = await Self.run(try Self.movie(), on: script)

        #expect(result == MediaDeletionResult(outcome: .deleted, watchlist: .unchanged))
        #expect(await script.events.contains { $0.hasPrefix("remove") } == false)
    }

    @Test func aMovieWithAnOldAgentGuidOrNoWatchlistSendsNothingToTheAccount() async throws {
        let legacy = try Self.movie(guid: "com.plexapp.agents.imdb://tt0118799")
        let script = Script(items: [legacy])
        let (result, _) = await Self.run(legacy, on: script)
        #expect(result == MediaDeletionResult(outcome: .deleted))

        let other = Script(items: [try Self.movie()])
        let (signedOut, _) = await Self.run(try Self.movie(), on: other, watchlist: false)
        #expect(signedOut == MediaDeletionResult(outcome: .deleted))
        #expect(await other.events == ["read 10", "delete 10"])
    }

    @Test func aShowWithTheGuidReadFromTheServerLeavesTheList() async throws {
        let show = try decode(PlexMetadata.self, ["ratingKey": "20", "type": "show", "guid": "plex://show/xyz"])
        let script = Script(items: [show])

        let (result, _) = await Self.run(try decode(PlexMetadata.self, ["ratingKey": "20", "type": "show"]), on: script)

        #expect(result.watchlist == .removed(guid: "plex://show/xyz"))
    }

    @Test func anEpisodeWithOthersLeftKeepsTheShowOnTheList() async throws {
        let sibling = try decode(PlexMetadata.self, ["ratingKey": "23", "type": "episode", "parentRatingKey": "21", "grandparentRatingKey": "20"])
        let script = Script(items: [try Self.episode()], leaves: [sibling])

        let (result, _) = await Self.run(try Self.episode(show: nil), on: script)

        #expect(result == MediaDeletionResult(outcome: .deleted, watchlist: .unchanged))
        #expect(await script.events == ["read 22", "delete 22", "leaves 20"])
    }

    /// The server still lists a deleted episode until its trash is emptied, and so does an earlier delete
    /// of this session, so neither counts as an episode left.
    @Test func theLastEpisodeTakesTheShowOffTheList() async throws {
        let leaf = { (key: String) in try decode(PlexMetadata.self, ["ratingKey": key, "type": "episode", "parentRatingKey": "21", "grandparentRatingKey": "20"]) }
        let script = Script(items: [try Self.episode()], leaves: [try leaf("22"), try leaf("23")])
        var earlier = DeletedTitles()
        earlier.insert("23")

        let (result, _) = await Self.run(try Self.episode(), on: script, alreadyDeleted: earlier)

        #expect(result.watchlist == .removed(guid: "plex://show/xyz"))
        #expect(await script.events == ["read 22", "delete 22", "leaves 20", "contains plex://show/xyz", "remove plex://show/xyz"])
    }

    @Test func aShowTheServerNoLongerKnowsHasNoEpisodesLeft() async throws {
        let script = Script(items: [try Self.episode()], .init(leavesError: .server(status: 404, message: nil)))

        let (result, _) = await Self.run(try Self.episode(), on: script)

        #expect(result.watchlist == .removed(guid: "plex://show/xyz"))
    }

    @Test func anEpisodeWithoutTheShowsKeyNeverTouchesTheList() async throws {
        let script = Script(items: [try Self.episode(showKey: nil)])

        let (result, _) = await Self.run(try Self.episode(showKey: nil), on: script)

        #expect(result == MediaDeletionResult(outcome: .deleted))
        #expect(await script.events == ["read 22", "delete 22"])
    }

    @Test func aSeasonTakesItsShowOffTheListWhenNothingIsLeft() async throws {
        let season = try decode(PlexMetadata.self, [
            "ratingKey": "21", "type": "season", "parentRatingKey": "20", "parentGuid": "plex://show/xyz",
        ])
        let episode = try decode(PlexMetadata.self, ["ratingKey": "22", "type": "episode", "parentRatingKey": "21", "grandparentRatingKey": "20"])
        let script = Script(items: [season], leaves: [episode])

        let (result, _) = await Self.run(season, on: script)

        #expect(result.watchlist == .removed(guid: "plex://show/xyz"))
    }

    @Test func a404BeforeTheDeleteCountsAsDeletedAndUsesTheOnScreenIdentity() async throws {
        let script = Script()

        let (result, _) = await Self.run(try Self.movie(), on: script)

        #expect(result == MediaDeletionResult(outcome: .deleted, watchlist: .removed(guid: "plex://movie/abc")))
        #expect(await script.events.contains("delete 10") == false)
    }

    @Test func a404DuringTheDeleteCountsAsDeletedToo() async throws {
        let script = Script(items: [try Self.movie()], .init(deleteError: .server(status: 404, message: nil)))

        let (result, _) = await Self.run(try Self.movie(), on: script)

        #expect(result.outcome == .deleted && result.watchlist == .removed(guid: "plex://movie/abc"))
    }

    @Test func refusedDeletesNeverTouchTheListOrRecheck() async throws {
        for error in [PlexError.unauthorized, .server(status: 403, message: nil)] {
            let script = Script(items: [try Self.movie()], .init(deleteError: error))

            let (result, waits) = await Self.run(try Self.movie(), on: script)

            #expect(result == MediaDeletionResult(outcome: .notAllowed))
            #expect(await script.events == ["read 10", "delete 10"])
            #expect(waits.isEmpty)
        }
    }

    /// A 5xx or a timeout may come after the files went: the item is asked for again, with waits between.
    @Test func aTimeoutThatDeletedItCountsAfterTheRecheckSeesItGone() async throws {
        let script = Script(items: [try Self.movie()], .init(deleteError: .unreachable(.timedOut), goneAfterReads: 3))

        let (result, waits) = await Self.run(try Self.movie(), on: script)

        #expect(result == MediaDeletionResult(outcome: .deleted, watchlist: .removed(guid: "plex://movie/abc")))
        #expect(await script.events.filter { $0.hasPrefix("read") }.count == 3)
        #expect(waits == [.seconds(1), .seconds(2)])
    }

    @Test func aServerFaultThatLeftTheItemThereIsReportedAfterThreeRechecks() async throws {
        let script = Script(items: [try Self.movie()], .init(deleteError: .server(status: 503, message: nil)))

        let (result, waits) = await Self.run(try Self.movie(), on: script)

        #expect(result == MediaDeletionResult(outcome: .failed))
        #expect(await script.events.filter { $0.hasPrefix("read") }.count == 4)
        #expect(waits == [.seconds(1), .seconds(2), .seconds(4)])
        #expect(await script.events.contains { $0.hasPrefix("contains") } == false)
    }

    @Test func otherFailuresAreNotRechecked() async throws {
        let script = Script(items: [try Self.movie()], .init(deleteError: .unreachable(.offline)))

        let (result, waits) = await Self.run(try Self.movie(), on: script)

        #expect(result.outcome == .failed && waits.isEmpty)
        #expect(await script.events == ["read 10", "delete 10"])
    }

    @Test func theWatchlistRemovalIsTriedThreeTimesWithBackoff() async throws {
        let script = Script(items: [try Self.movie()], .init(removeFailures: 2))

        let (result, waits) = await Self.run(try Self.movie(), on: script)

        #expect(result.watchlist == .removed(guid: "plex://movie/abc"))
        #expect(await script.events.filter { $0.hasPrefix("remove") }.count == 3)
        #expect(waits == [.milliseconds(500), .seconds(1)])
    }

    @Test func aRemovalThatKeepsFailingLeavesTheTitleDeletedAndSaysSo() async throws {
        let script = Script(items: [try Self.movie()], .init(containsFailures: 3))

        let (result, waits) = await Self.run(try Self.movie(), on: script)

        #expect(result == MediaDeletionResult(outcome: .deleted, watchlist: .failed(guid: "plex://movie/abc"), ticket: result.ticket))
        #expect(result.canRetry)
        #expect(await script.events.filter { $0.hasPrefix("contains") }.count == 3)
        #expect(waits.count == 2)
    }

    @Test func aWatchlistEntryTheAccountAlreadyLostIsNotAFailure() async throws {
        let script = Script(items: [try Self.movie()], .init(removeError: .server(status: 404, message: nil)))

        let (result, _) = await Self.run(try Self.movie(), on: script)

        #expect(result.watchlist == .unchanged)
    }

    @Test func theCallerHearsOfTheDeleteBeforeTheWatchlistWork() async throws {
        let script = Script(items: [try Self.movie()])

        let deletion = MediaDeletion(server: script, watchlist: script) { _ in }
        _ = await deletion.delete(try Self.movie()) { await script.note("afterDelete") }

        #expect(await script.events == ["read 10", "delete 10", "afterDelete", "contains plex://movie/abc", "remove plex://movie/abc"])
    }

    // MARK: Radarr, Sonarr and Seerr

    @Test func aMovieLeavesRadarrAndSeerrAfterTheServerDeletedIt() async throws {
        let script = Script(items: [try Self.movie(year: 2021)], .init(ids: ["10": Self.movieIDs]))

        let (result, waits) = await Self.run(try Self.movie(year: 2021), on: script, arr: true, requests: true)

        #expect(result == MediaDeletionResult(
            outcome: .deleted, watchlist: .removed(guid: "plex://movie/abc"), arr: .removed, requests: .removed))
        #expect(await script.events == [
            "read 10", "ids 10", "delete 10", "contains plex://movie/abc", "remove plex://movie/abc",
            "radarr 438631 Charge 2021", "seerr movie 438631",
        ])
        #expect(waits.isEmpty)
    }

    @Test func aShowLeavesSonarrByItsTVDBIDAndSeerrByItsTMDBID() async throws {
        let script = Script(items: [try Self.show()], .init(ids: ["30": Self.showIDs]))

        let (result, _) = await Self.run(try Self.show(), on: script, arr: true, requests: true)

        #expect(result.arr == .removed && result.requests == .removed)
        #expect(await script.events.suffix(2) == ["sonarr 121361 Dune Prophecy", "seerr tv 90"])
    }

    @Test func anEpisodeWithOthersLeftLeavesTheShowInSonarrAndSeerr() async throws {
        let sibling = try decode(PlexMetadata.self, ["ratingKey": "23", "type": "episode", "parentRatingKey": "21", "grandparentRatingKey": "20"])
        let script = Script(items: [try Self.episode()], leaves: [sibling], .init(ids: ["20": Self.showIDs]))

        let (result, _) = await Self.run(try Self.episode(), on: script, arr: true, requests: true)

        #expect(result == MediaDeletionResult(outcome: .deleted, watchlist: .unchanged, arr: .notApplicable, requests: .notApplicable))
        #expect(await script.events == ["read 22", "ids 20", "delete 22", "leaves 20"])
    }

    @Test func theLastEpisodeTakesTheShowOutOfSonarrAndSeerrAfterOneCountOfWhatIsLeft() async throws {
        let script = Script(items: [try Self.episode()], .init(ids: ["20": Self.showIDs]))

        let (result, _) = await Self.run(try Self.episode(), on: script, arr: true, requests: true)

        #expect(result.arr == .removed && result.requests == .removed)
        #expect(await script.events.suffix(2) == ["sonarr 121361 Dune Prophecy", "seerr tv 90"])
        #expect(await script.events.filter { $0 == "leaves 20" }.count == 1)
    }

    @Test func aTitleWithoutTheIDAServiceNeedsIsUnmatched() async throws {
        let script = Script(items: [try Self.movie(), try Self.show()], .init(ids: ["10": ["imdb://tt1"], "30": ["tmdb://90"]]))

        let (movie, _) = await Self.run(try Self.movie(), on: script, arr: true, requests: true)
        let (show, _) = await Self.run(try Self.show(), on: script, arr: true, requests: true)

        #expect(movie.arr == .unmatched && movie.requests == .unmatched)
        #expect(show.arr == .unmatched && show.requests == .removed)
        #expect(await script.events.allSatisfy { !$0.hasPrefix("radarr") && !$0.hasPrefix("sonarr") })
    }

    @Test func aTitleTheServerAlreadyForgotIsDeletedAndUnmatched() async throws {
        let script = Script()

        let (result, _) = await Self.run(try Self.movie(), on: script, arr: true, requests: true)

        #expect(result == MediaDeletionResult(
            outcome: .deleted, watchlist: .removed(guid: "plex://movie/abc"), arr: .unmatched, requests: .unmatched))
        #expect(await script.events == ["read 10", "contains plex://movie/abc", "remove plex://movie/abc"])
    }

    @Test func aServiceThatFailsDoesNotStopTheOthersAndRetryRepeatsOnlyIt() async throws {
        let script = Script(items: [try Self.movie()], .init(ids: ["10": Self.movieIDs], arrFailures: 2))
        let waits = Waits()
        let deletion = MediaDeletion(server: script, watchlist: script, arr: script, requests: script) { await waits.add($0) }

        let first = await deletion.delete(try Self.movie())

        #expect(first.outcome == .deleted)
        #expect(first.watchlist == .removed(guid: "plex://movie/abc"))
        #expect(first.arr == .failed)
        #expect(first.requests == .removed)
        #expect(first.canRetry)
        #expect(await waits.all == [.seconds(1)])

        let second = await deletion.retry(first)

        #expect(second.arr == .removed)
        #expect(second.requests == .removed)
        #expect(second.watchlist == first.watchlist)
        #expect(!second.canRetry)
        let events = await script.events
        #expect(events.filter { $0.hasPrefix("radarr") }.count == 3)
        #expect(events.filter { $0 == "delete 10" }.count == 1)
        #expect(events.filter { $0.hasPrefix("seerr") }.count == 1)
        #expect(events.filter { $0.hasPrefix("contains") }.count == 1)
    }

    @Test func aRefusedServiceIsNotAskedAgain() async throws {
        let script = Script(items: [try Self.movie()], .init(ids: ["10": Self.movieIDs], arrError: .badKey, requestsError: .notAllowed))

        let (result, waits) = await Self.run(try Self.movie(), on: script, arr: true, requests: true)

        #expect(result.arr == .refused && result.requests == .refused)
        #expect(!result.canRetry)
        #expect(waits.isEmpty)
        #expect(await script.events.filter { $0.hasPrefix("radarr") || $0.hasPrefix("seerr") }.count == 2)
    }

    @Test func aServiceThatFailsOnceIsTriedAgainAfterOneSecond() async throws {
        let script = Script(items: [try Self.movie()], .init(ids: ["10": Self.movieIDs], arrFailures: 1, requestsFailures: 1))

        let (result, waits) = await Self.run(try Self.movie(), on: script, arr: true, requests: true)

        #expect(result.arr == .removed && result.requests == .removed)
        #expect(waits == [.seconds(1), .seconds(1)])
    }

    @Test func idsThatCannotBeReadDoNotStopTheDelete() async throws {
        let script = Script(items: [try Self.movie()], .init(ids: ["10": Self.movieIDs], idsFailures: 2))

        let (result, waits) = await Self.run(try Self.movie(), on: script, arr: true, requests: true)

        #expect(result.outcome == .deleted)
        #expect(result.arr == .unmatched && result.requests == .unmatched)
        #expect(waits == [.seconds(1)])
        #expect(await script.events.filter { $0 == "delete 10" }.count == 1)
    }

    @Test func servicesThatAreNotConnectedAreNotAskedAndNeedNoIDs() async throws {
        let script = Script(items: [try Self.show()], arrKinds: [.radarr])

        let (result, _) = await Self.run(try Self.show(), on: script, arr: true)

        #expect(result.arr == .notConnected && result.requests == .notConnected)
        #expect(await script.events == ["read 30", "delete 30", "contains plex://show/xyz", "remove plex://show/xyz"])
    }

    @Test func aRefusedDeleteNeverReachesTheServices() async throws {
        let script = Script(items: [try Self.movie()], .init(deleteError: .server(status: 403, message: nil), ids: ["10": Self.movieIDs]))

        let (result, _) = await Self.run(try Self.movie(), on: script, arr: true, requests: true)

        #expect(result == MediaDeletionResult(outcome: .notAllowed))
        #expect(await script.events == ["read 10", "ids 10", "delete 10"])
    }

    /// The Android bridge answers each call once: it deletes, shows the title gone, then asks for the cleanup
    /// with the ticket the first answer carried as JSON.
    @Test func theServerDeleteAloneAsksNoOtherServiceAndItsTicketDrivesTheCleanup() async throws {
        let script = Script(items: [try Self.movie(year: 2021)], .init(ids: ["10": Self.movieIDs]))
        let deletion = MediaDeletion(server: script, watchlist: script, arr: script, requests: script) { _ in }

        let first = await deletion.deleteFromServer(try Self.movie(year: 2021))

        #expect(first.outcome == .deleted)
        #expect(await script.events == ["read 10", "ids 10", "delete 10"])

        let ticket = try JSONDecoder().decode(DeletionTicket.self, from: JSONEncoder().encode(try #require(first.ticket)))
        let result = await deletion.cleanUp(ticket)

        #expect(result == MediaDeletionResult(
            outcome: .deleted, watchlist: .removed(guid: "plex://movie/abc"), arr: .removed, requests: .removed))
        #expect(await script.events.dropFirst(3) == [
            "contains plex://movie/abc", "remove plex://movie/abc", "radarr 438631 Charge 2021", "seerr movie 438631",
        ])
    }
}
