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

    public let pageSize: Int
    @ObservationIgnored private var fetch: Fetch?
    /// Server offset of the next page. Counts items as the server sent them, before duplicates are skipped.
    @ObservationIgnored private var nextStart = 0
    @ObservationIgnored private var hasMore = false
    @ObservationIgnored private var nextPageGeneration: Int?
    @ObservationIgnored private var generation = 0

    public init(pageSize: Int = 60) {
        self.pageSize = pageSize
    }

    /// Sets the query (captured by `fetch`) and loads the first page. The current items stay visible until
    /// the new page replaces them.
    public func reload(using fetch: @escaping Fetch) async {
        self.fetch = fetch
        generation += 1
        let current = generation
        nextPageGeneration = nil
        isLoading = true
        failure = nil
        do {
            let page = try await fetch(0, pageSize)
            guard current == generation else { return }
            items = page.items
            totalSize = page.totalSize
            nextStart = page.items.count
            hasMore = nextStart < page.totalSize && !page.items.isEmpty
            contentRevision &+= 1
        } catch {
            guard current == generation else { return }
            items = []
            totalSize = nil
            hasMore = false
            failure = error
            contentRevision &+= 1
        }
        isLoading = false
    }

    /// Call when the item with `id` appears; loads the next page once it is near the end.
    public func loadMoreIfNeeded(after id: Item.ID) async {
        guard canLoadMore, items.suffix(max(1, pageSize * 3 / 4)).contains(where: { $0.id == id }) else { return }
        await loadNext(size: pageSize)
    }

    /// Loads as far as `index` in one request, e.g. for an A–Z jump to a letter further down.
    public func ensureLoaded(through index: Int) async {
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
        nextPageGeneration = current
        defer { if nextPageGeneration == current { nextPageGeneration = nil } }
        do {
            let page = try await fetch(nextStart, size)
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
}
