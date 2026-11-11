import Foundation
import Testing
@testable import MarqueeCore

struct MediaTracksTests {
    @Test func languageCodesCompareByLanguage() {
        #expect(TrackLanguage(tag: "eng").matches(.english))
        #expect(TrackLanguage(tag: "en-US").matches(TrackLanguage(tag: "en")))
        #expect(TrackLanguage(tag: "fre") == TrackLanguage(tag: "fra"))
        #expect(TrackLanguage(tag: "pt-BR") == TrackLanguage(code: "pt", region: "BR"))
        #expect(TrackLanguage(tag: "zh-hant") == TrackLanguage(code: "zh", script: "Hant"))
        #expect(TrackLanguage(tag: "jpn").name == "Japanese")
        #expect(TrackLanguage(tag: "es-419").variantName == "Latin America")
        #expect(!TrackLanguage(tag: "und").isKnown)
        #expect(!TrackLanguage(tag: "und").matches(TrackLanguage(tag: "und")))
    }

    @Test func catalogueNamesEachLanguageOnceInOrder() {
        let names = TrackLanguage.all.compactMap(\.name)
        #expect(names.count == TrackLanguage.all.count)
        #expect(Set(names).count == names.count)
        #expect(names == names.sorted())
        #expect(TrackLanguage.all.contains(.english))
        #expect(TrackLanguage.all.contains(TrackLanguage(tag: "heb")))
    }

