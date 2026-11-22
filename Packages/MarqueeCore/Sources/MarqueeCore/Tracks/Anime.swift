import Foundation

/// Whether a title is anime, by Plex's own tags.
public enum Anime {
    /// The genre Anime, or the genre Animation made in Japan.
    public static func matches(genres: [String], countries: [String]) -> Bool {
        let genres = Set(genres.map { $0.lowercased() })
        return genres.contains("anime") || (genres.contains("animation") && countries.contains { $0.lowercased() == "japan" })
    }
}

extension PlexMetadata {
    /// By this title's own tags, so false for an episode, which carries none: ask `AnimeLookup`.
    public var isAnime: Bool { Anime.matches(genres: genres, countries: countries) }
}

/// Tells whether a title is anime, reading the show of an episode or season once. The lookup is made
/// for a play or a download, never for a list of items, so the cost is one read per show.
public actor AnimeLookup {
    private var shows: [String: Bool] = [:]

    public init() {}

    /// A failed read answers no and is made again next time.
    public func isAnime(_ item: PlexMetadata, in library: PlexLibrary) async -> Bool {
        if item.isAnime { return true }
        guard item.type != .show, let show = item.showRatingKey else { return false }
        let key = "\(library.server.clientIdentifier)/\(show)"
        if let known = shows[key] { return known }
        guard let found = try? await library.metadata(show) else { return false }
        shows[key] = found.isAnime
        return found.isAnime
    }
}
