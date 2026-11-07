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
    /// Asks before deleting `target`, then deletes it and refreshes the screens showing it. Cancel is the
    /// default. `onDeleted` runs after the server confirms.
    func deleteConfirmation(_ target: Binding<DeleteTarget?>, onDeleted: @escaping @MainActor (DeleteTarget) -> Void = { _ in }) -> some View {
        modifier(DeleteConfirmation(target: target, onDeleted: onDeleted))
    }
}

private struct DeleteConfirmation: ViewModifier {
    @Binding var target: DeleteTarget?
    let onDeleted: @MainActor (DeleteTarget) -> Void

    @Environment(\.plexLibrary) private var library
    @Environment(LibraryChanges.self) private var changes
    @Environment(ToastCenter.self) private var toasts
    @State private var failure: String?

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
            .alert("Couldn't Delete", isPresented: Binding { failure != nil } set: { if !$0 { failure = nil } }) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failure ?? "")
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
        Task {
            do {
                switch target {
                case .title:
                    try await library.delete(item.ratingKey)
                    toasts.show("Deleted “\(item.title)”")
                case .version(_, let index):
                    try await library.deleteVersion(item.media[index].id, of: item.ratingKey)
                    toasts.show("Deleted the \(item.media[index].versionLabel) version")
                }
                changes.record(Set([item.ratingKey, item.parentRatingKey, item.grandparentRatingKey].compactMap(\.self)))
                onDeleted(target)
            } catch PlexError.unauthorized {
                failure = Self.notAllowed
            } catch PlexError.server(let status, _) where status == 403 {
                failure = Self.notAllowed
            } catch {
                failure = "“\(item.title)” wasn't deleted. \(error.localizedDescription)"
            }
        }
    }

    private static let notAllowed = "The Plex server doesn't allow deleting media. Turn on Allow media deletion in the server's Library settings, then try again."
}
