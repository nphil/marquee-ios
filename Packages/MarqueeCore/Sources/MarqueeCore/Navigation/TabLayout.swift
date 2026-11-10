/// A top-level place in the app (DESIGN §7). Each can be a tab; one that is not keeps a way in from
/// another page.
public enum Destination: String, CaseIterable, Hashable, Sendable, Identifiable {
    case home, library, liveTV, watchlist, search, requests, downloads

    public var id: String { rawValue }
}

/// The tab bar as the person arranged it (DESIGN §7): every destination in their order, and which are
/// tabs. Home is always a tab, since its profile button opens Settings. Search stays last, where iOS
/// draws the search tab on its own.
public struct TabLayout: Hashable, Sendable {
    public static let maximumTabs = 5

    /// Home, Library, Live TV, Watchlist and Search.
    public static let standard = TabLayout(
        order: Destination.allCases,
        shown: [.home, .library, .liveTV, .watchlist, .search]
    )

    /// Every destination once, Search last.
    public private(set) var order: [Destination]
    /// The destinations switched on; always holds Home.
    public private(set) var shown: Set<Destination>

    /// Destinations missing from `order`, such as one a later version adds, follow it switched off.
    public init(order: [Destination], shown: Set<Destination>) {
        var seen: Set<Destination> = []
        var order = (order + Destination.allCases).filter { seen.insert($0).inserted }
        order.removeAll { $0 == .search }
        order.append(.search)
        self.order = order
        self.shown = shown.union([.home])
    }

    /// A layout saved as destination names; names this version does not know, such as one saved by a
    /// later version, are dropped.
    public init(savedOrder: [String], savedShown: [String]) {
        self.init(
            order: savedOrder.compactMap(Destination.init(rawValue:)),
            shown: Set(savedShown.compactMap(Destination.init(rawValue:)))
        )
    }

    /// The tabs switched on, by name in this layout's order, as `init(savedOrder:savedShown:)` reads them.
    public var savedShown: [String] {
        order.filter(shown.contains).map(\.rawValue)
    }

    /// The tabs in order: Home, and each destination switched on that is `available`. Past the maximum,
    /// which only a destination becoming available can reach, the last before Search give way and keep
    /// their other way in.
    public func tabs(available: Set<Destination>) -> [Destination] {
        var tabs = order.filter { $0 == .home || (shown.contains($0) && available.contains($0)) }
        while tabs.count > Self.maximumTabs,
              let last = tabs.lastIndex(where: { $0 != .home && $0 != .search }) {
            tabs.remove(at: last)
        }
        return tabs
    }

    /// Whether the switch for `destination` can change: never Home's or an unavailable one's, and an off
    /// one only while the bar has room.
    public func canSwitch(_ destination: Destination, available: Set<Destination>) -> Bool {
        guard destination != .home, available.contains(destination) else { return false }
        let tabs = tabs(available: available)
        return tabs.contains(destination) || tabs.count < Self.maximumTabs
    }

    /// Switches `destination` on or off as a tab when `canSwitch` allows. The edit starts from the bar on
    /// screen, so a destination switched on while unavailable or crowded out does not return unseen.
    public mutating func setTab(_ destination: Destination, _ on: Bool, available: Set<Destination>) {
        guard canSwitch(destination, available: available) else { return }
        var shown = Set(tabs(available: available))
        if on { shown.insert(destination) } else { shown.remove(destination) }
        self.shown = shown.union([.home])
    }

    /// Takes `order`, this layout's order rearranged, as the new order; Search stays last.
    public mutating func reorder(_ order: [Destination]) {
        self = TabLayout(order: order, shown: shown)
    }
}
