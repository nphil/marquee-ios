import Foundation
import Testing
@testable import MarqueeCore

struct PlexModelsTests {
    @Test func episodeDecodesFromMixedFieldTypes() throws {
        let episode: [String: Any] = [
            "ratingKey": 5012, "key": "/library/metadata/5012", "type": "episode", "title": "Pilot",
            "grandparentRatingKey": "5000", "parentRatingKey": "5001", "index": "1", "parentIndex": 1,
            "duration": "1450000", "viewOffset": 61000.0, "viewCount": "0",
            "addedAt": 1_700_000_000, "lastViewedAt": "2024-05-01T20:15:00Z",
            "Genre": [["tag": "Drama"], ["tag": NSNull()], ["tag": "Mystery"]],
            "Marker": [
                ["type": "credits", "startTimeOffset": 1_400_000, "endTimeOffset": 1_450_000, "final": "1"],
                ["type": "intro", "startTimeOffset": 30000, "endTimeOffset": 90000],
                ["type": "credits", "startTimeOffset": 1_300_000, "endTimeOffset": 1_320_000, "final": false],
            ],
            "Media": [[
                "id": 1, "container": "mkv", "videoCodec": "hevc", "bitrate": "18000",
                "Part": [[
                    "id": 77, "key": "/library/parts/77/file.mkv", "duration": 1_450_000, "indexes": "sd",
                    "Stream": [
                        ["id": 1, "streamType": 1, "codec": "HEVC", "bitDepth": 10, "DOVIPresent": "1",
                         "DOVIProfile": 8, "DOVIBLCompatID": 1, "colorTrc": "SMPTE2084"],
                        ["id": 2, "streamType": "2", "codec": "eac3", "channels": 6, "default": 1, "languageCode": "eng"],
                        ["id": 3, "streamType": 3, "codec": "srt", "key": "", "forced": "0"],
                        ["id": 4, "streamType": 3, "codec": "srt", "key": "/library/streams/4", "hearingImpaired": true],
                    ],
                ]],
            ]],
        ]

        let item = try decode(PlexMetadata.self, episode)

        #expect(item.ratingKey == "5012")
        #expect(item.type == .episode)
        #expect(item.index == 1)
        #expect(item.duration == 1_450_000 && item.viewOffset == 61000)
        #expect(item.showRatingKey == "5000")
        #expect(!item.isWatched)
        #expect(item.addedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(item.lastViewedAt == Date(timeIntervalSince1970: 1_714_594_500))
        #expect(item.genres == ["Drama", "Mystery"])

        let credits = item.markers(.credits)
        #expect(credits.map(\.start) == [1_300_000, 1_400_000])
        #expect(credits[1].isFinal && credits[1].contains(1_460_000))
        #expect(!credits[0].contains(1_320_000))

        let part = try #require(item.media.first?.parts.first)
        #expect(part.hasSceneThumbnails)
        let streams = part.streams
        #expect(streams[0].codec == "hevc" && streams[0].colorTrc == "smpte2084")
        #expect(streams[0].dolbyVision?.profile == 8 && streams[0].dolbyVision?.baseLayerCompatibility == 1)
        #expect(streams[1].kind == .audio && streams[1].isDefault)
        #expect(!streams[2].isExternal)
        #expect(streams[3].isExternal && streams[3].isHearingImpaired)
    }

    @Test func showIsWatchedOnlyWhenEveryEpisodeIs() throws {
        func show(leaves: Int, viewed: Int) throws -> PlexMetadata {
            try decode(PlexMetadata.self, ["ratingKey": "1", "type": "show", "leafCount": leaves, "viewedLeafCount": viewed])
        }

        #expect(try show(leaves: 10, viewed: 10).isWatched)
        #expect(try !show(leaves: 10, viewed: 9).isWatched)
        #expect(try show(leaves: 10, viewed: 9).unwatchedLeafCount == 1)
    }

