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
                    "id": 77, "key": "/library/parts/77/file.mkv", "duration": 1_450_000,
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

        let streams = try #require(item.media.first?.parts.first?.streams)
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
}
