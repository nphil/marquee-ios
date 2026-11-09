import Foundation
import Testing
@testable import MarqueeCore

/// The subtitle that follows the audio: English audio takes the dub transcript, other audio the full
/// translation, a downloaded track over a built-in one.
struct SubtitleFollowTests {
    func decide(
        _ tracks: MediaTracks,
        audio: Int,
        remembered: RememberedSubtitle? = nil,
        handPick: SubtitleChoice? = nil,
        settings: SubtitleSettings = SubtitleSettings()
    ) -> SubtitleDecision {
        SubtitlePicker.decide(
            tracks: tracks, audio: tracks.audioTrack(id: audio), handPick: handPick, remembered: remembered,
            settings: settings, canDrawImageSubtitles: false
        )
    }

    /// English and Japanese audio; built-in full and SDH tracks, with the server holding the full one.
    func builtIn(extra: [[String: Any]] = []) throws -> MediaTracks {
        try Fixture.tracks([
            Fixture.audio(1, "eng"),
            Fixture.audio(2, "jpn"),
            Fixture.subtitle(10, "eng", selected: true),
            Fixture.subtitle(11, "eng", title: "SDH", hearingImpaired: true),
        ] + extra)
    }

    @Test func englishAudioTakesTheDubTranscriptAndOtherAudioTheFullTranslation() throws {
        let tracks = try builtIn()

        let english = decide(tracks, audio: 1)
        let japanese = decide(tracks, audio: 2)

        #expect(english.track?.id == 11 && english.followedAudio)
        #expect(japanese.track?.id == 10 && !japanese.followedAudio)
    }

    @Test func aTranscriptIsAFlagAnSdhOrCcTitleOrADubTitle() throws {
        for transcript in [
            Fixture.subtitle(20, "eng", hearingImpaired: true),
            Fixture.subtitle(20, "eng", title: "English [CC]"),
            Fixture.subtitle(20, "eng", title: "Dubtitles"),
            Fixture.subtitle(20, "eng", title: "English Dub"),
        ] {
            let tracks = try Fixture.tracks([Fixture.audio(1, "eng"), Fixture.subtitle(10, "eng", selected: true), transcript])
            #expect(decide(tracks, audio: 1).track?.id == 20)
        }
    }

    @Test func aDownloadedTrackBeatsABuiltInOne() throws {
        let tracks = try builtIn(extra: [
            Fixture.subtitle(20, "eng", external: true),
            Fixture.subtitle(21, "eng", title: "SDH", external: true, hearingImpaired: true),
        ])

        #expect(decide(tracks, audio: 1).track?.id == 21)
        #expect(decide(tracks, audio: 2).track?.id == 20)
    }

    @Test func theFullTranslationIsNeverADubOrACaptionTrack() throws {
        let tracks = try Fixture.tracks([
            Fixture.audio(1, "jpn"),
            Fixture.subtitle(10, "eng", title: "Dubtitles", selected: true),
            Fixture.subtitle(11, "eng", title: "SDH", hearingImpaired: true),
        ])

        #expect(decide(tracks, audio: 1).track?.id == 10)
    }

    @Test func aBaseThatIsForcedSignsCommentaryOrOfUnknownLanguageStands() throws {
        let bases: [[String: Any]] = [
            Fixture.subtitle(10, "eng", forced: true, selected: true),
            Fixture.subtitle(10, "eng", title: "Signs & Songs", selected: true),
            Fixture.subtitle(10, "eng", title: "Commentary", selected: true),
            Fixture.subtitle(10, nil, selected: true),
            Fixture.subtitle(10, "spa", selected: true),
        ]
        for base in bases {
            let tracks = try Fixture.tracks([
                Fixture.audio(1, "eng"), Fixture.subtitle(11, "eng", title: "SDH", hearingImpaired: true), base,
            ])
            let decision = decide(tracks, audio: 1)
            #expect(decision.track?.id == 10 && !decision.followedAudio)
        }
    }

    @Test func audioOfUnknownLanguageLeavesTheBase() throws {
        let tracks = try Fixture.tracks([
            Fixture.audio(1, nil),
            Fixture.subtitle(10, "eng", selected: true),
            Fixture.subtitle(11, "eng", title: "SDH", hearingImpaired: true),
        ])

        #expect(decide(tracks, audio: 1).track?.id == 10)
    }

    @Test func withNothingBetterTheBaseStands() throws {
        let tracks = try Fixture.tracks([Fixture.audio(1, "eng"), Fixture.subtitle(10, "eng", selected: true)])

        let decision = decide(tracks, audio: 1)

        #expect(decision.track?.id == 10 && !decision.followedAudio)
    }

    @Test func theSettingTurnsFollowingOff() throws {
        let off = SubtitleSettings(followsAudio: false)

        #expect(decide(try builtIn(), audio: 1, settings: off).track?.id == 10)
    }

    @Test func aSubtitleTheViewerChoseOrTheShowRemembersIsNeverMoved() throws {
        // Nothing selected on the server: a remembered choice comes before the setting's automatic pick.
        let tracks = try Fixture.tracks([
            Fixture.audio(1, "eng"),
            Fixture.subtitle(10, "eng"),
            Fixture.subtitle(11, "eng", title: "SDH", hearingImpaired: true),
        ])
        let remembered = try #require(RememberedSubtitle(.track(10), in: tracks))
        let always = SubtitleSettings(defaultMode: .always)

        #expect(decide(tracks, audio: 1, settings: always).track?.id == 11)
        let picked = decide(tracks, audio: 1, handPick: .track(10), settings: always)
        let kept = decide(tracks, audio: 1, remembered: remembered, settings: always)
        let off = decide(tracks, audio: 1, remembered: .off, settings: always)

        #expect(picked.track?.id == 10 && picked.source == .handPick)
        #expect(kept.track?.id == 10 && kept.source == .remembered && !kept.followedAudio)
        #expect(off.track == nil)
    }

    @Test func switchingAudioPicksAgainAndRememberedAudioDoesNotStopIt() throws {
        let tracks = try builtIn()
        let rememberedAudio = RememberedAudio(try #require(tracks.audioTrack(id: 1)))

        let onStart = AudioPicker.pick(in: tracks, remembered: rememberedAudio)
        let english = decide(tracks, audio: try #require(onStart?.id))
        let japanese = decide(tracks, audio: 2)

        #expect(english.track?.id == 11)
        #expect(japanese.track?.id == 10)
    }

    @Test func onScreenTextIsNeverFollowed() throws {
        let tracks = try Fixture.tracks([
            Fixture.audio(1, "eng"),
            Fixture.subtitle(10, "eng", title: "Signs", selected: true),
            Fixture.subtitle(11, "eng", title: "SDH", hearingImpaired: true),
        ])
        let onScreen = decide(tracks, audio: 1, handPick: .onScreenTextOnly)

        #expect(onScreen.isOnScreenTextOnly && onScreen.track?.id == 10)
    }
}
