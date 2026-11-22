import Foundation
import Testing
@testable import MarqueeCore

/// The audio and subtitle rules, one row per case (docs/PLAN.md N18). Each row is a file's tracks, what
/// the viewer or the show already settled, and the audio and subtitle that play. `plays` is an audio
/// stream id, `shows` a subtitle stream id, nil for none. The LG TV app keeps the same table.
struct TrackRulesTableTests {
    struct Audio: Sendable {
        var id: Int
        var language: String
        var title: String?
        var isDefault: Bool

        var stream: [String: Any] { Fixture.audio(id, language, title: title, codec: "eac3", channels: 6, isDefault: isDefault) }
    }

    /// `file` is a separate `.srt` beside the video, else a track inside it.
    struct Sub: Sendable {
        var id: Int
        var language: String?
        var title: String?
        var isPicture: Bool
        var file: Bool
        var forced: Bool
        var sdh: Bool

        var stream: [String: Any] {
            Fixture.subtitle(
                id, language, title: title, codec: isPicture ? "pgs" : "srt", external: file, forced: forced, hearingImpaired: sdh
            )
        }
    }

    /// What an earlier episode of the show left in its memory.
    enum Remembered: Sendable {
        case audio(Audio)
        case subtitle(Sub)
        case subtitleOff
        case anime(AnimeOverride)
    }

    struct Row: Sendable, CustomTestStringConvertible {
        var name: String
        /// Plex tags the title anime.
        var tagged: Bool
        /// The production countries Plex lists, as it spells them.
        var countries: [String]
        var audio: [Audio]
        var subtitles: [Sub]
        var handAudio: Int?
        var handSubtitle: SubtitleChoice?
        var remembered: [Remembered]
        var plays: Int?
        var shows: Int?
        var source: SubtitleDecision.Source

        init(
            _ name: String, tagged: Bool = false, countries: [String] = [], audio: [Audio], subtitles: [Sub] = [], handAudio: Int? = nil,
            handSubtitle: SubtitleChoice? = nil, remembered: [Remembered] = [], plays: Int?, shows: Int? = nil,
            source: SubtitleDecision.Source = .rules
        ) {
            self.name = name
            self.tagged = tagged
            self.countries = countries
            self.audio = audio
            self.subtitles = subtitles
            self.handAudio = handAudio
            self.handSubtitle = handSubtitle
            self.remembered = remembered
            self.plays = plays
            self.shows = shows
            self.source = source
        }

        var testDescription: String { name }

        var memory: TrackMemory? {
            get throws {
                guard !remembered.isEmpty else { return nil }
                var memory = TrackMemory()
                for item in remembered {
                    switch item {
                    case .audio(let track): memory.audio = RememberedAudio(try Fixture.tracks([track.stream]).audio[0])
                    case .subtitle(let track): memory.subtitle = RememberedSubtitle(.track(track.id), in: try Fixture.tracks([track.stream]))
                    case .subtitleOff: memory.subtitle = .off
                    case .anime(let override): memory.anime = override
                    }
                }
                return memory
            }
        }
    }

    static func audio(_ id: Int, _ language: String, _ title: String? = nil, isDefault: Bool = false) -> Audio {
        Audio(id: id, language: language, title: title, isDefault: isDefault)
    }

    static func text(
        _ id: Int, _ language: String? = "eng", _ title: String? = nil, file: Bool = false, forced: Bool = false, sdh: Bool = false
    ) -> Sub {
        Sub(id: id, language: language, title: title, isPicture: false, file: file, forced: forced, sdh: sdh)
    }

    static func picture(_ id: Int, _ title: String? = nil) -> Sub {
        Sub(id: id, language: "eng", title: title, isPicture: true, file: false, forced: false, sdh: false)
    }

