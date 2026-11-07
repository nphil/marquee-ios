import Foundation

/// The audio and subtitle choice remembered for a show or movie. It describes the tracks rather than
/// naming them, because stream ids differ in every episode.
public struct TrackMemory: Sendable, Hashable, Codable {
    public var audio: RememberedAudio?
    public var subtitle: RememberedSubtitle?

    public init(audio: RememberedAudio? = nil, subtitle: RememberedSubtitle? = nil) {
        self.audio = audio
        self.subtitle = subtitle
    }

    /// Where the memory of one show or movie is kept: per server and Plex Home profile.
    public static func storageKey(server: String, profile: String, item: PlexMetadata) -> String {
        "tracks.\(server).\(profile).\(item.showRatingKey ?? item.ratingKey)"
    }
}

public struct RememberedAudio: Sendable, Hashable, Codable {
    public var language: TrackLanguage
    public var isCommentary: Bool
    public var isAudioDescription: Bool
    public var codec: String
    public var channels: Int?
    public var title: String?
    public var wasDefault: Bool

    public init(_ track: AudioTrack) {
        language = track.language
        isCommentary = track.isCommentary
        isAudioDescription = track.isAudioDescription
        codec = track.codec
        channels = track.channels
        title = track.title
        wasDefault = track.isDefault
    }

    /// The track in another episode that matches. Language, commentary and audio description must
    /// match; codec, channels, region, title and the default flag only break ties, in that order.
    public func match(in tracks: [AudioTrack]) -> AudioTrack? {
        tracks
            .filter { $0.language.code == language.code && $0.isCommentary == isCommentary && $0.isAudioDescription == isAudioDescription }
            .closest { [$0.codec != codec, $0.channels != channels, $0.language != language, $0.title != title, $0.isDefault != wasDefault] }
    }
}

public enum RememberedSubtitle: Sendable, Hashable, Codable {
    case off
    case onScreenTextOnly
    case track(Description)

    public struct Description: Sendable, Hashable, Codable {
        public var language: TrackLanguage
        public var kind: SubtitleTrack.Kind
        public var isDub: Bool
        public var wasExternal: Bool

        public init(_ track: SubtitleTrack) {
            language = track.language
            kind = track.kind
            isDub = track.isDub
            wasExternal = track.isExternal
        }

        /// The track in another episode that matches: the same language, on-screen-text-ness and
        /// commentary-ness are required. A separate file is matched by another separate file before an
        /// embedded track; then the same kind, dub-ness and region win.
        public func match(in tracks: [SubtitleTrack]) -> SubtitleTrack? {
            tracks
                .filter {
                    $0.language.matches(language)
                        && ($0.kind == .onScreenText) == (kind == .onScreenText)
                        && ($0.kind == .commentary) == (kind == .commentary)
                }
                .closest { [$0.isExternal != wasExternal, $0.kind != kind, $0.isDub != isDub, $0.language != language] }
        }
    }

    /// What to remember after a hand pick.
    public init?(_ choice: SubtitleChoice, in tracks: MediaTracks) {
        switch choice {
        case .off: self = .off
        case .onScreenTextOnly: self = .onScreenTextOnly
        case .track(let id):
            guard let track = tracks.subtitle(id: id) else { return nil }
            self = .track(Description(tracks.visible(track)))
        }
    }
}

extension Array {
    /// The element that misses the fewest of the leading criteria: a miss on an earlier criterion
    /// outweighs any number of later ones. Ties go to the earlier element.
    func closest(misses: (Element) -> [Bool]) -> Element? {
        enumerated()
            .map { (rank: misses($0.element).map { $0 ? 1 : 0 } + [$0.offset], element: $0.element) }
            .min { $0.rank.lexicographicallyPrecedes($1.rank) }?
            .element
    }
}
