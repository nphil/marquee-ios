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

/// What a title's tags say: whether it is anime, and the countries it was made in.
public struct TitleTags: Sendable, Hashable {
    public var isAnime: Bool
    public var countries: [String]

    public init(isAnime: Bool, countries: [String]) {
        self.isAnime = isAnime
        self.countries = countries
    }

    init(_ item: PlexMetadata) {
        self.init(isAnime: item.isAnime, countries: item.countries)
    }
}

/// Reads the tags of a title, taking an episode's or season's from its show once. The lookup is made
/// for a play or a download, never for a list of items, so the cost is one read per show.
public actor AnimeLookup {
    private var shows: [String: TitleTags] = [:]

    public init() {}

    /// A failed read answers the item's own tags and is made again next time.
    public func tags(_ item: PlexMetadata, in library: PlexLibrary) async -> TitleTags {
        let own = TitleTags(item)
        guard item.type != .show, let show = item.showRatingKey else { return own }
        let key = "\(library.server.clientIdentifier)/\(show)"
        if let known = shows[key] { return merged(own, known) }
        guard let found = try? await library.metadata(show) else { return own }
        shows[key] = TitleTags(found)
        return merged(own, TitleTags(found))
    }

    private func merged(_ own: TitleTags, _ show: TitleTags) -> TitleTags {
        TitleTags(isAnime: own.isAnime || show.isAnime, countries: own.countries.isEmpty ? show.countries : own.countries)
    }
}