    /// A typical anime release: Japanese audio and an English dub; inside the file "Signs / Songs" and
    /// "Dialogue" as pictures; beside it `.en.srt` (the translation) and `.en.cc.srt` (the dub script).
    static let release = [audio(1, "jpn", isDefault: true), audio(2, "eng", "English")]
    static let releaseSubtitles = [
        picture(10, "Signs / Songs"), picture(11, "Dialogue"), text(12, file: true), text(13, file: true, sdh: true),
    ]

    static let rows: [Row] = [
        // Audio, for a movie or TV that is not anime: the original, never a dub.
        Row("original audio is the file's default track",
            audio: [audio(1, "eng"), audio(2, "fra", isDefault: true)], plays: 2),
        Row("original audio is the first track when none is default",
            audio: [audio(1, "fra"), audio(2, "eng")], plays: 1),
        Row("a titled dub is not the original",
            audio: [audio(1, "jpn", isDefault: true), audio(2, "eng", "English Dub")], plays: 1),
        Row("a titled dub the file defaults to is still not the original",
            audio: [audio(1, "eng", "English Dub", isDefault: true), audio(2, "jpn")], plays: 2),
        Row("a dub is played when it is all the file has",
            audio: [audio(1, "eng", "English Dub")], plays: 1),
        // The production country says the original language when the file's default is an unlabelled dub.
        Row("a Korean film whose default is an English dub plays Korean",
            countries: ["Republic of Korea"], audio: [audio(1, "eng", isDefault: true), audio(2, "kor")], plays: 2),
        Row("Taiwan, Province of China plays Chinese",
            countries: ["Taiwan, Province of China"], audio: [audio(1, "eng", isDefault: true), audio(2, "zho")], plays: 2),
        Row("Russian Federation plays Russian",
            countries: ["Russian Federation"], audio: [audio(1, "eng", isDefault: true), audio(2, "rus")], plays: 2),
        Row("Iran, Islamic Republic of plays Persian",
            countries: ["Iran, Islamic Republic of"], audio: [audio(1, "eng", isDefault: true), audio(2, "fas")], plays: 2),
        Row("Hong Kong plays Cantonese before Mandarin",
            countries: ["Hong Kong"], audio: [audio(1, "eng", isDefault: true), audio(2, "zho"), audio(3, "yue")], plays: 3),
        Row("a country is matched whatever its case",
            countries: ["JAPAN"], audio: [audio(1, "eng", isDefault: true), audio(2, "jpn")], plays: 2),
        Row("the first country with a track in its language decides",
            countries: ["Denmark", "France"], audio: [audio(1, "eng", isDefault: true), audio(2, "fra"), audio(3, "eng")], plays: 2),
        Row("an English-speaking country plays English",
            countries: ["Ireland"], audio: [audio(1, "fra", isDefault: true), audio(2, "eng")], plays: 2),
        Row("the country's language is taken in its main track, not commentary",
            countries: ["France"], audio: [audio(1, "eng", isDefault: true), audio(2, "fra", "Commentary"), audio(3, "fra")], plays: 3),
        Row("the country's language is not taken from a titled dub",
            countries: ["Japan"], audio: [audio(1, "eng", isDefault: true), audio(2, "jpn", "Japanese Dub")], plays: 1),
        Row("an unknown country plays the default track",
            countries: ["Atlantis"], audio: [audio(1, "eng", isDefault: true), audio(2, "kor")], plays: 1),
        Row("a country whose language the file lacks plays the default track",
            countries: ["Republic of Korea"], audio: [audio(1, "eng", isDefault: true), audio(2, "fra")], plays: 1),
        Row("anime keeps its dub whatever the country",
            tagged: true, countries: ["Japan"], audio: release, plays: 2),
        Row("a picked track comes before the country",
            countries: ["Republic of Korea"], audio: [audio(1, "eng", isDefault: true), audio(2, "kor")], handAudio: 1, plays: 1),
        Row("commentary is not the main audio",
            audio: [audio(1, "eng", "Commentary", isDefault: true), audio(2, "eng")], plays: 2),
        Row("audio description is not the main audio",
            audio: [audio(1, "eng", "Audio Description", isDefault: true), audio(2, "eng")], plays: 2),

        // Subtitles, for a movie or TV that is not anime: English text, on.
        Row("English audio with a .en.srt beside the file: on",
            audio: [audio(1, "eng", isDefault: true)], subtitles: [text(10, file: true)], plays: 1, shows: 10),
        Row("foreign audio with English text inside the file: on",
            audio: [audio(1, "fra", isDefault: true)], subtitles: [text(10), text(11, "fra")], plays: 1, shows: 10),
        Row("full English before captions, both inside the file",
            audio: [audio(1, "eng")], subtitles: [text(10, sdh: true), text(11)], plays: 1, shows: 11),
        Row("captions when there is nothing fuller",
            audio: [audio(1, "eng")], subtitles: [text(10, sdh: true)], plays: 1, shows: 10),
        Row("a .en.srt before a .en.cc.srt",
            audio: [audio(1, "eng")], subtitles: [text(10, file: true, sdh: true), text(11, file: true)], plays: 1, shows: 11),
        Row("a .en.cc.srt alone is used",
            audio: [audio(1, "eng")], subtitles: [text(10, file: true, sdh: true)], plays: 1, shows: 10),
        Row("a .en.cc.srt before full English inside the file",
            audio: [audio(1, "eng")], subtitles: [text(10), text(11, file: true, sdh: true)], plays: 1, shows: 11),
        Row("full English before forced",
            audio: [audio(1, "eng")], subtitles: [text(10, forced: true), text(11)], plays: 1, shows: 11),
        Row("a forced file never beats full English inside the file",
            audio: [audio(1, "eng")], subtitles: [text(10, file: true, forced: true), text(11)], plays: 1, shows: 11),
        Row("forced alone is the last resort",
            audio: [audio(1, "eng")], subtitles: [text(10, forced: true)], plays: 1, shows: 10),
        Row("a plain track before a dub script",
            audio: [audio(1, "eng")], subtitles: [text(10, "eng", "Dubtitles", file: true), text(11)], plays: 1, shows: 11),
        Row("text before a picture",
            audio: [audio(1, "eng")], subtitles: [picture(10), text(11)], plays: 1, shows: 11),
        Row("a picture alone is never picked",
            audio: [audio(1, "eng")], subtitles: [picture(10)], plays: 1),
        Row("only English is picked",
            audio: [audio(1, "eng")], subtitles: [text(10, "fra")], plays: 1),
        Row("a track with no language is not picked",
            audio: [audio(1, "eng")], subtitles: [text(10, nil)], plays: 1),
        Row("commentary text is not picked",
            audio: [audio(1, "eng")], subtitles: [text(10, "eng", "Commentary")], plays: 1),

        // Anime: the English dub with its script, else the original audio with the translation.
        Row("anime plays the dub with the dub script",
            tagged: true, audio: release, subtitles: releaseSubtitles, plays: 2, shows: 13),
        Row("anime with the original audio picked gets the translation",
            tagged: true, audio: release, subtitles: releaseSubtitles, handAudio: 1, plays: 1, shows: 12),
        Row("anime without a dub plays the original with the translation",
            tagged: true, audio: [audio(1, "jpn", isDefault: true)], subtitles: [text(12, file: true), text(13, file: true, sdh: true)],
            plays: 1, shows: 12),
        Row("anime dub with only a translation file uses it",
            tagged: true, audio: release, subtitles: [text(12, file: true)], plays: 2, shows: 12),
        Row("anime original audio with only a dub script file uses it",
            tagged: true, audio: [audio(1, "jpn", isDefault: true)], subtitles: [text(13, file: true, sdh: true)], plays: 1, shows: 13),
        Row("anime with text inside the file only: the dub takes the SDH track",
            tagged: true, audio: release, subtitles: [text(10, "eng", "English"), text(11, "eng", "English SDH", sdh: true)],
            plays: 2, shows: 11),
        Row("anime with text inside the file only: the original takes the full track",
            tagged: true, audio: release, subtitles: [text(10, "eng", "English"), text(11, "eng", "English SDH", sdh: true)],
            handAudio: 1, plays: 1, shows: 10),
        Row("anime: a dub-named track is the dub script",
            tagged: true, audio: release, subtitles: [text(12, file: true), text(13, "eng", "English Dubtitles", file: true)],
            plays: 2, shows: 13),
        Row("anime: a .en.srt beside the file before the dub's SDH track inside it",
            tagged: true, audio: release, subtitles: [text(10, "eng", "English SDH", sdh: true), text(12, file: true)],
            plays: 2, shows: 12),
        Row("anime: signs and songs never beat a full track",
            tagged: true, audio: [audio(1, "jpn")], subtitles: [text(10, "eng", "Signs & Songs"), text(11)], plays: 1, shows: 11),
        Row("anime: signs and songs alone are the last resort",
            tagged: true, audio: [audio(1, "jpn")], subtitles: [text(10, "eng", "Signs & Songs")], plays: 1, shows: 10),
        Row("anime: picture dialogue is never picked",
            tagged: true, audio: [audio(1, "jpn")], subtitles: [picture(10, "Dialogue")], plays: 1),

        // The viewer's word on anime, per show.
        Row("a show marked not anime plays as any other",
            tagged: true, audio: release, subtitles: releaseSubtitles, remembered: [.anime(.notAnime)], plays: 1, shows: 12),
        Row("a show marked anime plays as anime without Plex's tags",
            audio: release, subtitles: releaseSubtitles, remembered: [.anime(.anime)], plays: 2, shows: 13),

        // What the viewer picked or the show remembers stands.
        Row("a picked dub is played in a film",
            audio: [audio(1, "jpn", isDefault: true), audio(2, "eng", "English Dub")], handAudio: 2, plays: 2),
        Row("remembered audio is played over the dub",
            tagged: true, audio: release, subtitles: releaseSubtitles, remembered: [.audio(audio(99, "jpn", isDefault: true))],
            plays: 1, shows: 12),
        Row("picked audio comes before remembered audio",
            tagged: true, audio: release, subtitles: releaseSubtitles, handAudio: 2, remembered: [.audio(audio(99, "jpn"))],
            plays: 2, shows: 13),
        Row("Off by hand",
            audio: [audio(1, "eng")], subtitles: [text(10, file: true)], handSubtitle: .off, plays: 1, source: .handPick),
        Row("Off remembered for the show",
            audio: [audio(1, "eng")], subtitles: [text(10, file: true)], remembered: [.subtitleOff], plays: 1, source: .remembered),
        Row("On forgets a remembered Off",
            audio: [audio(1, "eng")], subtitles: [text(10, file: true)], handSubtitle: .automatic, remembered: [.subtitleOff],
            plays: 1, shows: 10),
        Row("a picked subtitle is not moved to suit the audio",
            tagged: true, audio: release, subtitles: releaseSubtitles, handAudio: 2, handSubtitle: .track(12),
            plays: 2, shows: 12, source: .handPick),
        Row("a picked picture track is shown as picked",
            audio: [audio(1, "eng")], subtitles: [picture(10), text(11)], handSubtitle: .track(10), plays: 1, shows: 10, source: .handPick),
        // An anime's remembered separate English file is only a language: the audio picks .en.cc or .en.
        Row("a remembered .en.srt gives way to .en.cc with the dub",
            tagged: true, audio: release, subtitles: releaseSubtitles, remembered: [.subtitle(text(99, file: true))],
            plays: 2, shows: 13, source: .remembered),
        Row("a remembered .en.srt is shown with the original audio",
            tagged: true, audio: release, subtitles: releaseSubtitles, handAudio: 1, remembered: [.subtitle(text(99, file: true))],
            plays: 1, shows: 12, source: .remembered),
        Row("a remembered .en.cc.srt is shown with the original audio as .en.srt",
            tagged: true, audio: release, subtitles: releaseSubtitles, handAudio: 1,
            remembered: [.subtitle(text(99, file: true, sdh: true))], plays: 1, shows: 12, source: .remembered),
        Row("a film keeps a remembered separate file",
            audio: [audio(1, "fra", isDefault: true)], subtitles: [text(10, file: true), text(11, file: true, sdh: true)],
            remembered: [.subtitle(text(99, file: true, sdh: true))], plays: 1, shows: 11, source: .remembered),
        Row("an anime keeps a remembered subtitle inside the file",
            tagged: true, audio: release, subtitles: [text(10, file: true), text(11), text(12, sdh: true)],
            handAudio: 2, remembered: [.subtitle(text(99, sdh: true))], plays: 2, shows: 12, source: .remembered),
        Row("a remembered subtitle the next episode lacks gives way to the rules",
            audio: [audio(1, "eng")], subtitles: [text(10, file: true)], remembered: [.subtitle(text(99, "fra"))], plays: 1, shows: 10),
    ]

