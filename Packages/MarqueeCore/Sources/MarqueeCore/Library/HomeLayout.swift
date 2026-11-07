import Foundation

/// A row Home can show: a hub from `/hubs/promoted`, or one from a library's `/hubs/sections/<key>`.
public struct HomeRow: Sendable, Hashable, Identifiable {
    /// The hub's `hubIdentifier`, prefixed with its library's id for a library hub, since two libraries
    /// of one kind name their hubs alike.
    public let id: String
    public var hub: PlexHub
    /// Nil for a Home hub.
    public let library: PlexLibrarySection?
    public var shown: Bool

    /// Shown unless it comes from a library: Home hubs are what Plex puts on Home, and a library holds
    /// a dozen more that would bury them.
    public init(hub: PlexHub, library: PlexLibrarySection? = nil) {
        self.hub = hub
        self.library = library
        id = library.map { "\(HomeLayout.libraryID($0))/\(hub.id)" } ?? hub.id
        shown = library == nil
    }
}

/// One profile's choice of Home rows: which show and in what order. Rows it never placed follow the
/// placed ones in the server's order with their default visibility, so a hub the server adds later
/// turns up at the end. Placed rows the server stops sending keep their place for when they return.
public struct HomeLayout: Codable, Hashable, Sendable {
    public struct Placement: Codable, Hashable, Sendable {
        public var id: String
        public var shown: Bool
        /// The library whose hubs carry the row (`libraryID(_:)`); nil for a Home hub.
        public var library: String?

        public init(id: String, shown: Bool, library: String? = nil) {
            self.id = id
            self.shown = shown
            self.library = library
        }
    }

    /// Empty until the profile changes something, which is the server's order.
    public var placements: [Placement]

    public init(placements: [Placement] = []) {
        self.placements = placements
    }

    public var isDefault: Bool { placements.isEmpty }

    /// The libraries with a shown row; Home asks only these for their hubs.
    public var shownLibraries: Set<String> {
        Set(placements.filter(\.shown).compactMap(\.library))
    }

    /// A library's id in a row's id: its uuid, which outlives a renumbered section, else its key.
    public static func libraryID(_ library: PlexLibrarySection) -> String {
        library.uuid ?? library.key
    }

    /// `rows`, in the server's order (Home hubs, then each library's), arranged by this layout. A
    /// repeated id keeps its first row.
    public func arrange(_ rows: [HomeRow]) -> [HomeRow] {
        var byID: [String: HomeRow] = [:]
        var serverOrder: [String] = []
        for row in rows where byID[row.id] == nil {
            byID[row.id] = row
            serverOrder.append(row.id)
        }
        var arranged: [HomeRow] = []
        for placement in placements {
            guard var row = byID.removeValue(forKey: placement.id) else { continue }
            row.shown = placement.shown
            arranged.append(row)
        }
        return arranged + serverOrder.compactMap { byID[$0] }
    }

    /// Makes `arranged` (an `arrange(_:)` result, edited) the layout. Each placed row missing from it
    /// stays right after the row it followed before.
    public mutating func save(_ arranged: [HomeRow]) {
        var saved = arranged.map {
            Placement(id: $0.id, shown: $0.shown, library: $0.library.map(Self.libraryID))
        }
        let present = Set(saved.map(\.id))
        var previous: String?
        for placement in placements {
            if !present.contains(placement.id) {
                let index = previous.flatMap { id in saved.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0
                saved.insert(placement, at: index)
            }
            previous = placement.id
        }
        placements = saved
    }
}
