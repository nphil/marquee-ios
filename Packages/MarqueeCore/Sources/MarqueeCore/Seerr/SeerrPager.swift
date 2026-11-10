import Foundation
import Observation

/// Pages through one Seerr Discover list by page number, for the browse grid.
///
/// - Every `reload` starts a new generation; a page that arrives for an older one is dropped, so quick
///   filter changes cannot mix two lists.
/// - The next page starts when one of the last titles scrolls into view.
/// - Titles already shown are skipped on append: TMDB's order shifts while paging, so pages overlap.
@Observable
@MainActor
public final class SeerrPager {
    public typealias Fetch = @Sendable (_ page: Int) async throws -> SeerrTitlePage

    public private(set) var items: [SeerrTitle] = []
    /// True while the first page of a reload is on its way; later pages load without showing anything.
    public private(set) var isLoading = false
    /// The first page's failure; with nothing to show, the screen offers a retry.
    public private(set) var failure: (any Error)?
    /// A later page failed: the titles so far stay, and `loadMore()` tries again.
    public private(set) var moreFailed = false
    /// The first page arrived, even when it held nothing.
    public private(set) var hasLoaded = false
    public private(set) var hasMore = false

    @ObservationIgnored private var fetch: Fetch?
    @ObservationIgnored private var nextPage = 1
    @ObservationIgnored private var isLoadingMore = false
    @ObservationIgnored private var generation = 0

    public init() {}

    /// Starts over with a new list and loads its first page. The old titles go at once, so the screen
    /// shows its skeleton rather than titles that no longer match.
    public func reload(using fetch: @escaping Fetch) async {
        self.fetch = fetch
        items = []
        hasLoaded = false
        await loadFirstPage()
    }

    /// Loads the first page of the same list again. Titles already shown stay until it arrives, and
    /// after a failure.
    public func refresh() async {
        await loadFirstPage()
    }

    private func loadFirstPage() async {
        guard let fetch else { return }
        generation += 1
        let current = generation
        isLoading = true
        isLoadingMore = false
        failure = nil
        moreFailed = false
        do {
            let page = try await fetch(1)
            guard current == generation else { return }
            items = Self.unique(page.titles)
            nextPage = page.page + 1
            hasMore = page.hasMore
            hasLoaded = true
        } catch {
            guard current == generation else { return }
            // A load cancelled because its screen went away is not a failure; the screen loads again
            // when it returns.
            if !Task.isCancelled { failure = error }
        }
        isLoading = false
    }

    /// Call when the title with `id` appears; loads the next page once it is near the end.
    public func loadMoreIfNeeded(after id: SeerrTitle.ID) async {
        guard !moreFailed, items.suffix(Self.lead).contains(where: { $0.id == id }) else { return }
        await loadMore()
    }

    /// Loads the next page, or tries again after a failure.
    public func loadMore() async {
        guard let fetch, hasMore, !isLoading, !isLoadingMore else { return }
        isLoadingMore = true
        moreFailed = false
        let current = generation
        // A page can hold only titles already shown; the list ends only at Seerr's last page.
        while hasMore, current == generation {
            do {
                let page = try await fetch(nextPage)
                guard current == generation else { return }
                var seen = Set(items.map(\.id))
                let fresh = page.titles.filter { seen.insert($0.id).inserted }
                items.append(contentsOf: fresh)
                nextPage = page.page + 1
                hasMore = page.hasMore
                if !fresh.isEmpty { break }
            } catch {
                guard current == generation else { return }
                if !Task.isCancelled { moreFailed = true }
                break
            }
        }
        if current == generation { isLoadingMore = false }
    }

    /// How many titles from the end the next page starts: three rows of the widest grid.
    static let lead = 9

    private static func unique(_ titles: [SeerrTitle]) -> [SeerrTitle] {
        var seen = Set<SeerrTitle.ID>()
        return titles.filter { seen.insert($0.id).inserted }
    }
}