    @Test(arguments: rows) func rule(_ row: Row) throws {
        let tracks = try Fixture.tracks(row.audio.map(\.stream) + row.subtitles.map(\.stream))
        let choices = TrackRules.Choices(audio: row.handAudio, subtitle: row.handSubtitle, memory: try row.memory)

        let pick = TrackRules.pick(from: tracks, isAnime: row.tagged, countries: row.countries, choices: choices)

        #expect(pick.audio?.id == row.plays)
        #expect(pick.subtitle.track?.id == row.shows)
        #expect(pick.subtitle.source == row.source)
    }
}

/// Which titles are anime: by Plex's tags, from the title or for an episode its show.
struct AnimeClassifierTableTests {
    struct Row: Sendable, CustomTestStringConvertible {
        var genres: [String]
        var countries: [String] = []
        var isAnime: Bool

        var testDescription: String { "\(genres) \(countries) \(isAnime ? "is" : "is not") anime" }
    }

    static let rows = [
        Row(genres: ["Anime"], isAnime: true),
        Row(genres: ["anime", "Drama"], countries: ["United States"], isAnime: true),
        Row(genres: ["Animation"], countries: ["Japan"], isAnime: true),
        Row(genres: ["Animation", "Comedy"], countries: ["United States", "Japan"], isAnime: true),
        Row(genres: ["Animation"], countries: ["United States"], isAnime: false),
        Row(genres: ["Animation"], isAnime: false),
        Row(genres: ["Drama"], countries: ["Japan"], isAnime: false),
        Row(genres: [], isAnime: false),
    ]

