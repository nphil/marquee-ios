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
        let stable = HomeLayout.stableID(hub.id)
        id = library.map { "\(HomeLayout.libraryID($0))/\(stable)" } ?? stable
        shown = library == nil
    }
}

/// One profile's choice of Home rows: which show and in what order. Rows it never placed follow the
/// placed ones in the server's order with their default visibility, so a hub the server adds later
/// turns up at the end. Placed rows the server stops sending keep their place for when they return.
/// Row ids are `stableID`s, so a layout saved by an older version reads the same as a new one.
public struct HomeLayout: Codable, Hashable, Sendable {
    public struct Placement: Codable, Hashable, Sendable {
        public var id: String
        public var shown: Bool
        /// The library whose hubs carry the row (`libraryID(_:)`); nil for a Home hub.
        public var library: String?

        public init(id: String, shown: Bool, library: String? = nil) {
            self.id = HomeLayout.stableID(id)
            self.shown = shown
            self.library = library
        }

        enum CodingKeys: String, CodingKey { case id, shown, library }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                id: try c.decode(String.self, forKey: .id),
                shown: try c.decodeIfPresent(Bool.self, forKey: .shown) ?? true,
                library: try c.decodeIfPresent(String.self, forKey: .library)
            )
        }
    }

    /// Empty until the profile changes something, which is the server's order.
    public var placements: [Placement]

    public init(placements: [Placement] = []) {
        var seen: Set<String> = []
        self.placements = placements.filter { seen.insert($0.id).inserted }
    }

    /// Placements that no longer decode are dropped one by one, so one odd entry from an older version
    /// does not bring every row back.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var list = try c.nestedUnkeyedContainer(forKey: .placements)
        var placements: [Placement] = []
        while !list.isAtEnd {
            if let placement = try? list.decode(Placement.self) {
                placements.append(placement)
            } else {
                _ = try? list.decode(Discarded.self)
            }
        }
        self.init(placements: placements)
    }

    private enum CodingKeys: String, CodingKey { case placements }
    private struct Discarded: Decodable {}

    /// A hub's id without the part Plex rotates: "Top Movies in <genre>" and "Top Movies with <person>"
    /// come with a new genre or person on each request and for each account
    /// (`movie.genre.1.3718`, `movie.genre.1.6`), so the row is `movie.genre.1`. Every other id is
    /// unchanged.
    public static func stableID(_ id: String) -> String {
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 4, parts.last.map({ !$0.isEmpty && !$0.contains("/") }) ?? false,
              parts[parts.count - 2].allSatisfy(\.isNumber) else { return id }
        let kind = parts.dropLast(2).joined(separator: ".")
        guard kind.hasSuffix(".genre") || kind.hasSuffix(".by.actor.or.director") else { return id }
        return parts.dropLast().joined(separator: ".")
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
