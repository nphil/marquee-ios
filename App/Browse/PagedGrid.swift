import MarqueeCore
import SwiftUI

extension PagedLoader where Item.ID: Sendable {
    /// A grid cell's `onAppear`: starts the next page once the cell is a quarter into the newest one. The
    /// check is synchronous, so a cell in the middle of the list scans nothing and starts no task.
    func cellAppeared(_ id: Item.ID) {
        guard wantsNextPage(after: id) else { return }
        ScrollMonitor.shared.pageRequested()
        Task { await loadMoreIfNeeded(after: id) }
    }
}

extension View {
    /// Queues the posters of a paged grid's newest page when the page lands, nearest first through the image
    /// pipeline's bounded queue, so no cell starts loads for the cells below it. Each cell still loads its
    /// own poster; this only has the next ones in memory by the time they appear.
    func prefetchesNewestPage(of loader: PagedLoader<PlexMetadata>, cellWidth: CGFloat) -> some View {
        modifier(NewestPagePrefetch(loader: loader, cellWidth: cellWidth))
    }
}

private struct NewestPagePrefetch: ViewModifier {
    let loader: PagedLoader<PlexMetadata>
    let cellWidth: CGFloat
    private let prefetch = ArtPrefetcher()
    @State private var seen = TitlesSeen()

    func body(content: Content) -> some View {
        content.onChange(of: loader.contentRevision, initial: true) {
            let count = loader.items.count
            ScrollMonitor.shared.pageAppended(items: count - seen.count)
            seen.count = count
            prefetch(loader.items.suffix(loader.pageSize).map(\.posterPath), size: PosterCell.artSize(width: cellWidth))
        }
    }
}

/// How many titles the grid held at the last change, to tell how many a page added. A plain box, so writing
/// it invalidates no view.
private final class TitlesSeen {
    var count = 0
}
