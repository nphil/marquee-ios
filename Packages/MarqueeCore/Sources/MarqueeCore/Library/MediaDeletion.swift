import Foundation

/// The server calls a delete needs.
public protocol DeletionServer: Sendable {
    func metadata(_ ratingKey: String) async throws -> PlexMetadata
    func deleteItem(_ ratingKey: String) async throws
    func allLeaves(of ratingKey: String) async throws -> [PlexMetadata]
}

/// The account watchlist calls a delete needs.
public protocol WatchlistAccount: Sendable {
    func contains(guid: String) async throws -> Bool
    func remove(guid: String) async throws
}

extension PlexLibrary: DeletionServer {}
extension PlexWatchlist: WatchlistAccount {}

/// What happened to the title's Watchlist entry after a delete.
public enum WatchlistCleanup: Equatable, Sendable {
    /// Nothing to remove: the title was not watchlisted, it has no catalogue guid, the show still has
    /// episodes, or nobody is signed in to a watchlist.
    case unchanged
    /// The catalogue title `guid` was on the Watchlist and is off it now.
    case removed(guid: String)
    /// The title is on the Watchlist and could not be taken off it.
    case failed(guid: String)
}

public struct MediaDeletionResult: Equatable, Sendable {
    public var outcome: DeleteOutcome
    public var watchlist: WatchlistCleanup

    public init(outcome: DeleteOutcome, watchlist: WatchlistCleanup = .unchanged) {
        self.outcome = outcome
        self.watchlist = watchlist
    }
}

/// Deleting a title from the server, and the Watchlist entry that goes with it.
///
/// The title's identity is read before the DELETE, because afterwards the server no longer answers for
/// it. A movie or show leaves the Watchlist with it; an episode or season takes its show off only when
/// that was the show's last episode. A 404 at any point counts as deleted and still cleans the
/// Watchlist, from the identity on screen when the server could not give one.
public struct MediaDeletion: Sendable {
    /// Waits between the checks that follow a delete the server answered with a fault or no answer.
    static let recheckDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]
    /// Watchlist cleanup is tried this many times, with these waits between the tries.
    static let watchlistAttempts = 3
    static let watchlistDelays: [Duration] = [.milliseconds(500), .seconds(1)]

    let server: any DeletionServer
    let watchlist: (any WatchlistAccount)?
    let sleep: @Sendable (Duration) async -> Void

    /// `watchlist` is nil when no profile is signed in to one. `sleep` is replaceable so tests need no
    /// real time.
    public init(
        server: any DeletionServer,
        watchlist: (any WatchlistAccount)?,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.server = server
        self.watchlist = watchlist
        self.sleep = sleep
    }

    /// Deletes `item`. `alreadyDeleted` lists what this session deleted before, because a server keeps
    /// listing those episodes until its trash is emptied. `afterDelete` runs as soon as the title is
    /// known to be gone, before the Watchlist cleanup, which can take several seconds when it retries.
    public func delete(
        _ item: PlexMetadata,
        alreadyDeleted: DeletedTitles = DeletedTitles(),
        afterDelete: @Sendable () async -> Void = {}
    ) async -> MediaDeletionResult {
        var identity = Identity(item)
        var isGone = false
        do {
            identity = Identity(try await server.metadata(item.ratingKey), fallback: item)
        } catch PlexError.server(404, _) {
            isGone = true
        } catch {
            // The on-screen identity serves.
        }

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
        return MediaDeletionResult(outcome: .deleted, watchlist: await clean(identity, deleted: deleted))
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

    // MARK: Watchlist

    private func clean(_ identity: Identity, deleted: DeletedTitles) async -> WatchlistCleanup {
        guard let watchlist, let guid = identity.guid, PlexWatchlist.catalogueKey(guid: guid) != nil else {
            return .unchanged
        }
        for attempt in 0..<Self.watchlistAttempts {
            if attempt > 0 { await sleep(Self.watchlistDelays[attempt - 1]) }
            do {
                if let showKey = identity.showKey, try await !isLastEpisode(of: showKey, deleted: deleted) {
                    return .unchanged
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

    /// The Watchlist title a delete concerns: the movie or show itself, or the show of an episode or
    /// season (then `showKey` is that show's rating key, for the episodes-left check).
    private struct Identity {
        var guid: String?
        var showKey: String?

        init(_ item: PlexMetadata, fallback: PlexMetadata? = nil) {
            switch item.type {
            case .movie, .show:
                guid = item.guid ?? fallback?.guid
            case .episode:
                guid = item.grandparentGuid ?? fallback?.grandparentGuid
                showKey = item.grandparentRatingKey ?? fallback?.grandparentRatingKey
            case .season:
                guid = item.parentGuid ?? fallback?.parentGuid
                showKey = item.parentRatingKey ?? fallback?.parentRatingKey
            default:
                break
            }
            // Without the show's key the episodes left cannot be counted, and the show must not go early.
            if item.type == .episode || item.type == .season, showKey == nil { guid = nil }
        }
    }
}
