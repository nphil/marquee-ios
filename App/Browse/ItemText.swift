import Foundation
import MarqueeCore

/// The words and artwork choices shared by every browse screen.
extension PlexMetadata {
    /// Part-watched progress from 0 to 1; nil when not started or finished.
    var progress: Double? {
        guard duration > 0, viewOffset > 0, viewOffset < duration else { return nil }
        return Double(viewOffset) / Double(duration)
    }

    /// Whole minutes left, rounded up; nil when not started.
    var minutesLeft: Int? {
        guard progress != nil else { return nil }
        return max(1, Int((Double(duration - viewOffset) / 60_000).rounded(.up)))
    }

    /// "S2 · E5" for an episode.
    var episodeCode: String? {
        guard type == .episode, let season = parentIndex, let episode = index else { return nil }
        return "S\(season) · E\(episode)"
    }

    /// The 2:3 artwork. An episode in a poster shelf shows its show's poster.
    var posterPath: String? {
        switch type {
        case .episode: grandparentThumb ?? parentThumb ?? thumb
        case .season: thumb ?? parentThumb
        default: thumb
        }
    }

    /// The 16:9 artwork for a card or a hero.
    var backdropPath: String? {
        art ?? grandparentArt
    }

    /// The name under a poster: an episode goes by its show.
    var posterTitle: String {
        type == .episode ? (grandparentTitle ?? title) : title
    }

    /// The unwatched-episode badge, or nil for titles without episodes.
    var unwatchedBadge: Int? {
        guard type == .show || type == .season, let count = unwatchedLeafCount, count > 0 else { return nil }
        return count
    }

    /// What VoiceOver reads for a poster or row (DESIGN §10): "Title, movie, 2019, 42 minutes left".
    var spokenSummary: String {
        var parts: [String]
        switch type {
        case .episode:
            parts = [grandparentTitle ?? "", parentIndex.map { "season \($0)" } ?? "", index.map { "episode \($0)" } ?? "", title]
        case .movie, .show, .collection:
            parts = [title, type.rawValue]
        case .season:
            parts = [parentTitle ?? "", title]
        default:
            parts = [title]
        }
        if let year, type != .episode { parts.append(String(year)) }
        if let minutesLeft {
            parts.append(ItemText.spokenLeft(minutesLeft))
        } else if let unwatched = unwatchedBadge {
            parts.append(unwatched == 1 ? "1 unwatched episode" : "\(unwatched) unwatched episodes")
        } else if isWatched, type != .collection {
            parts.append("watched")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

enum ItemText {
    /// "42 min", "2 h 14 m", "2 h" (DESIGN §8.3).
    static func duration(minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(rest) min" }
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) m"
    }

    /// A runtime in milliseconds, rounded to the minute; nil when unknown.
    static func runtime(_ milliseconds: Int) -> String? {
        guard milliseconds >= 30_000 else { return nil }
        return duration(minutes: max(1, Int((Double(milliseconds) / 60_000).rounded())))
    }

    /// "42 min left".
    static func left(_ minutes: Int) -> String {
        "\(duration(minutes: minutes)) left"
    }

    /// "1 hour 12 minutes left", for VoiceOver.
    static func spokenLeft(_ minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        var parts: [String] = []
        if hours > 0 { parts.append(hours == 1 ? "1 hour" : "\(hours) hours") }
        if rest > 0 { parts.append(rest == 1 ? "1 minute" : "\(rest) minutes") }
        return parts.joined(separator: " ") + " left"
    }

    /// An air date as the iPhone writes dates ("7 Mar 2024"), from Plex's "2024-03-07". Both sides stay in
    /// GMT, or the day would shift west of Greenwich.
    static func airDate(_ value: String?) -> String? {
        let parser = Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day().dateSeparator(.dash)
        guard let value, let date = try? parser.parse(value) else { return nil }
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: .gmt))
    }
}

extension PlexMedia {
    /// The format chips (DESIGN §8.3): 4K, then Dolby Vision or HDR, then Atmos.
    var formatChips: [String] {
        var chips: [String] = []
        if videoResolution?.lowercased() == "4k" { chips.append("4K") }
        if let range = dynamicRange { chips.append(range) }
        if hasAtmos { chips.append("Atmos") }
        return chips
    }

    /// "4K HDR · 12 GB", naming one version in the Version menu.
    var versionLabel: String {
        let resolution = videoResolution.map { value in
            value.lowercased() == "4k" ? "4K" : (Int(value) != nil ? "\(value)p" : value.uppercased())
        }
        let picture = [resolution, dynamicRange].compactMap(\.self).joined(separator: " ")
        let bytes = parts.compactMap(\.size).reduce(0, +)
        let size = bytes > 0 ? Int64(bytes).formatted(.byteCount(style: .file)) : nil
        let label = [picture.isEmpty ? nil : picture, size].compactMap(\.self).joined(separator: " · ")
        return label.isEmpty ? (container?.uppercased() ?? "Version") : label
    }

    private var dynamicRange: String? {
        let video = parts.first?.videoStream
        if video?.dolbyVision != nil { return "Dolby Vision" }
        if let transfer = video?.colorTrc, ["smpte2084", "arib-std-b67"].contains(transfer) { return "HDR" }
        return nil
    }

    private var hasAtmos: Bool {
        parts.flatMap(\.streams).contains { stream in
            stream.kind == .audio && [stream.displayTitle, stream.extendedDisplayTitle, stream.title].contains {
                $0?.localizedCaseInsensitiveContains("Atmos") == true
            }
        }
    }
}

extension PlexMetadata {
    /// The meta line under a title (DESIGN §8.3): "2019 · 2 h 14 m · PG-13"; for a show its seasons, for an
    /// episode its code and air date.
    var metaLine: String? {
        var parts: [String?] = []
        switch type {
        case .episode:
            parts = [episodeCode, ItemText.airDate(originallyAvailableAt), ItemText.runtime(duration), contentRating]
        case .show:
            let seasons = childCount.map { $0 == 1 ? "1 season" : "\($0) seasons" }
            parts = [year.map(String.init), seasons, contentRating]
        case .season:
            parts = [parentTitle, leafCount.map { $0 == 1 ? "1 episode" : "\($0) episodes" }]
        default:
            parts = [year.map(String.init), ItemText.runtime(duration), contentRating]
        }
        let line = parts.compactMap(\.self).filter { !$0.isEmpty }.joined(separator: " · ")
        return line.isEmpty ? nil : line
    }

    /// "Movie · 2019" under a search result (DESIGN §8.5).
    var kindLine: String {
        switch type {
        case .episode:
            return [grandparentTitle, episodeCode].compactMap(\.self).joined(separator: " · ")
        default:
            let kind = switch type {
            case .movie: "Movie"
            case .show: "Show"
            case .season: "Season"
            case .collection: "Collection"
            default: "Video"
            }
            return [kind, year.map(String.init)].compactMap(\.self).joined(separator: " · ")
        }
    }
}

extension SectionQuery.Sort {
    /// The name in the View menu.
    var title: String {
        switch self {
        case .title: "Title"
        case .recentlyAdded: "Recently Added"
        case .releaseDate: "Release Date"
        case .recentlyWatched: "Recently Watched"
        case .rating: "Rating"
        }
    }
}
