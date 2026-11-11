import Foundation

/// The subtitle menu's languages (behaviour spec §3). Every track sits on the menu while they are few. In
/// a longer list the viewer's own languages and that of the subtitle showing stay there, and the rest wait
/// A to Z behind Other Languages, unless only one is left, which a submenu would only hide.
public struct SubtitleLanguages: Sendable, Equatable {
    /// One language's tracks, ranked Full, Captions, On-screen text, Commentary, in file order within a kind.
    public struct Group: Sendable, Equatable, Identifiable {
        /// The language's code; "und" holds the tracks that name none.
        public var id: String
        public var name: String
        public var tracks: [SubtitleTrack]
    }

    /// In the order the viewer's languages were given, then the language showing, then any that had room.
    public var yours: [Group]
    /// A to Z.
    public var other: [Group]

    /// - Parameters:
    ///   - languages: The viewer's, most wanted first: the subtitle setting, the playing audio, the
    ///     phone's own languages.
    ///   - showing: The subtitle on screen, so the menu's own list always holds the check.
    ///   - room: The most tracks the menu lists whole.
    public init(_ tracks: [SubtitleTrack], yours languages: [TrackLanguage], showing: SubtitleTrack? = nil, room: Int = 0) {
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
        if let showing, let index = other.firstIndex(where: { $0.id == showing.language.code ?? "und" }) {
            yours.append(other.remove(at: index))
        }
        if other.count == 1 || tracks.count <= room {
            yours += other
            other = []
        }
        self.yours = yours
        self.other = other
    }
}
