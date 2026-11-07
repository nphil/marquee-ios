import Foundation
import Observation

/// Loads a long list page by page for a grid (adapted from Stashy's `PaginatedLoader`).
///
/// - Every `reload` starts a new generation; a page that arrives for an older one is dropped, so quick
///   filter changes cannot mix two lists or leave `isLoading` stuck.
/// - The next page starts loading while the user is still three quarters of a page from the end, which
///   gives the request enough lead that a fast fling does not reach the end of the list.
/// - Items already in the list are skipped on append; Plex pages can overlap when the library changes
///   while paging, and duplicate ids break `ForEach`.
@Observable
@MainActor
public final class PagedLoader<Item: Identifiable & Sendable> {
    public typealias Fetch = @Sendable (_ start: Int, _ size: Int) async throws -> PlexPage<Item>

    public private(set) var items: [Item] = []
    /// True while the first page of a reload is loading; later pages load without showing anything.
    public private(set) var isLoading = false
    public private(set) var failure: (any Error)?
    public private(set) var totalSize: Int?
    /// Bumped whenever `items` is replaced or extended.
    public private(set) var contentRevision = 0
    /// When the first page last arrived.
    public private(set) var loadedAt: Date?

    public let pageSize: Int
    @ObservationIgnored private var fetch: Fetch?
    /// Server offset of the next page. Counts items as the server sent them, before duplicates are skipped.
    @ObservationIgnored private var nextStart = 0
    @ObservationIgnored private var hasMore = false
    @ObservationIgnored private var nextPageGeneration: Int?
    /// The page on its way, so a jump can wait for it rather than give up.
    @ObservationIgnored private var nextPage: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    public init(pageSize: Int = 60) {
        self.pageSize = pageSize
    }

    /// Sets the query (captured by `fetch`) and loads the first page. The current items stay visible until
    /// the new page replaces them.
    public func reload(using fetch: @escaping Fetch) async {
        self.fetch = fetch
        await loadFirstPage(keepingItemsOnFailure: false)
    }

    /// Loads the first page again with the last query. When that fails, the items already shown stay, with
    /// `failure` set, so a refresh while offline keeps the last good list on screen.
    public func refresh() async {
        await loadFirstPage(keepingItemsOnFailure: true)
    }

    private func loadFirstPage(keepingItemsOnFailure: Bool) async {
        guard let fetch else { return }
        generation += 1
        let current = generation
        nextPageGeneration = nil
        isLoading = true
        if !keepingItemsOnFailure { failure = nil }
        do {
            let page = try await fetch(0, pageSize)
            guard current == generation else { return }
            items = page.items
            totalSize = page.totalSize
            nextStart = page.items.count
            hasMore = nextStart < page.totalSize && !page.items.isEmpty
            failure = nil
            loadedAt = .now
            contentRevision &+= 1
        } catch {
            guard current == generation else { return }
            // A load cancelled because its screen went away is not a failure; the screen loads again when
            // it returns.
            if !Task.isCancelled {
                if !keepingItemsOnFailure {
                    items = []
                    totalSize = nil
                    hasMore = false
                    contentRevision &+= 1
                }
                failure = error
            }
        }
        isLoading = false
    }

    /// Call when the item with `id` appears; loads the next page once it is near the end.
    public func loadMoreIfNeeded(after id: Item.ID) async {
        guard canLoadMore, items.suffix(max(1, pageSize * 3 / 4)).contains(where: { $0.id == id }) else { return }
        await loadNext(size: pageSize)
    }

    /// Loads as far as `index` in one request, e.g. for an A–Z jump to a letter further down. A page already
    /// on its way is waited for first, since a second request cannot start beside it.
    public func ensureLoaded(through index: Int) async {
        if nextPageGeneration != nil, let nextPage {
            await nextPage.value
        }
        guard canLoadMore, index >= nextStart else { return }
        await loadNext(size: index - nextStart + pageSize)
    }

    /// Replaces a loaded item in place. Returns false when it is not loaded.
    @discardableResult
    public func patch(_ item: Item) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return false }
        items[index] = item
        contentRevision &+= 1
        return true
    }

    private var canLoadMore: Bool {
        hasMore && !isLoading && nextPageGeneration == nil && fetch != nil
    }

    private func loadNext(size: Int) async {
        guard let fetch else { return }
        let current = generation
        let start = nextStart
        nextPageGeneration = current
        // A task of its own, so the page lands even when the cell that asked for it scrolls away.
        let page = Task {
            defer { if nextPageGeneration == current { nextPageGeneration = nil } }
            do {
                let page = try await fetch(start, size)
                guard current == generation else { return }
                var seen = Set(items.map(\.id))
                items.append(contentsOf: page.items.filter { seen.insert($0.id).inserted })
                totalSize = page.totalSize
                nextStart += page.items.count
                hasMore = nextStart < page.totalSize && !page.items.isEmpty
                contentRevision &+= 1
            } catch {
                guard current == generation else { return }
                failure = error
            }
        }
        nextPage = page
        await page.value
    }
}
