import MarqueeCore
import SwiftUI

/// What the browse screens ask of the session, set by the tab container.
struct SessionActions {
    /// Starts playback of one version of `item`, resuming unless `fromStart`; the session decides how.
    var startPlayback: @MainActor (_ item: PlexMetadata, _ mediaIndex: Int, _ fromStart: Bool) -> Void = { _, _, _ in }
    /// Leaves an expired sign-in for the sign-in screen.
    var signInAgain: @MainActor () -> Void = {}
    /// The server lets this app delete titles from its disk.
    var canDeleteMedia = false

    @MainActor
    func play(_ item: PlexMetadata, mediaIndex: Int = 0, fromStart: Bool = false) {
        startPlayback(item, mediaIndex, fromStart)
    }
}

extension EnvironmentValues {
    @Entry var sessionActions: SessionActions = SessionActions()
    /// The signed-in profile's watchlist on plex.tv; nil before sign-in.
    @Entry var plexWatchlist: PlexWatchlist? = nil
}

extension PlexLibrary {
    /// Names this library instance: signing in again, switching profile or choosing another server makes
    /// a new one, and screens reload for it.
    var instance: ObjectIdentifier { ObjectIdentifier(connection) }
}

/// Changes this app made on the server, so every screen that shows a changed title refreshes it.
@MainActor @Observable
final class LibraryChanges {
    /// Bumped after each confirmed watched or Continue Watching change.
    private(set) var revision = 0
    /// Bumped after each confirmed watchlist change.
    private(set) var watchlistRevision = 0
    /// The revision that last touched each title, its season and its show. Kept whole, so a screen that
    /// sees several revisions at once still learns every title they touched.
    @ObservationIgnored private var touched: [String: Int] = [:]
    /// Titles deleted this session. Every list leaves them out at once and stays that way after
    /// refetching, because the server lists a deleted title until its trash is emptied.
    private(set) var deleted = DeletedTitles()

    func record(_ keys: Set<String>) {
        revision += 1
        for key in keys { touched[key] = revision }
    }

    /// Takes a deleted title out of every list and its artwork out of the caches; the screens showing
    /// its season or show refetch their counts.
    func recordDeletion(of item: PlexMetadata, server: String) {
        deleted.insert(item.ratingKey)
        record(Set([item.ratingKey, item.parentRatingKey, item.grandparentRatingKey].compactMap(\.self)))
        let art = [item.thumb, item.art].compactMap(\.self)
        Task { await ImagePipeline.shared.forget(art, server: server) }
    }

    /// `items` without the titles deleted this session.
    func shown(_ items: [PlexMetadata]) -> [PlexMetadata] {
        deleted.removing(from: items)
    }

    /// Cards taken off Continue Watching whose removal the server has not answered yet. A refetch in that
    /// time still lists them, so Home leaves them out until the answer: confirmed, the next fetch is the
    /// server's word; refused, the card is back.
    private(set) var removing: Set<String> = []

    func startRemovingFromContinueWatching(_ key: String) { removing.insert(key) }
    func endRemovingFromContinueWatching(_ key: String) { removing.remove(key) }

    /// `items` of Continue Watching without the cards being removed.
    func shownInContinueWatching(_ items: [PlexMetadata]) -> [PlexMetadata] {
        removing.isEmpty ? items : items.filter { !removing.contains($0.ratingKey) }
    }

    /// Rating keys name titles on one server only, so choosing another server starts afresh.
    func forgetDeletions() {
        deleted = DeletedTitles()
    }

    func recordWatchlist() {
        watchlistRevision += 1
    }

    /// Catalogue keys of the titles taken off the Watchlist this session. The Watchlist screen leaves
    /// them out at once, without waiting for plex.tv to stop listing them.
    private(set) var unlisted: Set<String> = []

    func hideFromWatchlist(guid: String) {
        if let key = PlexWatchlist.catalogueKey(guid: guid) { unlisted.insert(key) }
        recordWatchlist()
    }

    /// Undoes `hideFromWatchlist` for a title saved again.
    func showInWatchlist(guid: String) {
        if let key = PlexWatchlist.catalogueKey(guid: guid) { unlisted.remove(key) }
    }

    /// `items` of the Watchlist without the titles taken off it this session.
    func shownInWatchlist(_ items: [PlexMetadata]) -> [PlexMetadata] {
        guard !unlisted.isEmpty else { return items }
        return items.filter { item in
            PlexWatchlist.catalogueKey(guid: item.guid).map { !unlisted.contains($0) } ?? true
        }
    }

    /// The titles touched after `revision`.
    func keys(after revision: Int) -> Set<String> {
        Set(touched.filter { $0.value > revision }.keys)
    }
}

/// Watched, watchlist and Continue Watching changes as DESIGN §8.3 and §11 describe them: the screen
/// shows the change at once; once the server confirms, the success haptic plays and a toast offers Undo;
/// a refused change rolls back with the error haptic.
@MainActor
struct ItemActions: DynamicProperty {
    @Environment(\.plexLibrary) private var library
    @Environment(\.plexWatchlist) private var watchlist
    @Environment(ToastCenter.self) private var toasts
    @Environment(LibraryChanges.self) private var changes

    /// What a watched change covers; it words the toast. Plex marks every episode under a show or season.
    enum Scope {
        case title, season, show

