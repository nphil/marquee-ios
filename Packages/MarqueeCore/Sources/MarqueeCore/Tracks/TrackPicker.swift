import Foundation

/// A subtitle choice made in the menu.
public enum SubtitleChoice: Sendable, Hashable, Codable {
    case off
    /// Only signs and on-screen text, in the language of the playing audio.
    case onScreenTextOnly
    /// A Plex stream id.
    case track(Int)
}

/// What subtitles show when nothing was picked or remembered.
public enum SubtitleDefault: String, Sendable, Hashable, Codable, CaseIterable {
    case off
    /// Subtitles in the preferred language when the audio is in another language.
    case foreignAudio
    case always
    case onScreenTextOnly
}

public struct SubtitleSettings: Sendable, Hashable, Codable {
    public var language: TrackLanguage
    public var defaultMode: SubtitleDefault
    /// Automatic picks move to the version that suits the playing audio: the dub transcript for audio in
    /// `language`, the full translation for any other audio.
    public var followsAudio: Bool

    public init(language: TrackLanguage = .english, defaultMode: SubtitleDefault = .foreignAudio, followsAudio: Bool = true) {
        self.language = language
        self.defaultMode = defaultMode
        self.followsAudio = followsAudio
    }
}

public struct SubtitleDecision: Sendable, Hashable {
    public enum Source: Sendable, Hashable {
        /// Picked in the menu for this playback.
        case handPick
        /// Remembered for the show or movie.
        case remembered
        /// Selected on the server for this user.
        case server
        /// Marked default in the file.
        case fileDefault
        /// Chosen by `SubtitleSettings.defaultMode`.
        case setting
    }

    /// Nil shows no subtitles.
    public var track: SubtitleTrack?
    public var source: Source
    /// On-screen-text-only mode: `track` is the on-screen text for the playing audio, if there is one.
    public var isOnScreenTextOnly: Bool
    /// The track was moved from the automatic pick to suit the playing audio.
    public var followedAudio: Bool

    public init(track: SubtitleTrack?, source: Source, isOnScreenTextOnly: Bool = false, followedAudio: Bool = false) {
        self.track = track
        self.source = source
        self.isOnScreenTextOnly = isOnScreenTextOnly
        self.followedAudio = followedAudio
    }
}

public enum SubtitlePicker {
    /// The subtitle to show with `audio`, in this order: a hand pick; the server's selection; the
    /// remembered choice (a remembered Off or on-screen-text-only stands even when nothing else would);
    /// the file's default track; `settings.defaultMode`. Automatic picks (server, file default, setting)
    /// take only tracks the app can draw, since they never cause a server re-encode, and follow the
    /// audio; hand picks and remembered picks are kept as chosen.
    ///
    /// - Parameter canDrawImageSubtitles: The current route can show picture-based subtitles (PGS, VobSub)
    ///   without a server re-encode.
    public static func decide(
        tracks: MediaTracks,
        audio: AudioTrack?,
        handPick: SubtitleChoice? = nil,
        remembered: RememberedSubtitle? = nil,
        settings: SubtitleSettings = SubtitleSettings(),
        canDrawImageSubtitles: Bool
    ) -> SubtitleDecision {
        switch handPick {
        case .off?:
            return SubtitleDecision(track: nil, source: .handPick)
        case .onScreenTextOnly?:
            return SubtitleDecision(track: onScreenText(for: audio, in: tracks), source: .handPick, isOnScreenTextOnly: true)
        case .track(let id)?:
            if let track = tracks.subtitle(id: id) { return SubtitleDecision(track: tracks.visible(track), source: .handPick) }
        case nil:
            break
        }

        let drawable = { (track: SubtitleTrack) in !track.isImageBased || canDrawImageSubtitles }

        if let selected = tracks.subtitles.first(where: \.isSelectedOnServer).map(tracks.visible), drawable(selected) {
            return automatic(selected, source: .server, audio: audio, tracks: tracks, settings: settings, drawable: drawable)
        }

        switch remembered {
        case .off?:
            return SubtitleDecision(track: nil, source: .remembered)
        case .onScreenTextOnly?:
            return SubtitleDecision(track: onScreenText(for: audio, in: tracks), source: .remembered, isOnScreenTextOnly: true)
        case .track(let description)?:
            if let track = description.match(in: tracks.visibleSubtitles) { return SubtitleDecision(track: track, source: .remembered) }
        case nil:
            break
        }

        if let fileDefault = tracks.subtitles.first(where: \.isDefault).map(tracks.visible), drawable(fileDefault) {
            return automatic(fileDefault, source: .fileDefault, audio: audio, tracks: tracks, settings: settings, drawable: drawable)
        }

        switch settings.defaultMode {
        case .off:
            return SubtitleDecision(track: nil, source: .setting)
        case .onScreenTextOnly:
            return SubtitleDecision(track: onScreenText(for: audio, in: tracks), source: .setting, isOnScreenTextOnly: true)
        case .foreignAudio, .always:
            let audioIsForeign = audio.map { $0.language.isKnown && !$0.language.matches(settings.language) } ?? false
            guard settings.defaultMode == .always || audioIsForeign,
                  let best = tracks.visibleSubtitles
                      .filter({ drawable($0) && $0.language.matches(settings.language) && ($0.kind == .full || $0.kind == .captions) })
                      .closest(misses: { [$0.kind != .full, $0.isDub, !$0.isExternal] })
            else { return SubtitleDecision(track: nil, source: .setting) }
            return automatic(best, source: .setting, audio: audio, tracks: tracks, settings: settings, drawable: drawable)
        }
    }

