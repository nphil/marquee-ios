import Foundation
import Testing
@testable import MarqueeCore

/// Scripted server and account: every call is logged in order, in `events`.
private actor Script: DeletionServer, WatchlistAccount {
    struct Config {
        var deleteError: PlexError?
        /// The item answers 404 from the Nth metadata read on (1-based), as after a delete that timed out.
        var goneAfterReads: Int?
        var leavesError: PlexError?
        var watchlisted = true
        var containsFailures = 0
        var removeError: PlexError?
        var removeFailures = 0
    }

    private(set) var events: [String] = []
    private let items: [String: PlexMetadata]
    private let leaves: [PlexMetadata]
    private var config: Config
    private var reads = 0

    init(items: [PlexMetadata] = [], leaves: [PlexMetadata] = [], _ config: Config = Config()) {
        self.items = Dictionary(uniqueKeysWithValues: items.map { ($0.ratingKey, $0) })
        self.leaves = leaves
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
}

/// Records each wait and returns at once.
private actor Waits {
    private(set) var all: [Duration] = []
    func add(_ duration: Duration) { all.append(duration) }
}

struct MediaDeletionTests {
    private static func movie(_ key: String = "10", guid: String? = "plex://movie/abc") throws -> PlexMetadata {
        try decode(PlexMetadata.self, ["ratingKey": key, "type": "movie", "guid": guid as Any, "title": "Charge"])
    }

    private static func episode(_ key: String = "22", show: String? = "plex://show/xyz", showKey: String? = "20") throws -> PlexMetadata {
        try decode(PlexMetadata.self, [
            "ratingKey": key, "type": "episode", "parentRatingKey": "21", "grandparentRatingKey": showKey as Any,
            "grandparentGuid": show as Any, "guid": "plex://episode/e1",
        ])
    }

    private static func run(
        _ item: PlexMetadata,
        on script: Script,
        watchlist: Bool = true,
        alreadyDeleted: DeletedTitles = DeletedTitles()
    ) async -> (MediaDeletionResult, [Duration]) {
        let waits = Waits()
        let deletion = MediaDeletion(server: script, watchlist: watchlist ? script : nil) { await waits.add($0) }
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

        #expect(result == MediaDeletionResult(outcome: .deleted, watchlist: .failed(guid: "plex://movie/abc")))
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
}
