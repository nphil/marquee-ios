import Foundation
import Testing
@testable import MarqueeCore

/// What a show remembers is matched by description in its next episodes, whose stream ids all differ.
struct TrackMemoryTests {
    func shown(_ tracks: MediaTracks, remembering subtitle: RememberedSubtitle) -> Int? {
        TrackRules.pick(from: tracks, isAnime: false, choices: .init(memory: TrackMemory(subtitle: subtitle))).subtitle.track?.id
    }

    @Test func aRememberedFileIsMatchedByAFileInTheNextEpisode() throws {
        let first = try Fixture.tracks([
            Fixture.audio(1, "jpn"),
            Fixture.subtitle(12, "eng", external: true),
            Fixture.subtitle(13, "eng", external: true, hearingImpaired: true),
        ])
        let remembered = try #require(RememberedSubtitle(.track(13), in: first))
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
        let otherLanguage = try Fixture.tracks([Fixture.audio(1, "jpn"), Fixture.subtitle(40, "spa", isDefault: true)])

        #expect(shown(next, remembering: remembered) == 22)
        #expect(shown(builtInOnly, remembering: remembered) == 31)
        #expect(shown(otherLanguage, remembering: remembered) == nil)
    }

    @Test func aRememberedHiddenTrackIsStoredAsTheFileThatReplacedIt() throws {
        let tracks = try Fixture.tracks([
            Fixture.subtitle(11, "eng", title: "Dialogue", codec: "pgs"),
            Fixture.subtitle(12, "eng", external: true),
        ])

        let remembered = RememberedSubtitle(.track(11), in: tracks)

        guard case .track(let description)? = remembered else {
            Issue.record("nothing remembered")
            return
        }
        #expect(description.wasExternal && description.kind == .full)
    }

    @Test func rememberedAudioKeepsLanguageAndCommentaryStrict() throws {
        let watched = try Fixture.tracks([Fixture.audio(1, "eng", codec: "eac3", channels: 6)])
        let remembered = RememberedAudio(watched.audio[0])
        let next = try Fixture.tracks([
            Fixture.audio(5, "eng", title: "Commentary", codec: "eac3", channels: 6),
            Fixture.audio(6, "eng", codec: "ac3", channels: 6),
            Fixture.audio(7, "eng", codec: "eac3", channels: 2),
            Fixture.audio(8, "jpn", codec: "eac3", channels: 6),
        ])
        let japaneseOnly = try Fixture.tracks([Fixture.audio(9, "jpn", codec: "eac3", channels: 6)])

        #expect(remembered.match(in: next.audio)?.id == 7)
        #expect(remembered.match(in: japaneseOnly.audio) == nil)
    }

    @Test func memorySavedBeforeTheRulesKeepsItsAudio() throws {
        let audio = RememberedAudio(try Fixture.tracks([Fixture.audio(1, "jpn")]).audio[0])
        let saved = #"{"audio":\#(String(decoding: try JSONEncoder().encode(audio), as: UTF8.self))"#
            + #","subtitle":{"onScreenTextOnly":{}}}"#

        let memory = try JSONDecoder().decode(TrackMemory.self, from: Data(saved.utf8))

        #expect(memory.audio == audio && memory.subtitle == nil && memory.anime == .automatic)
    }
}
