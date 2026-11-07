import Foundation
import MarqueeCore
import SwiftUI

/// What shows under the posters of movies and shows (behaviour spec §1, "Under posters"), per profile.
/// Decoding fills a missing or unreadable key with its default, like `ProfileSettings`.
struct PosterLabels: Equatable, Sendable {
    var showsTitle = true
    var details = Details.none
    /// While a library grid is sorted by anything but Title or Random, the value it is sorted by replaces
    /// the details line.
    var showsSortValue = true

    enum Details: String, Codable, CaseIterable, Sendable {
        case none, yearAndLength, genre, video, ratingAndScore

        var title: String {
            switch self {
            case .none: "Nothing"
            case .yearAndLength: "Year · Length"
            case .genre: "Genre"
            case .video: "Video"
            case .ratingAndScore: "Age Rating · Score"
            }
        }
    }
}

extension PosterLabels: Codable {
    enum CodingKeys: String, CodingKey {
        case showsTitle, details, showsSortValue
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys) -> T? { try? c.decodeIfPresent(T.self, forKey: key) }
        self.init()
        showsTitle = value(.showsTitle) ?? showsTitle
        details = value(.details) ?? details
        showsSortValue = value(.showsSortValue) ?? showsSortValue
    }
}

extension EnvironmentValues {
    /// The active profile's poster labels, set over the signed-in screens.
    @Entry var posterLabels = PosterLabels()
    /// The sort of the library grid a poster sits in, for its sort value; nil outside a library grid.
    @Entry var posterSort: SectionQuery.Sort? = nil
}

/// The line under a poster's title. "Never" is quiet: a fact about the sort, not about the title.
struct PosterLine: Equatable {
    var text: String
    var isQuiet = false
}

extension PosterLabels {
    /// Whether posters keep room for a line under the title, so titles in a grid row line up.
    func reservesLine(sort: SectionQuery.Sort?) -> Bool {
        details != .none || (showsSortValue && sort.map { $0 != .title && $0 != .random } == true)
    }

    /// The Settings row's value: "Title, Year · Length", "Title", "Nothing".
    var summary: String {
        let parts = [showsTitle ? "Title" : nil, details == .none ? nil : details.title].compactMap(\.self)
        return parts.isEmpty ? "Nothing" : parts.joined(separator: ", ")
    }
}

extension PlexMetadata {
    /// The line under a poster: the sort value in a grid sorted by one, otherwise the chosen details.
    func posterLine(_ labels: PosterLabels, sort: SectionQuery.Sort?, now: Date = .now) -> PosterLine? {
        if labels.showsSortValue, let sort, let value = sortValue(sort, now: now) { return value }
        return posterDetails(labels.details, now: now).map { PosterLine(text: $0) }
    }

    /// The value a grid sorted by `sort` is ordered on: "Today", "7 Mar 2024", "7.8", "14 plays", "Never".
    /// Nil for Title and Random, and for a date or score the title does not have.
    func sortValue(_ sort: SectionQuery.Sort, now: Date = .now) -> PosterLine? {
        let never = PosterLine(text: "Never", isQuiet: true)
        switch sort {
        case .title, .random:
            return nil
        case .recentlyAdded:
            return addedAt.map { PosterLine(text: ItemText.day($0, now: now)) }
        case .releaseDate:
            return ItemText.releaseDate(originallyAvailableAt, now: now).map { PosterLine(text: $0) }
        case .recentlyWatched:
            return lastViewedAt.map { PosterLine(text: ItemText.day($0, now: now)) } ?? never
        case .rating:
            return rating.map { PosterLine(text: ItemText.score($0)) }
        case .audienceRating:
            return audienceRating.map { PosterLine(text: ItemText.score($0)) }
        case .plays:
            // A no-break space keeps the count with its noun under a narrow poster.
            return viewCount == 0 ? never : PosterLine(text: viewCount == 1 ? "1\u{00A0}play" : "\(viewCount)\u{00A0}plays")
        }
    }

    /// The details line, worded for the kind of title. A started title shows the time left, one not yet
    /// released its release date, and a collection how many titles it holds, whatever was chosen.
    func posterDetails(_ details: PosterLabels.Details, now: Date = .now) -> String? {
        guard details != .none, [.movie, .show, .collection].contains(type) else { return nil }
        if type == .collection {
            return childCount.map { $0 == 1 ? "1 title" : "\($0) titles" }
        }
        if let minutesLeft { return ItemText.left(minutesLeft) }
        if let release = ItemText.releaseDay(originallyAvailableAt), release > now {
            return ItemText.releaseDate(originallyAvailableAt, now: now)
        }
        let yearText = year.map(String.init)
        switch details {
        case .none:
            return nil
        case .yearAndLength:
            if type == .show {
                if let unwatched = unwatchedLeafCount, unwatched > 0, (viewedLeafCount ?? 0) > 0 {
                    return unwatched == 1 ? "1 new episode" : "\(unwatched) new episodes"
                }
                return Self.joined([yearText, childCount.map { $0 == 1 ? "1 season" : "\($0) seasons" }])
            }
            return Self.joined([yearText, ItemText.runtime(duration)])
        case .genre:
            return genres.first
        case .video:
            guard type == .movie, let first = media.first else { return yearText }
            return Self.joined(first.videoMarks)
        case .ratingAndScore:
            return Self.joined([contentRating, (audienceRating ?? rating).map(ItemText.score)])
        }
    }

    private static func joined(_ parts: [String?]) -> String? {
        let line = parts.compactMap(\.self).filter { !$0.isEmpty }.joined(separator: " · ")
        return line.isEmpty ? nil : line
    }
}
