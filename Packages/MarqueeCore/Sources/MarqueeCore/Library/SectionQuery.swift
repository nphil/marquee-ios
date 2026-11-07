import Foundation

/// One page of a paged list.
public struct PlexPage<Item: Sendable>: Sendable {
    public var items: [Item]
    /// Items behind the whole request.
    public var totalSize: Int

    public init(items: [Item], totalSize: Int) {
        self.items = items
        self.totalSize = totalSize
    }
}

/// What a library grid lists: the item type, a sort, the Unwatched filter and a genre.
public struct SectionQuery: Sendable, Hashable {
    public var type: PlexMediaType
    public var sort: Sort
    public var unwatchedOnly: Bool
    /// An entry of `PlexLibrary.genres(in:)`.
    public var genre: PlexDirectory?

    public init(type: PlexMediaType, sort: Sort = .title, unwatchedOnly: Bool = false, genre: PlexDirectory? = nil) {
        self.type = type
        self.sort = sort
        self.unwatchedOnly = unwatchedOnly
        self.genre = genre
    }

    public enum Sort: String, Sendable, Hashable, CaseIterable {
        case title = "titleSort"
        case recentlyAdded = "addedAt:desc"
        case releaseDate = "originallyAvailableAt:desc"
        case recentlyWatched = "lastViewedAt:desc"
        case rating = "rating:desc"
    }

    /// Query items for `/all` and `/firstCharacter`. A show counts as unwatched while any of its
    /// episodes is (`unwatchedLeaves`); a movie or episode by its own state (`unwatched`).
    public var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let code = type.code { items.append(URLQueryItem(name: "type", value: String(code))) }
        items.append(URLQueryItem(name: "sort", value: sort.rawValue))
        if unwatchedOnly {
            items.append(URLQueryItem(name: type == .show ? "unwatchedLeaves" : "unwatched", value: "1"))
        }
        if let genre { items.append(URLQueryItem(name: "genre", value: genre.key)) }
        return items
    }
}

/// One letter of the A–Z jump bar, with the position of its first title in the sorted list.
public struct AlphabetIndexEntry: Sendable, Hashable {
    public var character: String
    public var count: Int
    public var offset: Int

    public init(character: String, count: Int, offset: Int) {
        self.character = character
        self.count = count
        self.offset = offset
    }

    /// Letters from `/firstCharacter` in server order. Each letter starts where the counts before it end.
    public static func entries(from directories: [PlexDirectory]) -> [AlphabetIndexEntry] {
        var offset = 0
        return directories.map { directory in
            defer { offset += directory.size }
            let character = directory.title.isEmpty ? directory.key : directory.title
            return AlphabetIndexEntry(character: character, count: directory.size, offset: offset)
        }
    }
}
