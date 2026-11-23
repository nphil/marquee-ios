import MarqueeCore
import SwiftUI

/// A title, or one version of it, to remove from the server's disk. Offered only where the server allows
/// it (`AppSession.canDeleteMedia`).
enum DeleteTarget: Identifiable, Hashable {
    case title(PlexMetadata)
    case version(PlexMetadata, mediaIndex: Int)

    var id: String {
        switch self {
        case .title(let item): item.ratingKey
        case .version(let item, let index): "\(item.ratingKey)/\(index)"
        }
    }

    var item: PlexMetadata {
        switch self {
        case .title(let item), .version(let item, _): item
        }
    }
}

extension View {
    /// Asks before deleting `target`, then deletes it and takes it out of every list. Cancel is the
    /// default. `onDeleted` runs once the title is gone from the server.
    func deleteConfirmation(_ target: Binding<DeleteTarget?>, onDeleted: @escaping @MainActor (DeleteTarget) -> Void = { _ in }) -> some View {
        modifier(DeleteConfirmation(target: target, onDeleted: onDeleted))
    }
}

private struct DeleteConfirmation: ViewModifier {
    @Binding var target: DeleteTarget?
    let onDeleted: @MainActor (DeleteTarget) -> Void

    @Environment(\.plexLibrary) private var library
    @Environment(\.plexWatchlist) private var watchlist
    @Environment(LibraryChanges.self) private var changes
    @Environment(ToastCenter.self) private var toasts
    @Environment(AppSession.self) private var session
    @State private var failure: Failure?
    @State private var leftover: Leftover?

    private struct Failure {
        let target: DeleteTarget
        let outcome: DeleteOutcome
    }

