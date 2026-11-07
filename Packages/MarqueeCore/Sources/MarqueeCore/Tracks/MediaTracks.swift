import Foundation

public enum TrackBadge: String, Sendable, Hashable, Codable {
    /// Subtitles for deaf and hard-of-hearing viewers (SDH, CC).
    case captions = "Captions"
    case audioDescription = "Audio description"
}

public struct AudioTrack: Sendable, Hashable, Identifiable {
    /// Plex stream id.
    public var id: Int
    public var language: TrackLanguage
    /// Display name of the language, e.g. "Japanese".
    public var languageName: String
    public var title: String?
    public var codec: String
    public var channels: Int?
    public var isCommentary: Bool
    public var isAudioDescription: Bool
    /// A dubbed version, by its title.
    public var isDub: Bool
    public var isDefault: Bool
    public var isSelectedOnServer: Bool
    /// The server has measured this track's loudness, which Boost dialog and Normalize loudness need.
    public var canNormalizeLoudness: Bool
    /// Menu text, e.g. "English", "English (commentary)", "Spanish (Latin America)".
    public var label: String
    public var badges: [TrackBadge]

    init(_ stream: PlexStream) {
        let words = TrackWords(stream)
        id = stream.id
        language = TrackLanguage(stream: stream)
        languageName = language.name ?? stream.language ?? "Unknown"
        title = stream.title
        codec = (stream.codec ?? "").lowercased()
        channels = stream.channels
        isCommentary = words.saysCommentary
        isAudioDescription = stream.isVisualImpaired || words.saysAudioDescription
        isDub = words.saysDub
        isDefault = stream.isDefault
        isSelectedOnServer = stream.isSelected
        canNormalizeLoudness = stream.canNormalizeLoudness
        label = ""
        badges = isAudioDescription ? [.audioDescription] : []
    }

    var channelName: String? {
        switch channels {
        case nil: nil
        case 1: "Mono"
        case 2: "Stereo"
        case 3: "2.1"
        case 6: "5.1"
        case 7: "6.1"
        case 8: "7.1"
        case let count?: "\(count) channels"
        }
    }
}

public struct SubtitleTrack: Sendable, Hashable, Identifiable {
    /// What the track holds. When several apply, the earlier case wins: a forced commentary is commentary.
    public enum Kind: Int, Sendable, Hashable, Codable, Comparable {
        /// The whole dialogue.
        case full
        /// The whole dialogue plus sound cues, for deaf and hard-of-hearing viewers.
        case captions
        /// Only signs, on-screen text and songs: forced subtitles and "Signs & Songs" tracks.
        case onScreenText
        case commentary

        public static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Plex stream id.
    public var id: Int
    public var language: TrackLanguage
    public var languageName: String
    public var title: String?
    public var kind: Kind
    /// A transcript of a dubbed audio track ("Dubtitles"), by its title.
    public var isDub: Bool
    /// A separate file next to the video rather than a track inside it.
    public var isExternal: Bool
    /// Closed captions (CEA-608/708) carried inside the video stream; they survive wherever the video is
    /// copied rather than re-encoded.
    public var isInVideoStream: Bool
    public var codec: String
    /// "PGS", "VOBSUB" or "DVB" for picture-based subtitles, which can only be drawn as images.
    public var imageFormat: String?
    public var isDefault: Bool
    public var isSelectedOnServer: Bool
    /// The separate file that stands in for this embedded track. Such a track is left out of menus.
    public var replacedBy: Int?
    /// Menu text, e.g. "English", "English (on-screen text)", "English (dub)".
    public var label: String
    public var badges: [TrackBadge]

    public var isImageBased: Bool { imageFormat != nil }
    public var isHidden: Bool { replacedBy != nil }

    init(_ stream: PlexStream) {
        let words = TrackWords(stream)
        id = stream.id
        language = TrackLanguage(stream: stream)
        languageName = language.name ?? stream.language ?? "Unknown"
        title = stream.title
        kind = if words.saysCommentary {
            .commentary
        } else if stream.isForced || words.saysOnScreenText {
            .onScreenText
        } else if stream.isHearingImpaired || stream.isEmbeddedInVideo || words.saysCaptions {
            .captions
        } else {
            .full
        }
        isDub = words.saysDub
        isExternal = stream.isExternal
        isInVideoStream = stream.isEmbeddedInVideo
        codec = (stream.codec ?? stream.format ?? "").lowercased()
        imageFormat = Self.imageFormats[codec]
        isDefault = stream.isDefault
        isSelectedOnServer = stream.isSelected
        replacedBy = nil
        label = ""
        badges = kind == .captions ? [.captions] : []
    }

    /// Two tracks that say the same thing: same language, region and script, kind and dub-ness.
    /// Commentary, dub transcripts and on-screen text never stand in for a full track because the kind
    /// and dub flag must match.
    func isTwin(of other: SubtitleTrack) -> Bool {
        language == other.language && language.isKnown && kind == other.kind && isDub == other.isDub
    }

