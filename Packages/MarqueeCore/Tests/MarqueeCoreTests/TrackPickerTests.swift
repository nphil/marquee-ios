import Foundation
import Testing
@testable import MarqueeCore

struct TrackPickerTests {
    /// A typical anime release: Japanese audio and an English dub; inside the file a "Signs / Songs" track
    /// and a "Dialogue" track as pictures; next to it `.en.srt` (the translation) and `.en.cc.srt` (the
    /// dub transcript with sound cues).
    static func anime(serverSelected: Int? = nil) throws -> MediaTracks {
        try Fixture.tracks([
            Fixture.audio(1, "jpn", codec: "flac", isDefault: true),
            Fixture.audio(2, "eng", title: "English Dub", codec: "eac3", channels: 6),
            Fixture.subtitle(10, "eng", title: "Signs / Songs", codec: "pgs", selected: serverSelected == 10),
            Fixture.subtitle(11, "eng", title: "Dialogue", codec: "pgs", selected: serverSelected == 11),
            Fixture.subtitle(12, "eng", external: true, selected: serverSelected == 12),
            Fixture.subtitle(13, "eng", external: true, hearingImpaired: true, selected: serverSelected == 13),
        ])
    }

    static let japanese = 1, englishDub = 2, signs = 10, dialogue = 11, translation = 12, transcript = 13

    func decide(
        _ tracks: MediaTracks,
        audio: Int,
        handPick: SubtitleChoice? = nil,
        remembered: RememberedSubtitle? = nil,
        settings: SubtitleSettings = SubtitleSettings(),
        canDraw: Bool = false
    ) -> SubtitleDecision {
        SubtitlePicker.decide(
            tracks: tracks, audio: tracks.audioTrack(id: audio), handPick: handPick, remembered: remembered,
            settings: settings, canDrawImageSubtitles: canDraw
        )
    }

    // MARK: Anime release

    @Test func builtInDialogueIsReplacedByTheTranslationFile() throws {
        let tracks = try Self.anime()

        #expect(tracks.visibleSubtitles.map(\.id) == [Self.signs, Self.translation, Self.transcript])
        #expect(tracks.subtitle(id: Self.dialogue)?.replacedBy == Self.translation)
        #expect(tracks.subtitle(id: Self.transcript)?.badges == [.captions])
    }

    @Test func originalAudioGetsTheTranslation() throws {
        let decision = decide(try Self.anime(serverSelected: Self.dialogue), audio: Self.japanese)

        #expect(decision.track?.id == Self.translation)
        #expect(decision.source == .server && !decision.followedAudio)
    }

    @Test func dubAudioGetsTheDubTranscript() throws {
        let decision = decide(try Self.anime(serverSelected: Self.dialogue), audio: Self.englishDub)

        #expect(decision.track?.id == Self.transcript)
        #expect(decision.source == .server && decision.followedAudio)
    }

    @Test func alwaysOnSettingFollowsTheAudioToo() throws {
        let always = SubtitleSettings(defaultMode: .always)

        #expect(decide(try Self.anime(), audio: Self.japanese, settings: always).track?.id == Self.translation)
        #expect(decide(try Self.anime(), audio: Self.englishDub, settings: always).track?.id == Self.transcript)
        #expect(decide(try Self.anime(), audio: Self.englishDub).track == nil)
    }

    @Test func onScreenTextOnlyShowsSignsForTheAudioLanguage() throws {
        let tracks = try Self.anime()

        let dub = decide(tracks, audio: Self.englishDub, handPick: .onScreenTextOnly)
        let original = decide(tracks, audio: Self.japanese, handPick: .onScreenTextOnly)

        #expect(dub.track?.id == Self.signs && dub.isOnScreenTextOnly)
        #expect(original.track == nil && original.isOnScreenTextOnly)
    }

    @Test func handPickIsNotMovedToSuitTheAudio() throws {
        let decision = decide(try Self.anime(), audio: Self.englishDub, handPick: .track(Self.translation))

        #expect(decision.track?.id == Self.translation)
        #expect(decision.source == .handPick && !decision.followedAudio)
    }

    // MARK: Order

    @Test func automaticPicksSkipTracksTheAppCannotDraw() throws {
        let tracks = try Fixture.tracks([
            Fixture.audio(1, "fra"),
            Fixture.subtitle(2, "eng", codec: "pgs", isDefault: true, selected: true),
            Fixture.subtitle(3, "eng", title: "SDH", codec: "srt", hearingImpaired: true),
        ])

        #expect(decide(tracks, audio: 1, canDraw: true).source == .server)
        let fallback = decide(tracks, audio: 1)
        #expect(fallback.source == .setting && fallback.track?.id == 3)
    }

