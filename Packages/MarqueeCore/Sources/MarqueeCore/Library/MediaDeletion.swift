import Foundation

/// The server calls a delete needs.
public protocol DeletionServer: Sendable {
    func metadata(_ ratingKey: String) async throws -> PlexMetadata
    func deleteItem(_ ratingKey: String) async throws
    func allLeaves(of ratingKey: String) async throws -> [PlexMetadata]
    /// The item's ids at IMDb, TMDB and TVDB, as `tmdb://603`.
    func externalIDs(_ ratingKey: String) async throws -> [String]
}

/// The account watchlist calls a delete needs.
public protocol WatchlistAccount: Sendable {
    func contains(guid: String) async throws -> Bool
    func remove(guid: String) async throws
}

/// The Seerr call a delete needs.
public protocol RequestsAccount: Sendable {
    /// Clears Seerr's record of the title; true when it held one.
    func removeMedia(_ kind: SeerrMediaKind, tmdbID: Int) async throws -> Bool
}

extension PlexLibrary: DeletionServer {}
extension PlexWatchlist: WatchlistAccount {}
extension SeerrClient: RequestsAccount {}

/// What happened to the title's Watchlist entry after a delete.
public enum WatchlistCleanup: Equatable, Sendable {
    /// Nothing to remove: the title was not watchlisted, it has no catalogue guid, the show still has
    /// episodes, or nobody is signed in to a watchlist.
    case unchanged
    /// The catalogue title `guid` was on the Watchlist and is off it now.
    case removed(guid: String)
    /// The title is on the Watchlist and could not be taken off it.
    case failed(guid: String)

    var isFailed: Bool {
        switch self {
        case .failed: true
        case .unchanged, .removed: false
        }
    }
}

/// What happened in Sonarr, Radarr or Seerr after a delete.
public enum ServiceCleanup: Equatable, Sendable {
    /// Marquee has no connection to the service, so it was not asked.
    case notConnected
    /// Nothing to do there: the delete left part of the show in place.
    case notApplicable
    /// The title carries no id the service knows it by: a TMDB id for a movie, or for Seerr; a TVDB id
    /// for a show in Sonarr. Asking again cannot help.
    case unmatched
    /// The title is off the service: removed now, or not there to begin with.
    case removed
    /// The service refused the account or the key. Asking again cannot help.
    case refused
    /// An error or no answer; Retry may work.
    case failed
}

/// What a delete knew of the title while the server still knew it: enough to finish the cleanup later.
public struct DeletionTicket: Equatable, Sendable {
    public var ratingKey: String
    public var kind: PlexMediaType
    /// The movie's or the show's title; an episode or season gives its show's.
    public var title: String
    public var year: Int?
    /// The Watchlist title: the movie or show, or the show of an episode or season.
    public var guid: String?
    /// The show's rating key for an episode or season, to count the episodes left.
    public var showKey: String?
    /// The movie's or the show's ids in TMDB and TVDB, which Radarr, Sonarr and Seerr go by.
    public var tmdbID: Int?
    public var tvdbID: Int?

    init(_ item: PlexMetadata, fallback: PlexMetadata? = nil) {
        ratingKey = item.ratingKey
        kind = item.type
        switch item.type {
        case .movie, .show:
            guid = item.guid ?? fallback?.guid
            title = item.title
            year = item.year ?? fallback?.year
        case .episode:
            guid = item.grandparentGuid ?? fallback?.grandparentGuid
            showKey = item.grandparentRatingKey ?? fallback?.grandparentRatingKey
            title = item.grandparentTitle ?? fallback?.grandparentTitle ?? item.title
        case .season:
            guid = item.parentGuid ?? fallback?.parentGuid
            showKey = item.parentRatingKey ?? fallback?.parentRatingKey
            title = item.parentTitle ?? fallback?.parentTitle ?? item.title
        default:
            title = item.title
        }
        // Without the show's key the episodes left cannot be counted, and the show must not go early.
        if item.type == .episode || item.type == .season, showKey == nil { guid = nil }
    }

    /// Radarr holds a movie; Sonarr holds a show, and so its seasons and episodes.
    var arrKind: ArrKind? {
        switch kind {
        case .movie: .radarr
        case .show, .season, .episode: .sonarr
        default: nil
        }
    }

