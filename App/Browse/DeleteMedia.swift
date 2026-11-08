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
    @State private var failure: Failure?

    private struct Failure {
        let target: DeleteTarget
        let outcome: DeleteOutcome
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
                Text(Self.message(target))
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
    }

    static func title(_ target: DeleteTarget) -> String {
        switch target {
        case .title(let item): "Delete “\(item.title)”?"
        case .version(let item, _): "Delete this version of “\(item.title)”?"
        }
    }

    static func message(_ target: DeleteTarget) -> String {
        switch target {
        case .title(let item):
            switch item.type {
            case .show: "Every season and episode, and their files, are removed from the server's disk. This can't be undone."
            case .season: "Every episode in this season, and their files, are removed from the server's disk. This can't be undone."
            default: "Its files are removed from the server's disk. This can't be undone."
            }
        case .version(let item, let index):
            "The \(item.media[index].versionLabel) file is removed from the server's disk. The other versions stay. This can't be undone."
        }
    }

    private func perform(_ target: DeleteTarget) {
        guard let library else { return }
        let item = target.item
        let changes = changes
        let toasts = toasts
        let watchlist = watchlist
        let onDeleted = onDeleted
        Task {
            switch target {
            case .title:
                let result = await MediaDeletion(server: library, watchlist: watchlist)
                    .delete(item, alreadyDeleted: changes.deleted) { @MainActor in
                        changes.recordDeletion(of: item, server: library.server.id)
                        onDeleted(target)
                    }
                guard result.outcome == .deleted else {
                    failure = Failure(target: target, outcome: result.outcome)
                    return
                }
                switch result.watchlist {
                case .removed(let guid):
                    changes.hideFromWatchlist(guid: guid)
                    toasts.show("Deleted “\(item.title)”")
                case .failed:
                    toasts.show("Deleted, but couldn't remove it from your Watchlist.")
                case .unchanged:
                    toasts.show("Deleted “\(item.title)”")
                }
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
}