    private static let imageFormats = [
        "pgs": "PGS", "hdmv_pgs_subtitle": "PGS",
        "vobsub": "VOBSUB", "dvd_subtitle": "VOBSUB", "dvdsub": "VOBSUB",
        "dvb_subtitle": "DVB", "dvbsub": "DVB",
    ]
}

/// The audio and subtitle tracks of one part, labelled for menus.
public struct MediaTracks: Sendable, Hashable {
    /// In file order.
    public var audio: [AudioTrack]
    /// In file order, separate files last, including embedded tracks hidden by a separate twin.
    public var subtitles: [SubtitleTrack]

    public init(part: PlexPart) {
        self.init(streams: part.streams)
    }

    public init(streams: [PlexStream]) {
        audio = streams.filter { $0.kind == .audio }.map(AudioTrack.init)
        let all = streams.filter { $0.kind == .subtitle }.map(SubtitleTrack.init)
        var subtitles = all.filter { !$0.isExternal } + all.filter(\.isExternal)
        for index in subtitles.indices where !subtitles[index].isExternal {
            subtitles[index].replacedBy = subtitles.first { $0.isExternal && $0.isTwin(of: subtitles[index]) }?.id
        }
        self.subtitles = subtitles
        Labeler.label(&self.audio)
        Labeler.label(&self.subtitles)
    }

    /// The subtitles a menu offers.
    public var visibleSubtitles: [SubtitleTrack] { subtitles.filter { !$0.isHidden } }

    public func audioTrack(id: Int) -> AudioTrack? { audio.first { $0.id == id } }

    public func subtitle(id: Int) -> SubtitleTrack? { subtitles.first { $0.id == id } }

    /// The track a menu shows for `track`: its separate twin when it is hidden.
    public func visible(_ track: SubtitleTrack) -> SubtitleTrack {
        track.replacedBy.flatMap(subtitle(id:)) ?? track
    }
}

/// Gives each track a plain name and keeps names in one menu apart: first by region or script, then (for
/// audio) by channel layout, then by track number.
private enum Labeler {
    static func label(_ tracks: inout [AudioTrack]) {
        var names = tracks.map { Name(language: $0.languageName, variant: nil, qualifier: $0.isCommentary ? "commentary" : nil) }
        separate(&names, badges: tracks.map(\.badges)) { index, name in
            name.variant = tracks[index].language.variantName
        }
        separate(&names, badges: tracks.map(\.badges)) { index, name in
            name.detail = tracks[index].channelName
        }
        numberDuplicates(&names, badges: tracks.map(\.badges))
        for index in tracks.indices { tracks[index].label = names[index].text }
    }

    static func label(_ tracks: inout [SubtitleTrack]) {
        let visible = tracks.indices.filter { !tracks[$0].isHidden }
        var names = visible.map { Name(language: tracks[$0].languageName, variant: nil, qualifier: qualifier(tracks[$0])) }
        let badges = visible.map { tracks[$0].badges }
        separate(&names, badges: badges) { position, name in
            name.variant = tracks[visible[position]].language.variantName
        }
        numberDuplicates(&names, badges: badges)
        for (position, index) in visible.enumerated() { tracks[index].label = names[position].text }
        for index in tracks.indices where tracks[index].isHidden {
            tracks[index].label = tracks.first { $0.id == tracks[index].replacedBy }?.label ?? tracks[index].languageName
        }
    }

    private static func qualifier(_ track: SubtitleTrack) -> String? {
        switch track.kind {
        case .commentary: "commentary"
        case .onScreenText: "on-screen text"
        case .full, .captions: track.isDub ? "dub" : nil
        }
    }

    private struct Name: Hashable {
        var language: String
        var variant: String?
        var qualifier: String?
        var detail: String?
        var number: Int?

        var text: String {
            let inside = [variant, qualifier].compactMap { $0 }.joined(separator: ", ")
            var text = inside.isEmpty ? language : "\(language) (\(inside))"
            let suffix = [detail, number.map { "Track \($0)" }].compactMap { $0 }.joined(separator: ", ")
            if !suffix.isEmpty { text += " – \(suffix)" }
            return text
        }
    }

    /// Applies `refine` to every name that, with its badges, is shared by another track.
    private static func separate(_ names: inout [Name], badges: [[TrackBadge]], refine: (Int, inout Name) -> Void) {
        let clashing = clashes(names, badges: badges)
        for index in names.indices where clashing.contains(index) { refine(index, &names[index]) }
    }

    private static func numberDuplicates(_ names: inout [Name], badges: [[TrackBadge]]) {
        let clashing = clashes(names, badges: badges)
        for index in names.indices where clashing.contains(index) { names[index].number = index + 1 }
    }

    private static func clashes(_ names: [Name], badges: [[TrackBadge]]) -> Set<Int> {
        var groups: [String: [Int]] = [:]
        for index in names.indices {
            groups[names[index].text + "|" + badges[index].map(\.rawValue).joined(separator: ","), default: []].append(index)
        }
        return Set(groups.values.filter { $0.count > 1 }.joined())
    }
}
