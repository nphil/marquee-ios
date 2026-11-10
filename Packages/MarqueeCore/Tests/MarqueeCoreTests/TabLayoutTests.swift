import Testing
@testable import MarqueeCore

struct TabLayoutTests {
    private let all = Set(Destination.allCases)

    @Test func standardBarIsTheFiveOriginalTabsWithSearchLast() {
        let layout = TabLayout.standard

        #expect(layout.tabs(available: all) == [.home, .library, .liveTV, .watchlist, .search])
        #expect(layout.order.last == .search)
    }

    @Test func homeIsAlwaysATabAndUnavailableDestinationsAreNot() {
        let layout = TabLayout(order: [.requests, .home, .library], shown: [.requests, .library])

        #expect(layout.tabs(available: all.subtracting([.requests])) == [.home, .library])
        #expect(layout.tabs(available: all) == [.requests, .home, .library])
    }

    @Test func aDestinationBecomingAvailablePastTheMaximumGivesWayBeforeSearch() {
        let layout = TabLayout(
            order: [.home, .library, .requests, .liveTV, .watchlist],
            shown: [.library, .requests, .liveTV, .watchlist, .search]
        )

        #expect(layout.tabs(available: all.subtracting([.requests])) == [.home, .library, .liveTV, .watchlist, .search])
        #expect(layout.tabs(available: all) == [.home, .library, .requests, .liveTV, .search])
    }

    @Test func switchesFollowTheRules() {
        var layout = TabLayout.standard
        let noRequests = all.subtracting([.requests])

        #expect(!layout.canSwitch(.home, available: all))
        #expect(!layout.canSwitch(.requests, available: noRequests))
        #expect(!layout.canSwitch(.downloads, available: all))
        #expect(layout.canSwitch(.watchlist, available: all))

        layout.setTab(.downloads, true, available: all)
        #expect(layout.tabs(available: all).contains(.downloads) == false)

        layout.setTab(.watchlist, false, available: all)
        layout.setTab(.downloads, true, available: all)
        #expect(layout.tabs(available: all) == [.home, .library, .liveTV, .downloads, .search])
    }

    @Test func anEditKeepsOnlyWhatTheBarShows() {
        var layout = TabLayout(order: Destination.allCases, shown: [.library, .requests])

        layout.setTab(.watchlist, true, available: all.subtracting([.requests]))

        #expect(layout.tabs(available: all) == [.home, .library, .watchlist])
    }

    @Test func reorderingKeepsSearchLast() {
        var layout = TabLayout.standard

        layout.reorder([.search, .watchlist, .home, .library, .liveTV, .requests, .downloads])

        #expect(layout.order == [.watchlist, .home, .library, .liveTV, .requests, .downloads, .search])
        #expect(layout.tabs(available: all) == [.watchlist, .home, .library, .liveTV, .search])
    }

    @Test func savedLayoutReadsBackAndSkipsUnknownNames() {
        var layout = TabLayout.standard
        layout.reorder([.downloads, .home])
        #expect(TabLayout(savedOrder: layout.order.map(\.rawValue), savedShown: layout.savedShown) == layout)

        let saved = TabLayout(savedOrder: ["teleport", "library", "home"], savedShown: ["library", "teleport"])

        #expect(saved.order == [.library, .home, .liveTV, .watchlist, .requests, .downloads, .search])
        #expect(saved.tabs(available: all) == [.library, .home])
    }
}