    @Test func flagsAndTitleWordsDecideWhatASubtitleHolds() throws {
        let tracks = try Fixture.tracks([
            Fixture.subtitle(1, "eng", title: "Signs / Songs", codec: "pgs"),
            Fixture.subtitle(2, "eng", title: "Commentary", forced: true),
            Fixture.subtitle(3, "eng", title: "English [CC]"),
            Fixture.subtitle(4, "eng", codec: "eia_608", inVideo: true),
            Fixture.subtitle(5, "rus", title: "Форсированные"),
            Fixture.subtitle(6, "rus", title: "Комментарии режиссёра"),
            Fixture.subtitle(7, "eng", title: "Dubtitles"),
            Fixture.subtitle(8, "eng", title: "Designer cut"),
        ])

        #expect(tracks.subtitles.map(\.kind)
            == [.onScreenText, .commentary, .captions, .captions, .onScreenText, .commentary, .full, .full])
        #expect(tracks.subtitles[0].imageFormat == "PGS" && tracks.subtitles[1].imageFormat == nil)
        #expect(tracks.subtitles[3].isInVideoStream)
        #expect(tracks.subtitles[6].isDub && !tracks.subtitles[7].isDub)
    }

    @Test func labelsArePlainWordsAndTellTracksApart() throws {
        let tracks = try Fixture.tracks([
            Fixture.audio(1, "eng", codec: "truehd", channels: 8),
            Fixture.audio(2, "eng", codec: "ac3", channels: 6),
            Fixture.audio(3, "eng", title: "Director's Commentary"),
            Fixture.audio(4, "eng", title: "Descriptive Audio"),
            Fixture.subtitle(10, "spa", tag: "es-419"),
            Fixture.subtitle(11, "spa", tag: "es-ES"),
            Fixture.subtitle(12, "eng", title: "Forced", forced: true),
            Fixture.subtitle(13, "eng", title: "SDH", hearingImpaired: true),
            Fixture.subtitle(14, "eng"),
            Fixture.subtitle(15, "eng"),
            Fixture.subtitle(16, "eng", title: "Dubtitles"),
        ])

        #expect(tracks.audio.map(\.label) == ["English – 7.1", "English – 5.1", "English (commentary)", "English"])
        #expect(tracks.audio[3].badges == [.audioDescription])
        #expect(tracks.subtitles.map(\.label) == [
            "Spanish (Latin America)", "Spanish (Spain)", "English (on-screen text)", "English",
            "English – Track 5", "English – Track 6", "English (dub)",
        ])
        #expect(tracks.subtitles[3].badges == [.captions])
    }

    @Test func builtInTrackIsHiddenOnlyBehindAnExactTwin() throws {
        let tracks = try Fixture.tracks([
            Fixture.subtitle(1, "eng", codec: "pgs"),
            Fixture.subtitle(2, "eng", title: "Forced", codec: "pgs", forced: true),
            Fixture.subtitle(3, "por", tag: "pt-BR"),
            Fixture.subtitle(4, "eng", external: true),
            Fixture.subtitle(5, "por", tag: "pt-PT", external: true),
            Fixture.subtitle(6, "eng", title: "Dubtitles", external: true),
        ])

        #expect(tracks.subtitles.map(\.id) == [1, 2, 3, 4, 5, 6])
        #expect(tracks.subtitles.map(\.replacedBy) == [4, nil, nil, nil, nil, nil])
        #expect(tracks.visibleSubtitles.map(\.id) == [2, 3, 4, 5, 6])
        #expect(tracks.subtitles[0].label == "English")
        #expect(tracks.visible(tracks.subtitles[0]).id == 4)
    }

    @Test func aDownloadIsTheNewFileInItsLanguage() throws {
        let tracks = try Fixture.tracks([
            Fixture.subtitle(1, "eng"),
            Fixture.subtitle(2, "eng", external: true),
            Fixture.subtitle(3, "fre", external: true),
            Fixture.subtitle(4, "eng", external: true),
            Fixture.subtitle(5, "eng", external: true, hearingImpaired: true),
        ])

        #expect(tracks.arrived(.english, kind: .captions, since: [1, 2, 3])?.id == 5)
        #expect(tracks.arrived(.english, kind: .onScreenText, since: [1, 2, 3])?.id == 4)
        #expect(tracks.arrived(TrackLanguage(tag: "fr"), kind: .full, since: [1, 2, 3]) == nil)
    }

    @Test func aFileDownloadedAgainReplacesItsEarlierCopy() throws {
        let release = "Alive.2020.1080p.WEBRip"
        let tracks = try Fixture.tracks([
            Fixture.subtitle(1, "eng"),
            Fixture.subtitle(7, "eng", title: release, external: true),
            Fixture.subtitle(8, "dut", title: release, external: true),
            Fixture.subtitle(9, "eng", title: release, external: true),
        ])

        #expect(tracks.subtitles.map(\.replacedBy) == [9, 9, nil, nil])
        #expect(tracks.visibleSubtitles.map(\.id) == [8, 9])
        let added = PlexSubtitleCandidate(key: "/library/streams/40", title: release, language: TrackLanguage(tag: "nl"), provider: nil, score: nil)
        let other = PlexSubtitleCandidate(key: "/library/streams/41", title: "Alive.2020.720p", language: .english, provider: nil, score: nil)
        #expect(tracks.listed(added)?.id == 8 && tracks.listed(other) == nil)
        #expect(tracks.landed(added, since: [1, 7, 9])?.id == 8 && tracks.landed(added, since: [1, 7, 8, 9]) == nil)
    }

    @Test func viewersLanguagesStayOnTheMenuAndTheRestGoAToZ() throws {
        let tracks = try Fixture.tracks([
            Fixture.subtitle(1, "spa"),
            Fixture.subtitle(2, "eng", title: "Commentary"),
            Fixture.subtitle(3, "fre"),
            Fixture.subtitle(4, "eng", hearingImpaired: true),
            Fixture.subtitle(5, "jpn"),
            Fixture.subtitle(6, "eng"),
            Fixture.subtitle(7, nil),
        ])

        let all = SubtitleLanguages(tracks.visibleSubtitles, yours: [TrackLanguage(tag: "jpn"), .english, .english])
        #expect(all.yours.map(\.name) == ["Japanese", "English"])
        #expect(all.yours[1].tracks.map(\.id) == [6, 4, 2])
        #expect(all.other.map(\.name) == ["French", "Spanish", "Unknown"])

        let pair = SubtitleLanguages(tracks.visibleSubtitles.filter { [2, 3, 6].contains($0.id) }, yours: [.english])
        #expect(pair.yours.map(\.name) == ["English", "French"] && pair.other.isEmpty)

        // A list the menu has room for stays whole, the viewer's languages still first.
        let whole = SubtitleLanguages(tracks.visibleSubtitles, yours: [.english], room: 7)
        #expect(whole.yours.map(\.name) == ["English", "French", "Japanese", "Spanish", "Unknown"] && whole.other.isEmpty)
        let long = SubtitleLanguages(tracks.visibleSubtitles, yours: [.english], room: 6)
        #expect(long.yours.map(\.name) == ["English"] && long.other.count == 4)
        // The subtitle showing keeps its language on the menu, named or not.
        let showing = SubtitleLanguages(tracks.visibleSubtitles, yours: [.english], showing: tracks.visibleSubtitles.first { $0.id == 7 }, room: 6)
        #expect(showing.yours.map(\.name) == ["English", "Unknown"] && showing.other.map(\.name) == ["French", "Japanese", "Spanish"])
    }

    @Test func memoryIsKeptPerShowNotPerEpisode() throws {
        let episode = try decode(PlexMetadata.self, ["ratingKey": "12", "type": "episode", "grandparentRatingKey": "10"])
        let movie = try decode(PlexMetadata.self, ["ratingKey": "99", "type": "movie"])

        #expect(TrackMemory.storageKey(server: "machine-1", profile: "u9", item: episode) == "tracks.machine-1.u9.10")
        #expect(TrackMemory.storageKey(server: "machine-1", profile: "u9", item: movie) == "tracks.machine-1.u9.99")
    }
}