    /// A rewatch keeps the view count, so part-watched titles in On Deck carried a check (2026-11-21).
    @Test func aPartWatchedRewatchShowsNoCheck() throws {
        func item(_ fields: [String: Any]) throws -> PlexMetadata {
            try decode(PlexMetadata.self, ["ratingKey": "1"].merging(fields) { $1 })
        }
        #expect(try !item(["type": "episode", "viewCount": 2, "viewOffset": 120_000]).showsWatchedCheck)
        #expect(try item(["type": "episode", "viewCount": 2]).showsWatchedCheck)
        #expect(try !item(["type": "show", "viewCount": 3]).showsWatchedCheck)
        #expect(try item(["type": "show", "leafCount": 10, "viewedLeafCount": 10]).showsWatchedCheck)
        #expect(try !item(["type": "collection", "viewCount": 1]).showsWatchedCheck)
    }

    /// The Apothecary Diaries S2 E10's real times: Plex's credits start 13 s into the file's Ending chapter, and
    /// E11 has an Ending chapter but no Plex credits marker.
    @Test func namedChaptersCorrectAndFillIntroAndCreditsMarkers() throws {
        func episode(markers: [[String: Any]], extra: [[String: Any]] = []) throws -> PlexMetadata {
            let chapters: [[String: Any]] = [
                ["tag": "Opening", "startTimeOffset": 0, "endTimeOffset": 90007],
                ["tag": "Part A", "startTimeOffset": 90007, "endTimeOffset": 859_067],
                ["tag": "Part B", "startTimeOffset": 859_067, "endTimeOffset": 1_335_084],
                ["tag": "Ending", "startTimeOffset": 1_335_084, "endTimeOffset": 1_425_132],
                ["tag": "Preview", "startTimeOffset": 1_425_132, "endTimeOffset": 1_441_065],
            ] + extra
            return try decode(PlexMetadata.self, [
                "ratingKey": "18731", "type": "episode", "duration": 1_441_065, "Marker": markers, "Chapter": chapters,
            ])
        }

        let marked = try episode(markers: [
            ["type": "intro", "startTimeOffset": 1600, "endTimeOffset": 87400],
            ["type": "credits", "startTimeOffset": 1_348_000, "endTimeOffset": 1_441_065, "final": true],
        ])
        let intro = try #require(marked.markers(.intro).first)
        #expect((intro.start, intro.end, intro.fromChapter) == (0, 90007, true))
        let credits = try #require(marked.markers(.credits).first)
        #expect((credits.start, credits.end, credits.isFinal) == (1_335_084, 1_441_065, true))

        let unmarked = try episode(markers: [], extra: [
            // Opening credits named "Credits", and a story scene too long for a theme song: neither is a marker.
            ["tag": "Credits", "startTimeOffset": 95000, "endTimeOffset": 150_000],
            ["tag": "Ending", "startTimeOffset": 900_000, "endTimeOffset": 1_300_000],
        ])
        #expect(unmarked.markers(.credits).map { [$0.start, $0.end] } == [[1_335_084, 1_425_132]])
        #expect(unmarked.markers(.intro).map(\.start) == [0])
    }

    /// The Apothecary Diaries S1 E14's real times: Plex split the file's Credits chapter into credits and final
    /// credits, and Up Next waited 75 s for the final ones.
    @Test func aCreditsChapterJoinsEveryPlexCreditsMarkerItSpans() throws {
        let item = try decode(PlexMetadata.self, [
            "ratingKey": "22534", "type": "episode", "duration": 1_372_073,
            "Marker": [
                ["type": "credits", "startTimeOffset": 1_270_867, "endTimeOffset": 1_290_867],
                ["type": "credits", "startTimeOffset": 1_340_867, "endTimeOffset": 1_372_075, "final": true],
            ],
            "Chapter": [
                ["tag": "Part 01", "startTimeOffset": 0, "endTimeOffset": 1_266_450],
                ["tag": "Credits", "startTimeOffset": 1_266_450, "endTimeOffset": 1_372_080],
            ],
        ])

        let credits = item.markers(.credits)
        #expect(credits.map { [$0.start, $0.end] } == [[1_266_450, 1_372_080]])
        #expect(credits.first?.isFinal == true)
    }
}