    var seerrKind: SeerrMediaKind? {
        switch kind {
        case .movie: .movie
        case .show, .season, .episode: .tv
        default: nil
        }
    }
}

public struct MediaDeletionResult: Equatable, Sendable {
    public var outcome: DeleteOutcome
    public var watchlist: WatchlistCleanup
    public var arr: ServiceCleanup
    public var requests: ServiceCleanup
    /// What `MediaDeletion.retry` needs to repeat the steps that failed; nil when none did.
    public var ticket: DeletionTicket?

    public init(
        outcome: DeleteOutcome, watchlist: WatchlistCleanup = .unchanged, arr: ServiceCleanup = .notConnected,
        requests: ServiceCleanup = .notConnected, ticket: DeletionTicket? = nil
    ) {
        self.outcome = outcome
        self.watchlist = watchlist
        self.arr = arr
        self.requests = requests
        self.ticket = ticket
    }

    /// Whether a step failed in a way that asking again may fix.
    public var canRetry: Bool {
        ticket != nil
    }

    fileprivate var hasFailedStep: Bool {
        watchlist.isFailed || arr == .failed || requests == .failed
    }
}

/// Deleting a title from the server, and everything that would bring it back: its Watchlist entry (which
/// Pulsarr and Seerr read), its place in Radarr or Sonarr, and Seerr's record of it.
///
/// The title's identity is read before the DELETE, because afterwards the server no longer answers for
/// it. A movie or show leaves the Watchlist with it; an episode or season takes its show off only when
/// that was the show's last episode. A 404 at any point counts as deleted and still cleans the
/// Watchlist, from the identity on screen when the server could not give one.
///
/// Once the server has deleted the title, the steps run one after another: Watchlist, then Radarr or
/// Sonarr (the title is removed with its files and put on the import exclusion list, so no list sync adds
/// it again), then Seerr. Each reports its own result, a failure in one never stops the next, and
/// `retry` repeats only what failed. Radarr, Sonarr and Seerr leave a movie or show alone while episodes
/// of it remain.
public struct MediaDeletion: Sendable {
    /// Waits between the checks that follow a delete the server answered with a fault or no answer.
    static let recheckDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]
    /// Watchlist cleanup is tried this many times, with these waits between the tries.
    static let watchlistAttempts = 3
    static let watchlistDelays: [Duration] = [.milliseconds(500), .seconds(1)]
    /// Reading the title's ids, and each of Radarr, Sonarr and Seerr, is tried this many times, with
    /// this wait between the tries.
    static let serviceAttempts = 2
    static let serviceDelay: Duration = .seconds(1)

    let server: any DeletionServer
    let watchlist: (any WatchlistAccount)?
    let arr: (any ArrAccount)?
    let requests: (any RequestsAccount)?
    let sleep: @Sendable (Duration) async -> Void

    /// `watchlist`, `arr` and `requests` are nil when nothing is connected to them. `sleep` is
    /// replaceable so tests need no real time.
    public init(
        server: any DeletionServer,
        watchlist: (any WatchlistAccount)?,
        arr: (any ArrAccount)? = nil,
        requests: (any RequestsAccount)? = nil,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.server = server
        self.watchlist = watchlist
        self.arr = arr
        self.requests = requests
        self.sleep = sleep
    }

    /// Deletes `item`. `alreadyDeleted` lists what this session deleted before, because a server keeps
    /// listing those episodes until its trash is emptied. `afterDelete` runs as soon as the title is
    /// known to be gone, before the cleanup of the other services, which can take several seconds when
    /// it retries.
    public func delete(
        _ item: PlexMetadata,
        alreadyDeleted: DeletedTitles = DeletedTitles(),
        afterDelete: @Sendable () async -> Void = {}
    ) async -> MediaDeletionResult {
        var ticket = DeletionTicket(item)
        var isGone = false
        do {
            ticket = DeletionTicket(try await server.metadata(item.ratingKey), fallback: item)
        } catch PlexError.server(404, _) {
            isGone = true
        } catch {
            // The on-screen identity serves.
        }
        if !isGone { await readIDs(into: &ticket) }

        if !isGone {
            do {
                try await server.deleteItem(item.ratingKey)
            } catch {
                switch DeleteOutcome(error) {
                case .deleted:
                    break
                case .notAllowed:
                    return MediaDeletionResult(outcome: .notAllowed)
                case .failed:
                    guard Self.mayHaveSucceeded(after: error), await confirmsGone(item.ratingKey) else {
                        return MediaDeletionResult(outcome: .failed)
                    }
                }
            }
        }

        await afterDelete()
        var deleted = alreadyDeleted
        deleted.insert(item.ratingKey)
        return await cleanUp(MediaDeletionResult(outcome: .deleted, ticket: ticket), deleted: deleted, onlyFailed: false)
    }

    /// Repeats the steps of `result` that failed and keeps the rest. The title is gone from the server
    /// by now, so the ticket's identity serves.
    public func retry(
        _ result: MediaDeletionResult, alreadyDeleted: DeletedTitles = DeletedTitles()
    ) async -> MediaDeletionResult {
        guard result.canRetry, let ticket = result.ticket else { return result }
        var deleted = alreadyDeleted
        deleted.insert(ticket.ratingKey)
        return await cleanUp(result, deleted: deleted, onlyFailed: true)
    }

    /// A fault or silence says nothing about whether the server removed the files before it gave out.
    private static func mayHaveSucceeded(after error: any Error) -> Bool {
        switch error as? PlexError {
        case .server(let status, _): status >= 500
        case .unreachable(.timedOut): true
        default: false
        }
    }

    /// Asks the server for the item a few times, waiting between asks; true once it answers 404.
    private func confirmsGone(_ ratingKey: String) async -> Bool {
        for delay in Self.recheckDelays {
            await sleep(delay)
            do {
                _ = try await server.metadata(ratingKey)
            } catch PlexError.server(404, _) {
                return true
            } catch {
                continue
            }
        }
        return false
    }

    // MARK: Cleanup

    /// Runs the steps, all of them or only those that failed before.
    private func cleanUp(_ previous: MediaDeletionResult, deleted: DeletedTitles, onlyFailed: Bool) async -> MediaDeletionResult {
        guard let ticket = previous.ticket else { return previous }
        var result = previous
        // Whether the delete took the whole title; nil until a step needs to know and the server tells.
        var whole: Bool? = ticket.showKey == nil ? ticket.kind == .movie || ticket.kind == .show : nil
        if !onlyFailed || result.watchlist.isFailed {
            result.watchlist = await clean(ticket, deleted: deleted, whole: &whole)
        }
        if !onlyFailed || result.arr == .failed {
            result.arr = await removeFromArr(ticket, deleted: deleted, whole: &whole)
        }
        if !onlyFailed || result.requests == .failed {
            result.requests = await clearRequests(ticket, deleted: deleted, whole: &whole)
        }
        result.ticket = result.hasFailedStep ? ticket : nil
        return result
    }

    /// Whether the delete took the whole title: always for a movie or show, and for an episode or season
    /// when the show has no episode left. nil when the server could not tell.
    private func wholeTitleGone(_ ticket: DeletionTicket, deleted: DeletedTitles, known: inout Bool?) async -> Bool? {
        guard known == nil, let showKey = ticket.showKey else { return known }
        for attempt in 0..<Self.watchlistAttempts {
            if attempt > 0 { await sleep(Self.watchlistDelays[attempt - 1]) }
            if let last = try? await isLastEpisode(of: showKey, deleted: deleted) {
                known = last
                return last
            }
        }
        return nil
    }

    /// Tries `work` a second time after a wait unless the service refused.
    private func attempt(_ work: () async throws -> Void, refused: (any Error) -> Bool) async -> ServiceCleanup {
        for attempt in 0..<Self.serviceAttempts {
            if attempt > 0 { await sleep(Self.serviceDelay) }
            do {
                try await work()
                return .removed
            } catch {
                if refused(error) { return .refused }
            }
        }
        return .failed
    }

    // MARK: Ids

    /// Reads the ids Radarr, Sonarr and Seerr know the title by, while the server still knows it. Asked
    /// only when one of them is connected, so a delete without them makes no extra call. A title whose
    /// ids cannot be read is deleted all the same, and those services report it as unmatched.
    private func readIDs(into ticket: inout DeletionTicket) async {
        var wanted = requests != nil && ticket.seerrKind != nil
        if let kind = ticket.arrKind, arr?.isConnected(kind) == true { wanted = true }
        let key = ticket.showKey ?? (ticket.kind == .movie || ticket.kind == .show ? ticket.ratingKey : nil)
        guard wanted, let key else { return }
        for attempt in 0..<Self.serviceAttempts {
            if attempt > 0 { await sleep(Self.serviceDelay) }
            if let ids = try? await server.externalIDs(key) {
                ticket.tmdbID = Self.id("tmdb", in: ids)
                ticket.tvdbID = Self.id("tvdb", in: ids)
                return
            }
        }
    }

    private static func id(_ scheme: String, in ids: [String]) -> Int? {
        let prefix = scheme + "://"
        return ids.lazy.filter { $0.hasPrefix(prefix) }.compactMap { Int($0.dropFirst(prefix.count)) }.first
    }

    // MARK: Radarr, Sonarr, Seerr

    private func removeFromArr(_ ticket: DeletionTicket, deleted: DeletedTitles, whole: inout Bool?) async -> ServiceCleanup {
        guard let arr, let kind = ticket.arrKind, arr.isConnected(kind) else { return .notConnected }
        switch await wholeTitleGone(ticket, deleted: deleted, known: &whole) {
        case .none: return .failed
        case .some(false): return .notApplicable
        case .some(true): break
        }
        let title: ArrTitle
        switch kind {
        case .radarr:
            guard let tmdbID = ticket.tmdbID else { return .unmatched }
            title = .movie(tmdbID: tmdbID, title: ticket.title, year: ticket.year)
        case .sonarr:
            guard let tvdbID = ticket.tvdbID else { return .unmatched }
            title = .series(tvdbID: tvdbID, title: ticket.title)
        }
        return await attempt({ _ = try await arr.remove(title) }, refused: { ($0 as? ArrError) == .badKey })
    }

    private func clearRequests(_ ticket: DeletionTicket, deleted: DeletedTitles, whole: inout Bool?) async -> ServiceCleanup {
        guard let requests, let kind = ticket.seerrKind else { return .notConnected }
        switch await wholeTitleGone(ticket, deleted: deleted, known: &whole) {
        case .none: return .failed
        case .some(false): return .notApplicable
        case .some(true): break
        }
        guard let tmdbID = ticket.tmdbID else { return .unmatched }
        return await attempt({ _ = try await requests.removeMedia(kind, tmdbID: tmdbID) }, refused: {
            switch $0 as? SeerrError {
            case .notAllowed, .badKey, .plexAccountNotAllowed: true
            default: false
            }
        })
    }

    // MARK: Watchlist

    private func clean(_ ticket: DeletionTicket, deleted: DeletedTitles, whole: inout Bool?) async -> WatchlistCleanup {
        guard let watchlist, let guid = ticket.guid, PlexWatchlist.catalogueKey(guid: guid) != nil else {
            return .unchanged
        }
        for attempt in 0..<Self.watchlistAttempts {
            if attempt > 0 { await sleep(Self.watchlistDelays[attempt - 1]) }
            do {
                if let showKey = ticket.showKey {
                    let last = try await isLastEpisode(of: showKey, deleted: deleted)
                    whole = last
                    if !last { return .unchanged }
                }
                guard try await isWatchlisted(guid, in: watchlist) else { return .unchanged }
                do {
                    try await watchlist.remove(guid: guid)
                } catch PlexError.server(404, _) {
                    return .unchanged
                }
                return .removed(guid: guid)
            } catch {
                continue
            }
        }
        return .failed(guid: guid)
    }

    private func isWatchlisted(_ guid: String, in watchlist: any WatchlistAccount) async throws -> Bool {
        do {
            return try await watchlist.contains(guid: guid)
        } catch PlexError.server(404, _) {
            return false
        }
    }

    /// Whether the show has no episode left apart from those deleted; a show the server no longer knows
    /// has none.
    private func isLastEpisode(of showKey: String, deleted: DeletedTitles) async throws -> Bool {
        do {
            return try await deleted.removing(from: server.allLeaves(of: showKey)).isEmpty
        } catch PlexError.server(404, _) {
            return true
        }
    }
}
