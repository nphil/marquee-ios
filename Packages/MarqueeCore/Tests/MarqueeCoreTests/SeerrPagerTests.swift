import Foundation
import Testing
@testable import MarqueeCore

@MainActor
struct SeerrPagerTests {
    nonisolated static func title(_ id: Int) -> SeerrTitle {
        SeerrTitle(kind: .movie, tmdbID: id, name: "Title \(id)")
    }

    /// Seerr pages of `size` titles numbered from 1, in `pages` pages, recording every request.
    actor Server {
        private(set) var requests: [Int] = []
        private(set) var isDown = false
        private let size: Int
        private let pages: Int
        private var shift = 0

        init(size: Int, pages: Int) {
            self.size = size
            self.pages = pages
        }

        func goDown() { isDown = true }
        func comeUp() { isDown = false }
        /// The list moved on by `by` titles since the last page, so the next page repeats some.
        func shiftList(by: Int) { shift += by }

        func page(_ number: Int) throws -> SeerrTitlePage {
            requests.append(number)
            if isDown { throw SeerrError.unreachable }
            let first = (number - 1) * size + 1 - shift
            return SeerrTitlePage(titles: (first..<first + size).map(SeerrPagerTests.title), page: number, totalPages: pages)
        }
    }

    @Test func nextPageLoadsOnlyNearTheEndAndStopsAtTheLastPage() async {
        let server = Server(size: 20, pages: 3)
        let pager = SeerrPager()
        await pager.reload { try await server.page($0) }

        await pager.loadMoreIfNeeded(after: "movie/1")
        #expect(pager.items.count == 20)
        await pager.loadMoreIfNeeded(after: "movie/20")
        await pager.loadMoreIfNeeded(after: "movie/40")
        await pager.loadMoreIfNeeded(after: "movie/60")

        #expect(pager.items.count == 60 && !pager.hasMore)
        #expect(await server.requests == [1, 2, 3])
    }

    @Test func titlesTheListMovedPastAreShownOnce() async {
        let server = Server(size: 5, pages: 4)
        let pager = SeerrPager()
        await pager.reload { try await server.page($0) }
        await server.shiftList(by: 2)

        await pager.loadMoreIfNeeded(after: "movie/5")

        #expect(pager.items.map(\.tmdbID) == Array(1...8))
    }

    @Test func aPageOfOnlyRepeatsLoadsTheNextOne() async {
        let pager = SeerrPager()
        await pager.reload { page in
            switch page {
            case 1: SeerrTitlePage(titles: [Self.title(1), Self.title(2)], page: 1, totalPages: 3)
            case 2: SeerrTitlePage(titles: [Self.title(2)], page: 2, totalPages: 3)
            default: SeerrTitlePage(titles: [Self.title(3)], page: 3, totalPages: 3)
            }
        }
        await pager.loadMoreIfNeeded(after: "movie/2")

        #expect(pager.items.map(\.tmdbID) == [1, 2, 3])
    }

    @Test func aLaterPageFailingKeepsTheListAndRetries() async {
        let server = Server(size: 4, pages: 2)
        let pager = SeerrPager()
        await pager.reload { try await server.page($0) }
        await server.goDown()
        await pager.loadMoreIfNeeded(after: "movie/4")
        #expect(pager.items.count == 4 && pager.moreFailed && pager.failure == nil)

        await pager.loadMoreIfNeeded(after: "movie/4")
        #expect(await server.requests == [1, 2])

        await server.comeUp()
        await pager.loadMore()
        #expect(pager.items.count == 8 && !pager.moreFailed)
    }

    @Test func failedFirstPageShowsNothingAndFailedRefreshKeepsTheList() async {
        let server = Server(size: 4, pages: 2)
        await server.goDown()
        let pager = SeerrPager()
        await pager.reload { try await server.page($0) }
        #expect(pager.items.isEmpty && !pager.hasLoaded && pager.failure as? SeerrError == .unreachable)

        await server.comeUp()
        await pager.refresh()
        #expect(pager.items.count == 4 && pager.hasLoaded && pager.failure == nil)
        await server.goDown()
        await pager.refresh()
        #expect(pager.items.count == 4 && pager.failure as? SeerrError == .unreachable)
    }

    @Test func refreshingLoadedPagesKeepsTheListLongAndAFailureKeepsItToo() async {
        let server = Server(size: 4, pages: 3)
        let pager = SeerrPager()
        await pager.reload { try await server.page($0) }
        await pager.loadMore()

        await pager.refreshLoaded()
        #expect(pager.items.count == 8 && pager.hasMore && pager.failure == nil)
        #expect(await server.requests == [1, 2, 1, 2])

        await server.goDown()
        await pager.refreshLoaded()
        #expect(pager.items.count == 8 && pager.failure as? SeerrError == .unreachable)
    }

    @Test func pageForAnOlderReloadIsDropped() async {
        let pager = SeerrPager()
        let started = Gate()
        let release = Gate()
        let slow = Task {
            await pager.reload { _ in
                await started.open()
                await release.wait()
                return SeerrTitlePage(titles: [Self.title(1)], page: 1, totalPages: 1)
            }
        }
        await started.wait()
        await pager.reload { _ in SeerrTitlePage(titles: [Self.title(2)], page: 1, totalPages: 1) }
        await release.open()
        await slow.value

        #expect(pager.items.map(\.tmdbID) == [2] && !pager.isLoading)
    }

    @Test func aReloadClearsTheOldTitlesAtOnce() async {
        let pager = SeerrPager()
        await pager.reload { _ in SeerrTitlePage(titles: [Self.title(1)], page: 1, totalPages: 1) }
        let started = Gate()
        let release = Gate()
        let next = Task {
            await pager.reload { _ in
                await started.open()
                await release.wait()
                return SeerrTitlePage(titles: [], page: 1, totalPages: 1)
            }
        }
        await started.wait()
        #expect(pager.items.isEmpty && pager.isLoading && !pager.hasLoaded)
        await release.open()
        await next.value
        #expect(pager.hasLoaded && pager.items.isEmpty)
    }
}