    /// A title that is gone from the server, with the steps after the delete that did not go through.
    private struct Leftover {
        let target: DeleteTarget
        let result: MediaDeletionResult
    }

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                target.map(Self.title) ?? "",
                isPresented: Binding { target != nil } set: { if !$0 { target = nil } },
                titleVisibility: .visible,
                presenting: target
            ) { target in
                Button("Delete", role: .destructive) { perform(target) }
                    .accessibilityIdentifier("delete.confirm")
                Button("Cancel", role: .cancel) {}
            } message: { target in
                Text(Self.message(target, also: Self.places(for: target, session: session)))
            }
            .alert(
                failure?.outcome == .notAllowed ? "Deleting Is Turned Off" : "Couldn't Delete",
                isPresented: Binding { failure != nil } set: { if !$0 { failure = nil } },
                presenting: failure
            ) { failure in
                if failure.outcome == .failed {
                    Button("Retry") { perform(failure.target) }
                    Button("Cancel", role: .cancel) {}
                } else {
                    Button("OK", role: .cancel) {}
                }
            } message: { failure in
                Text(failure.outcome == .notAllowed
                    ? "The server doesn't allow deleting media. Its owner can turn on Allow media deletion in the Plex server's Settings, under Library."
                    : "“\(failure.target.item.title)” is still on the server. Check the connection, then try again.")
            }
            .alert(
                "Deleted, but Not Everywhere",
                isPresented: Binding { leftover != nil } set: { if !$0 { leftover = nil } },
                presenting: leftover
            ) { leftover in
                if leftover.result.canRetry {
                    Button("Retry") { retry(leftover) }
                    Button("Not Now", role: .cancel) {}
                } else {
                    Button("OK", role: .cancel) {}
                }
            } message: { leftover in
                Text(Self.shortfall(of: leftover.result, kind: Self.arrKind(leftover.target)).joined(separator: "\n"))
            }
    }

    static func title(_ target: DeleteTarget) -> String {
        switch target {
        case .title(let item): "Delete “\(item.title)”?"
        case .version(let item, _): "Delete this version of “\(item.title)”?"
        }
    }

    /// `places` are the connected services that also drop the title, which the message names.
    static func message(_ target: DeleteTarget, also places: [String] = []) -> String {
        switch target {
        case .title(let item):
            let files = switch item.type {
            case .show: "Every season and episode, and their files, are removed from the server's disk."
            case .season: "Every episode in this season, and their files, are removed from the server's disk."
            default: "Its files are removed from the server's disk."
            }
            guard !places.isEmpty else { return "\(files) This can't be undone." }
            return "\(files) It is also removed from \(places.formatted(.list(type: .and))), so it isn't downloaded again. This can't be undone."
        case .version(let item, let index):
            return "The \(item.media[index].versionLabel) file is removed from the server's disk. The other versions stay. This can't be undone."
        }
    }

    /// The connected services that also drop a movie or show: Radarr or Sonarr, and Seerr.
    static func places(for target: DeleteTarget, session: AppSession) -> [String] {
        guard case .title(let item) = target, item.type == .movie || item.type == .show else { return [] }
        let kind = arrKind(target)
        var names: [String] = []
        if session.arr.config(kind) != nil { names.append(kind.appName) }
        if session.seerr.isEnabled { names.append("Seerr") }
        return names
    }

    /// Radarr holds movies; Sonarr holds shows, and so their seasons and episodes.
    static func arrKind(_ target: DeleteTarget) -> ArrKind {
        target.item.type == .movie ? .radarr : .sonarr
    }

    /// What a delete left undone after the server dropped the title, one line each; empty when nothing
    /// is left to say. A service that has nothing to remove says nothing.
    static func shortfall(of result: MediaDeletionResult, kind: ArrKind) -> [String] {
        var lines: [String] = []
        if result.watchlist.isFailed {
            lines.append("It is still on your Watchlist, which can request it again.")
        }
        let arrID = kind == .radarr ? "TMDB" : "TVDB"
        switch result.arr {
        case .failed: lines.append("\(kind.appName) didn't answer, so it may still hold the title and download it again.")
        case .refused: lines.append("\(kind.appName) refused the API key. Check it in Settings, under Integrations.")
        case .unmatched: lines.append("\(kind.appName) was not asked: the server has no \(arrID) id for this title.")
        case .notConnected, .notApplicable, .removed: break
        }
        switch result.requests {
        case .failed: lines.append("Seerr didn't answer, so it may still show the title as requested.")
        case .refused: lines.append("Seerr wouldn't remove it: the signed-in account can't manage requests.")
        case .unmatched: lines.append("Seerr was not asked: the server has no TMDB id for this title.")
        case .notConnected, .notApplicable, .removed: break
        }
        return lines
    }

    /// The toast when no step failed: the title, the services that dropped it and, for a movie or show,
    /// the ones that were not asked because they are not set up, so the title may come back through them.
    static func summary(of result: MediaDeletionResult, target: DeleteTarget, kind: ArrKind) -> String {
        let item = target.item
        var dropped: [String] = []
        if result.arr == .removed { dropped.append(kind.appName) }
        if result.requests == .removed { dropped.append("Seerr") }
        let deleted = "Deleted “\(item.title)”"
        var sentences = [dropped.isEmpty ? deleted : "\(deleted) and removed it from \(dropped.formatted(.list(type: .and)))"]
        if item.type == .movie || item.type == .show {
            var idle: [String] = []
            if result.arr == .notConnected { idle.append(kind.appName) }
            if result.requests == .notConnected { idle.append("Seerr") }
            if !idle.isEmpty {
                sentences.append("\(idle.formatted(.list(type: .and))) \(idle.count == 1 ? "wasn't" : "weren't") asked: not set up in Settings.")
            }
        }
        return sentences.joined(separator: ". ")
    }

    private func perform(_ target: DeleteTarget) {
        guard let library else { return }
        let item = target.item
        let changes = changes
        let toasts = toasts
        let deleting = deletion(on: library)
        let onDeleted = onDeleted
        Task {
            switch target {
            case .title:
                let result = await deleting.delete(item, alreadyDeleted: changes.deleted) { @MainActor in
                    changes.recordDeletion(of: item, server: library.server.id)
                    onDeleted(target)
                }
                guard result.outcome == .deleted else {
                    failure = Failure(target: target, outcome: result.outcome)
                    return
                }
                conclude(result, of: target)
            case .version(_, let index):
                let outcome = await library.deleteVersion(item.media[index].id, of: item.ratingKey)
                guard outcome == .deleted else {
                    failure = Failure(target: target, outcome: outcome)
                    return
                }
                changes.record(Set([item.ratingKey, item.parentRatingKey, item.grandparentRatingKey].compactMap(\.self)))
                toasts.show("Deleted the \(item.media[index].versionLabel) version")
                onDeleted(target)
            }
        }
    }

    /// The delete and what follows it: the Watchlist, Radarr or Sonarr, and Seerr, each only where connected.
    private func deletion(on library: PlexLibrary) -> MediaDeletion {
        MediaDeletion(server: library, watchlist: watchlist, arr: session.arr.services, requests: session.seerr.client)
    }

    /// Repeats the steps that failed. The title is already off the server and out of every list.
    private func retry(_ leftover: Leftover) {
        guard let library else { return }
        let deleting = deletion(on: library)
        let changes = changes
        Task {
            let result = await deleting.retry(leftover.result, alreadyDeleted: changes.deleted)
            conclude(result, of: leftover.target)
        }
    }

    /// A toast when no step failed; otherwise an alert that says what is left, with Retry where asking again may help.
    private func conclude(_ result: MediaDeletionResult, of target: DeleteTarget) {
        if case .removed(let guid) = result.watchlist {
            changes.hideFromWatchlist(guid: guid)
        }
        let kind = Self.arrKind(target)
        let leftovers = Self.shortfall(of: result, kind: kind)
        Diag.event(.integration, "delete.cleanup", [
            "watchlist": Self.word(result.watchlist), "arr": "\(result.arr)", "requests": "\(result.requests)",
        ], leftovers.isEmpty ? .info : .warning)
        if leftovers.isEmpty {
            toasts.show(Self.summary(of: result, target: target, kind: kind))
        } else {
            leftover = Leftover(target: target, result: result)
        }
    }

    private static func word(_ cleanup: WatchlistCleanup) -> String {
        switch cleanup {
        case .unchanged: "unchanged"
        case .removed: "removed"
        case .failed: "failed"
        }
    }
}
