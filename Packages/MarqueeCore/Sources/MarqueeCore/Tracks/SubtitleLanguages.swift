import Foundation

/// The subtitle menu's languages (behaviour spec §3). The viewer's own languages sit on the menu and the
/// rest wait A to Z behind Other Languages, unless only one is left, which a submenu would only hide.
public struct SubtitleLanguages: Sendable, Equatable {
    /// One language's tracks, ranked Full, Captions, On-screen text, Commentary, in file order within a kind.
    public struct Group: Sendable, Equatable, Identifiable {
        /// The language's code; "und" holds the tracks that name none.
        public var id: String
        public var name: String
        public var tracks: [SubtitleTrack]
    }

    /// In the order the viewer's languages were given.
    public var yours: [Group]
    /// A to Z.
    public var other: [Group]

    /// - Parameter languages: The viewer's, most wanted first: the subtitle setting, the playing audio, the
    ///   phone's own languages.
    public init(_ tracks: [SubtitleTrack], yours languages: [TrackLanguage]) {
        var order: [String] = []
        var members: [String: [SubtitleTrack]] = [:]
        for track in tracks {
            let key = track.language.code ?? "und"
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(track)
        }
        let groups = order.map { key in
            let ranked = members[key, default: []].enumerated().sorted { a, b in
                a.element.kind == b.element.kind ? a.offset < b.offset : a.element.kind < b.element.kind
            }.map(\.element)
            return Group(id: key, name: ranked.first?.languageName ?? "Unknown", tracks: ranked)
        }
        let rank = Dictionary(languages.compactMap(\.code).enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        var yours = groups.filter { rank[$0.id] != nil }.sorted { rank[$0.id, default: 0] < rank[$1.id, default: 0] }
        var other = groups.filter { rank[$0.id] == nil }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if other.count == 1 {
            yours += other
            other = []
        }
        self.yours = yours
        self.other = other
    }
}