    @Test func usualSubtitlesAreFullTextBeforeCaptionsAndPictures() throws {
        let tracks = try Fixture.tracks([
            Fixture.audio(1, "eng"),
            Fixture.subtitle(2, "eng", title: "Forced", forced: true),
            Fixture.subtitle(3, "eng", hearingImpaired: true),
            Fixture.subtitle(4, "eng", codec: "pgs"),
            Fixture.subtitle(5, "eng"),
            Fixture.subtitle(6, "fre"),
        ])

        #expect(SubtitlePicker.usual(in: .english, from: tracks)?.id == 5)
        #expect(SubtitlePicker.usual(in: .english, from: tracks) { $0.id != 5 }?.id == 4)
        #expect(SubtitlePicker.usual(in: .english, from: tracks) { $0.id == 2 } == nil)
    }

    @Test func rememberedOffAndOnScreenTextStand() throws {
        let tracks = try Fixture.tracks([
            Fixture.audio(1, "eng"),
            Fixture.subtitle(2, "eng", title: "Forced", forced: true),
            Fixture.subtitle(3, "eng", isDefault: true),
        ])

        let off = decide(tracks, audio: 1, remembered: .off)
        let signs = decide(tracks, audio: 1, remembered: .onScreenTextOnly)

        #expect(off.track == nil && off.source == .remembered)
        #expect(signs.track?.id == 2 && signs.source == .remembered)
        #expect(decide(tracks, audio: 1).source == .fileDefault)
    }

    @Test func rememberedFileIsMatchedByAFileInTheNextEpisode() throws {
        let first = try Self.anime()
        let remembered = try #require(RememberedSubtitle(.track(Self.transcript), in: first))
        let next = try Fixture.tracks([
            Fixture.audio(1, "jpn"),
            Fixture.subtitle(20, "eng", title: "SDH", hearingImpaired: true),
            Fixture.subtitle(21, "eng", external: true),
            Fixture.subtitle(22, "eng", title: "SDH", external: true, hearingImpaired: true),
        ])
        let builtInOnly = try Fixture.tracks([
            Fixture.audio(1, "jpn"),
            Fixture.subtitle(30, "eng", title: "Forced", forced: true),
            Fixture.subtitle(31, "eng", title: "SDH", hearingImpaired: true),
        ])
        let otherLanguage = try Fixture.tracks([
            Fixture.audio(1, "jpn"),
            Fixture.subtitle(40, "spa", isDefault: true),
        ])

        #expect(decide(next, audio: 1, remembered: remembered).track?.id == 22)
        #expect(decide(builtInOnly, audio: 1, remembered: remembered).track?.id == 31)
        let stepsAside = decide(otherLanguage, audio: 1, remembered: remembered)
        #expect(stepsAside.track?.id == 40 && stepsAside.source == .fileDefault)
    }

    @Test func rememberedHiddenTrackIsStoredAsTheFileThatReplacedIt() throws {
        let tracks = try Self.anime()

        let remembered = RememberedSubtitle(.track(Self.dialogue), in: tracks)

        guard case .track(let description)? = remembered else {
            Issue.record("nothing remembered")
            return
        }
        #expect(description.wasExternal && description.kind == .full)
    }

    // MARK: Audio

    @Test func audioMemoryKeepsLanguageAndCommentaryStrict() throws {
        let watched = try Fixture.tracks([Fixture.audio(1, "eng", codec: "eac3", channels: 6)])
        let remembered = RememberedAudio(watched.audio[0])
        let next = try Fixture.tracks([
            Fixture.audio(5, "eng", title: "Commentary", codec: "eac3", channels: 6),
            Fixture.audio(6, "eng", codec: "ac3", channels: 6),
            Fixture.audio(7, "eng", codec: "eac3", channels: 2),
            Fixture.audio(8, "jpn", codec: "eac3", channels: 6),
        ])
        let japaneseOnly = try Fixture.tracks([Fixture.audio(9, "jpn", codec: "eac3", channels: 6, selected: true)])

        #expect(remembered.match(in: next.audio)?.id == 7)
        #expect(remembered.match(in: japaneseOnly.audio) == nil)
        #expect(AudioPicker.pick(in: japaneseOnly, remembered: remembered)?.id == 9)
    }

    @Test func audioPickOrder() throws {
        let tracks = try Fixture.tracks([
            Fixture.audio(1, "eng", title: "Commentary"),
            Fixture.audio(2, "jpn", isDefault: true),
            Fixture.audio(3, "eng"),
            Fixture.audio(4, "fra"),
        ])
        let selected = try Fixture.tracks([Fixture.audio(1, "eng"), Fixture.audio(2, "fra", selected: true)])

        #expect(AudioPicker.pick(in: tracks, handPick: 4, preferredLanguage: .english)?.id == 4)
        #expect(AudioPicker.pick(in: tracks, preferredLanguage: .english)?.id == 3)
        #expect(AudioPicker.pick(in: tracks)?.id == 2)
        #expect(AudioPicker.pick(in: selected, preferredLanguage: .english)?.id == 2)
    }
}