        func marked(_ watched: Bool) -> String {
            let state = watched ? "watched" : "unwatched"
            return switch self {
            case .title: "Marked \(state)"
            case .season: "Season marked \(state)"
            case .show: "Show marked \(state)"
            }
        }

        func failed(_ watched: Bool) -> String {
            let state = watched ? "watched" : "unwatched"
            return switch self {
            case .title: "Couldn't mark \(state)"
            case .season: "Couldn't mark season \(state)"
            case .show: "Couldn't mark show \(state)"
            }
        }
    }

    /// Marks `item` watched or unwatched. `show` puts a state on screen; Undo and failures call it again
    /// with the state to return to. A show or season passes its own rating key, and Plex marks every
    /// episode under it.
    func setWatched(_ watched: Bool, _ item: PlexMetadata, show: @escaping @MainActor (Bool) -> Void) {
        let scope: Scope = switch item.type {
        case .show: .show
        case .season: .season
        default: .title
        }
        setWatched(watched, key: item.ratingKey, touching: [item.parentRatingKey, item.grandparentRatingKey], scope: scope, show: show)
    }

    /// The same for the title with rating key `key`, which `touching` names the parents of. A screen that
    /// shows an episode and offers its show passes the show's key.
    func setWatched(
        _ watched: Bool, key: String, touching parents: [String?], scope: Scope, show: @escaping @MainActor (Bool) -> Void
    ) {
        guard let library else { return }
        let touched = Set(([key] + parents).compactMap(\.self))
        let toasts = toasts
        let changes = changes

        func send(_ watched: Bool, onSuccess: @escaping @MainActor () -> Void, onFailure: @escaping @MainActor () -> Void) {
            Task {
                do {
                    if watched { try await library.markWatched(key) } else { try await library.markUnwatched(key) }
                    Haptics.success()
                    changes.record(touched)
                    onSuccess()
                } catch {
                    Haptics.error()
                    onFailure()
                }
            }
        }

        show(watched)
        send(watched) {
            toasts.show(scope.marked(watched), undo: {
                show(!watched)
                send(!watched, onSuccess: {}) {
                    show(watched)
                    toasts.show("Couldn't undo")
                }
            })
        } onFailure: {
            show(!watched)
            toasts.show(scope.failed(watched))
        }
    }

    /// Takes `item` off Continue Watching. `hide` hides it at once; the server hears of it only once the
    /// toast has gone without Undo (or the app leaves the foreground), so Undo never needs a call of its
    /// own. The card stays out of Home's refetches until the server answers; a refused call puts it back.
    func removeFromContinueWatching(_ item: PlexMetadata, hide: @escaping @MainActor (Bool) -> Void) {
        guard let library else { return }
        let key = item.ratingKey
        let toasts = toasts
        let changes = changes
        changes.startRemovingFromContinueWatching(key)
        hide(true)
        toasts.show("Removed from Continue Watching", undo: {
            changes.endRemovingFromContinueWatching(key)
            hide(false)
        }, commit: {
            // Sent as the app goes to the background too, which iOS suspends within seconds.
            let assertion = UIApplication.shared.beginBackgroundTask(withName: "marquee-continue-watching")
            Task {
                defer { if assertion != .invalid { UIApplication.shared.endBackgroundTask(assertion) } }
                do {
                    try await library.removeFromContinueWatching(key)
                    changes.endRemovingFromContinueWatching(key)
                    changes.record([key])
                } catch {
                    changes.endRemovingFromContinueWatching(key)
                    hide(false)
                    Haptics.error()
                    toasts.show("Couldn't remove from Continue Watching")
                }
            }
        })
    }

    /// Whether `guid` can go on the watchlist: it needs a catalogue title, and a signed-in profile.
    func canWatchlist(_ guid: String?) -> Bool {
        watchlist != nil && PlexWatchlist.catalogueKey(guid: guid) != nil
    }

    /// Whether the catalogue title `guid` is on the watchlist; nil when that cannot be told.
    func isWatchlisted(_ guid: String?) async -> Bool? {
        guard let watchlist, let guid, canWatchlist(guid) else { return nil }
        return try? await watchlist.contains(guid: guid)
    }

    /// Adds the catalogue title `guid` to the watchlist or removes it, with `show` as for `setWatched`.
    func setWatchlisted(_ on: Bool, guid: String, show: @escaping @MainActor (Bool) -> Void) {
        guard let watchlist else { return }
        let toasts = toasts
        let changes = changes

        func send(_ on: Bool, onSuccess: @escaping @MainActor () -> Void, onFailure: @escaping @MainActor () -> Void) {
            Task {
                do {
                    if on { try await watchlist.add(guid: guid) } else { try await watchlist.remove(guid: guid) }
                    if on { changes.showInWatchlist(guid: guid) }
                    Haptics.success()
                    changes.recordWatchlist()
                    onSuccess()
                } catch {
                    Haptics.error()
                    onFailure()
                }
            }
        }

        show(on)
        send(on) {
            toasts.show(on ? "Added to Watchlist" : "Removed from Watchlist", undo: {
                show(!on)
                send(!on, onSuccess: {}) {
                    show(on)
                    toasts.show("Couldn't undo")
                }
            })
        } onFailure: {
            show(!on)
            toasts.show("Couldn't update the Watchlist")
        }
    }
}
