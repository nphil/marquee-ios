import MarqueeCore
import SwiftUI

/// Each destination as a tab and as a page (DESIGN §7). One without a tab opens as the same page pushed
/// onto the current tab's stack, so it looks alike wherever it opens.
extension Destination {
    var title: String {
        switch self {
        case .home: "Home"
        case .library: "Library"
        case .liveTV: "Live TV"
        case .watchlist: "Watchlist"
        case .search: "Search"
        case .requests: "Requests"
        case .downloads: "Downloads"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .library: "rectangle.stack"
        case .liveTV: "play.tv"
        case .watchlist: "bookmark"
        case .search: "magnifyingglass"
        case .requests: "rectangle.stack.badge.plus"
        case .downloads: "arrow.down.circle"
        }
    }

    /// Requests needs Seerr set up; the rest are always there.
    @MainActor
    func isAvailable(in session: AppSession) -> Bool {
        switch self {
        case .requests: session.seerr.isEnabled
        case .home, .library, .liveTV, .watchlist, .search, .downloads: true
        }
    }

    @MainActor
    static func available(in session: AppSession) -> Set<Destination> {
        Set(allCases.filter { $0.isAvailable(in: session) })
    }

    /// The number on the tab: downloads under way. Zero shows none.
    @MainActor
    func badge(in session: AppSession) -> Int {
        switch self {
        case .downloads: session.downloads.activeCount
        case .home, .library, .liveTV, .watchlist, .search, .requests: 0
        }
    }

    /// The page. Search opened from a button rather than its tab has its field ready to type in.
    @MainActor @ViewBuilder
    func page(pushed: Bool = false) -> some View {
        switch self {
        case .home: HomeView()
        case .library: LibraryView()
        case .liveTV: LiveTVView()
        case .watchlist: WatchlistView()
        case .search: SearchView(focusesField: pushed)
        case .requests: RequestsView()
        case .downloads: DownloadsView()
        }
    }
}

/// The tabs on the bar and the way to switch to one, set by the tab view. Outside it every destination
/// counts as a tab, so no page offers a second way in.
struct TabSelection {
    var tabs: [Destination] = Destination.allCases
    var select: @MainActor (Destination) -> Void = { _ in }

    func isTab(_ destination: Destination) -> Bool {
        tabs.contains(destination)
    }
}

/// Opens a destination: its tab when it has one, else its page pushed onto the current tab's stack.
struct OpenDestinationAction {
    let open: @MainActor (Destination) -> Void

    @MainActor
    func callAsFunction(_ destination: Destination) {
        open(destination)
    }
}

extension EnvironmentValues {
    @Entry var tabSelection = TabSelection()
    @Entry var openDestination = OpenDestinationAction { _ in }
}