    /// The on-screen text track for the playing audio's language, a separate file first; nil when the
    /// language has none.
    public static func onScreenText(for audio: AudioTrack?, in tracks: MediaTracks) -> SubtitleTrack? {
        guard let audio, audio.language.isKnown else { return nil }
        return tracks.visibleSubtitles
            .filter { $0.kind == .onScreenText && $0.language.matches(audio.language) }
            .closest { [!$0.isExternal] }
    }

    private static func automatic(
        _ base: SubtitleTrack,
        source: SubtitleDecision.Source,
        audio: AudioTrack?,
        tracks: MediaTracks,
        settings: SubtitleSettings,
        drawable: (SubtitleTrack) -> Bool
    ) -> SubtitleDecision {
        let track = follow(base, audio: audio, tracks: tracks, settings: settings, drawable: drawable)
        return SubtitleDecision(track: track, source: source, followedAudio: track.id != base.id)
    }

    /// Moves a full or captions track in the preferred language to the version that suits the audio:
    /// for audio in that language the dub transcript (a dub-named or captions track), for other audio the
    /// full translation. Separate files win over embedded tracks. Other tracks, and audio in an unknown
    /// language, keep the base.
    private static func follow(
        _ base: SubtitleTrack,
        audio: AudioTrack?,
        tracks: MediaTracks,
        settings: SubtitleSettings,
        drawable: (SubtitleTrack) -> Bool
    ) -> SubtitleTrack {
        guard settings.followsAudio, let audio, audio.language.isKnown,
              base.kind == .full || base.kind == .captions, base.language.matches(settings.language)
        else { return base }
        let wantsTranscript = audio.language.matches(settings.language)
        return tracks.visibleSubtitles
            .filter { track in
                guard drawable(track), track.language.matches(settings.language) else { return false }
                return wantsTranscript ? (track.isDub || track.kind == .captions) : (track.kind == .full && !track.isDub)
            }
            .closest { [!$0.isExternal, !$0.isDub] } ?? base
    }
}

public enum AudioPicker {
    /// The audio to play: a hand pick; the remembered choice for the show; the server's selection; the
    /// first main track in `preferredLanguage`; the file default; the first main track.
    public static func pick(
        in tracks: MediaTracks,
        handPick: Int? = nil,
        remembered: RememberedAudio? = nil,
        preferredLanguage: TrackLanguage? = nil
    ) -> AudioTrack? {
        if let handPick, let track = tracks.audioTrack(id: handPick) { return track }
        if let remembered, let track = remembered.match(in: tracks.audio) { return track }
        if let track = tracks.audio.first(where: \.isSelectedOnServer) { return track }
        let main = tracks.audio.filter { !$0.isCommentary && !$0.isAudioDescription }
        if let preferredLanguage, let track = main.first(where: { $0.language.matches(preferredLanguage) }) { return track }
        return tracks.audio.first(where: \.isDefault) ?? main.first ?? tracks.audio.first
    }
}
