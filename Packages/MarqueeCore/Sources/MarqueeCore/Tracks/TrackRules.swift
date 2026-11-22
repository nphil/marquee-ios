import Foundation

/// A subtitle choice made in the player's menu.
public enum SubtitleChoice: Sendable, Hashable, Codable {
    case off
    /// On: what `TrackRules` picks, forgetting any track picked earlier for the show or movie.
    case automatic
    /// A Plex stream id.
    case track(Int)
}

public struct SubtitleDecision: Sendable, Hashable {
    public enum Source: Sendable, Hashable {
        /// Picked in the menu for this playback.
        case handPick
        /// Remembered for the show or movie.
        case remembered
        /// Decided by `TrackRules`. No track means the file has no English text to show.
        case rules
    }

    /// Nil shows no subtitles.
    public var track: SubtitleTrack?
    public var source: Source

    public init(track: SubtitleTrack?, source: Source) {
        self.track = track
        self.source = source
    }
}

/// What the viewer said about a show or movie being anime, ahead of what Plex's tags say.
public enum AnimeOverride: String, Sendable, Hashable, Codable, CaseIterable {
    case automatic, anime, notAnime

    /// Whether the title counts as anime, given what its tags said (`Anime.matches`).
    public func resolve(_ tagged: Bool) -> Bool {
        switch self {
        case .automatic: tagged
        case .anime: true
        case .notAnime: false
        }
    }
}

/// The audio and subtitle that play, by one set of rules for every profile and both apps.
///
/// - Movies and TV that is not anime play the original audio, never a dub, with the English subtitle: the
///   `.en` file, else the `.en.cc` file, else English text inside the video. The original language is the one
///   of the first production country that has a track (`OriginalLanguage`); with none, it is the file's
///   default track.
/// - Anime plays the English dub when the file has one, else the original audio, with the English
///   subtitle written for that audio: the dub script (`.en.cc`) with English audio, the translation
///   (`.en`) with any other. A file beside the video comes before text inside it.
/// - Subtitles are on, unless the viewer turned them off for the show or movie.
/// - A track the viewer picked, now or earlier for the show or movie, stands. The audio never moves it.
/// - A picture subtitle (PGS, VobSub) is never picked by the rules, since only the server can draw it.
public enum TrackRules {
    /// What the viewer settled, which the rules do not overrule.
    public struct Choices: Sendable, Hashable {
        /// An audio stream picked in the player.
        public var audio: Int?
        /// A subtitle choice made in the player.
        public var subtitle: SubtitleChoice?
        /// What earlier plays of the show or movie remembered.
        public var memory: TrackMemory?

        public init(audio: Int? = nil, subtitle: SubtitleChoice? = nil, memory: TrackMemory? = nil) {
            self.audio = audio
            self.subtitle = subtitle
            self.memory = memory
        }
    }

    public struct Pick: Sendable, Hashable {
        public var audio: AudioTrack?
        public var subtitle: SubtitleDecision
        /// Whether the pick took the title as anime, after the viewer's override.
        public var isAnime: Bool
    }

    /// - Parameters:
    ///   - isAnime: What Plex's tags say (`Anime.matches`); the viewer's override in `choices.memory` comes before it.
    ///   - countries: The production countries Plex lists for the title, or for an episode's show, which say the
    ///     original language of a title that is not anime.
    public static func pick(
        from tracks: MediaTracks, isAnime tagged: Bool, countries: [String] = [], choices: Choices = Choices()
    ) -> Pick {
        let isAnime = (choices.memory?.anime ?? .automatic).resolve(tagged)
        let audio = pickAudio(in: tracks, isAnime: isAnime, countries: countries, choices: choices)
        let subtitle = pickSubtitle(in: tracks, audio: audio, isAnime: isAnime, choices: choices)
        return Pick(audio: audio, subtitle: subtitle, isAnime: isAnime)
    }

    /// The English subtitle the rules put on screen with `audio`; nil when the file has no English text,
    /// which leaves the subtitles off. Text inside the video counts only when no separate file has English.
    public static func automaticSubtitle(in tracks: MediaTracks, audio: AudioTrack?, isAnime: Bool) -> SubtitleTrack? {
        let english = tracks.visibleSubtitles.filter {
            $0.language.matches(.english) && !$0.isImageBased && $0.kind != .commentary
        }
        guard isAnime else {
            // Signs and songs alone and a dub script come last. Then a separate file before text inside the
            // video, and dialogue before captions for the deaf: `.en`, else `.en.cc`, else the video's own.
            return english.closest { [$0.kind == .onScreenText, $0.isDub, !$0.isExternal, $0.kind != .full] }
        }
        // Signs and songs alone come last. Then a separate file before text inside the video, and the one
        // written for the audio playing.
        let wantsDubScript = audio?.language.matches(.english) ?? false
        return english.closest { [$0.kind == .onScreenText, !$0.isExternal, $0.isDubScript != wantsDubScript] }
    }

    private static func pickAudio(in tracks: MediaTracks, isAnime: Bool, countries: [String], choices: Choices) -> AudioTrack? {
        if let id = choices.audio, let track = tracks.audioTrack(id: id) { return track }
        if let track = choices.memory?.audio?.match(in: tracks.audio) { return track }
        let main = tracks.audio.filter { !$0.isCommentary && !$0.isAudioDescription }
        if isAnime, let english = main.first(where: { $0.language.matches(.english) }) { return english }
        // A dub is left out unless the file has only dubs.
        let original = main.filter { !$0.isDub }
        let pool = original.isEmpty ? main : original
        // A file's default track is often a dub that is not labelled one, so the country says which is the original.
        if !isAnime, let track = OriginalLanguage.firstMatch(among: pool, countries: countries) { return track }
        return pool.first(where: \.isDefault) ?? pool.first ?? tracks.audio.first(where: \.isDefault) ?? tracks.audio.first
    }

    private static func pickSubtitle(in tracks: MediaTracks, audio: AudioTrack?, isAnime: Bool, choices: Choices) -> SubtitleDecision {
        switch choices.subtitle {
        case .off?:
            return SubtitleDecision(track: nil, source: .handPick)
        case .track(let id)?:
            if let track = tracks.subtitle(id: id) { return SubtitleDecision(track: tracks.visible(track), source: .handPick) }
        case .automatic?:
            return rulesSubtitle(in: tracks, audio: audio, isAnime: isAnime)
        case nil:
            break
        }
        switch choices.memory?.subtitle {
        case .off?:
            return SubtitleDecision(track: nil, source: .remembered)
        case .track(let description)?:
            if let track = description.match(in: tracks.visibleSubtitles) { return SubtitleDecision(track: track, source: .remembered) }
        case nil:
            break
        }
        return rulesSubtitle(in: tracks, audio: audio, isAnime: isAnime)
    }

    private static func rulesSubtitle(in tracks: MediaTracks, audio: AudioTrack?, isAnime: Bool) -> SubtitleDecision {
        SubtitleDecision(track: automaticSubtitle(in: tracks, audio: audio, isAnime: isAnime), source: .rules)
    }
}

private extension SubtitleTrack {
    /// Written for the English dub: a dub-named track, or captions, which also carry the dub's sounds.
    var isDubScript: Bool { isDub || kind == .captions }
}