    @Test(arguments: rows) func classifies(_ row: Row) {
        #expect(Anime.matches(genres: row.genres, countries: row.countries) == row.isAnime)
    }

    @Test func aShowIsReadOnceForAllItsEpisodes() async throws {
        let (library, transport) = PlexLibraryTests.library { _ in
            container(["size": 1, "Metadata": [["ratingKey": "5", "type": "show", "Genre": [["tag": "Animation"]], "Country": [["tag": "Japan"]]]]])
        }
        let lookup = AnimeLookup()
        let first = try decode(PlexMetadata.self, ["ratingKey": "50", "type": "episode", "grandparentRatingKey": "5"])
        let second = try decode(PlexMetadata.self, ["ratingKey": "51", "type": "episode", "grandparentRatingKey": "5"])
        let filmItem = try decode(PlexMetadata.self, ["ratingKey": "9", "type": "movie", "Genre": [["tag": "Drama"]]])

        let episodes = [await lookup.tags(first, in: library), await lookup.tags(second, in: library)]
        let film = await lookup.tags(filmItem, in: library)

        #expect(episodes == [TitleTags(isAnime: true, countries: ["Japan"]), TitleTags(isAnime: true, countries: ["Japan"])])
        #expect(!film.isAnime && film.countries.isEmpty)
        #expect(await transport.requests(to: "/library/metadata/5").count == 1)
    }
}
